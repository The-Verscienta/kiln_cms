defmodule KilnCMS.Newsletter.MailWorker do
  @moduledoc """
  Delivers one newsletter email to one subscriber.

  Enqueued by `KilnCMS.Newsletter.SendWorker` (one job per recipient). Rebuilds
  the email from the campaign's fired `:web` artifact, injects the
  `List-Unsubscribe` headers (RFC 8058 one-click) and footer, and delivers via
  `KilnCMS.Mail.deliver_for_worker/2` — inheriting DKIM signing, permanent-bounce
  suppression, and greylist-aware retry from the mail pipeline. Skips a
  subscriber who unsubscribed (or whose address hard-bounced) between fan-out
  and delivery.

  `unique` on the `{send, subscriber}` pair, over every state and for as long
  as the row exists, so a re-run of the fan-out (`SendWorker` retried, or
  rescued after a deploy killed it — #1718) cannot mail anyone twice. The
  pair is the job's whole identity: there is no legitimate second job for it.
  """
  use Oban.Worker,
    queue: :newsletter,
    max_attempts: 8,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:newsletter_send_id, :subscriber_id],
      states: :all
    ]

  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  require Logger

  alias KilnCMS.Mail
  alias KilnCMS.Newsletter

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "newsletter_send_id" => send_id,
          "subscriber_id" => subscriber_id,
          "org_id" => tenant
        }
      })
      when is_binary(tenant) do
    # Strict tenancy (#419): the per-recipient job carries the campaign's org
    # (enqueued by SendWorker).
    #
    # Both reads run as `Newsletter.system/0` (#1659) and fail CLOSED. Under
    # the filter a refused read answers `nil`, and `nil` cancels the job as
    # "not found"; the job is `unique` over every state, so a cancelled
    # recipient is never re-enqueued and never mailed. `authorize_with:
    # :error` makes a lost grant a logged retry instead.
    with {:ok, send} <- fetch("send", send_id, &Newsletter.get_send(&1, lookup_opts(tenant))),
         {:ok, subscriber} <-
           fetch("subscriber", subscriber_id, &Newsletter.get_subscriber(&1, lookup_opts(tenant))) do
      cond do
        is_nil(send) ->
          {:cancel, "newsletter send #{send_id} not found"}

        is_nil(subscriber) ->
          {:cancel, "subscriber #{subscriber_id} not found"}

        subscriber.status != :confirmed ->
          {:cancel, "subscriber not confirmed (#{subscriber.status})"}

        # The instance-wide list, and this site's own relay's list (#1562).
        # Raises if either list cannot be read (#1659), which retries the job.
        Mail.suppressed?(to_string(subscriber.email), org_id: tenant) ->
          {:cancel, "recipient suppressed (bounced)"}

        true ->
          deliver(send, subscriber)
      end
    end
  end

  # A job with no `org_id` was enqueued by a release before 0.12, which ran it
  # against the default org with a deprecation warning. 1.0 removed that
  # fallback (#1543): the job is cancelled with a logged error, never retried.
  def perform(%Oban.Job{args: args}),
    do: KilnCMS.Deprecations.cancel_legacy_job(__MODULE__, args)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  @impl Oban.Worker
  def timeout(_job), do: Mail.attempt_timeout()

  defp deliver(send, subscriber) do
    case Newsletter.artifact_html(send) do
      {:ok, html} ->
        send
        |> build_email(subscriber, html)
        # Stable Message-ID across retries (keyed on send + subscriber), so a
        # greylisted retry re-sends the same message rather than a new one.
        |> Mail.ensure_message_id("newsletter-#{send.id}-#{subscriber.id}")
        # Through the site's own relay when it has one (#1322).
        |> Mail.deliver_for_worker(org_id: send.org_id)
        |> record_outcome(send)

      {:error, :not_fired} ->
        {:cancel, "no fired :web artifact for #{send.content_type} #{send.content_id}"}
    end
  end

  defp lookup_opts(tenant) do
    [actor: Newsletter.system(), authorize_with: :error, not_found_error?: false, tenant: tenant]
  end

  defp fetch(what, id, read) do
    case read.(id) do
      {:ok, record} ->
        {:ok, record}

      {:error, error} ->
        Logger.error(
          "Newsletter.MailWorker could not read #{what} #{id}, will retry: " <>
            Exception.message(error)
        )

        {:error, error}
    end
  end

  # Settle the per-recipient outcome under the campaign's own site (epic #336),
  # as `Newsletter.system/0` (#1659, admitted for `record_sent` and
  # `record_failed`).
  #
  # A counter that will not move is LOGGED, never raised: by then the message
  # is out (or refused for good), and failing the job would have Oban mail the
  # same person the same newsletter again to fix a tally.
  defp record_outcome(:ok, send) do
    send
    |> Newsletter.record_sent(actor: Newsletter.system(), tenant: send.org_id)
    |> log_unrecorded(:record_sent, send)

    :ok
  end

  defp record_outcome({:cancel, reason}, send) do
    send
    |> Newsletter.record_failed(actor: Newsletter.system(), tenant: send.org_id)
    |> log_unrecorded(:record_failed, send)

    {:cancel, reason}
  end

  defp log_unrecorded({:ok, _send}, _action, _send_record), do: :ok

  defp log_unrecorded({:error, error}, action, send) do
    Logger.error(
      "Newsletter.MailWorker could not #{action} on send #{send.id}: " <>
        Exception.message(error)
    )
  end

  defp build_email(send, subscriber, html) do
    unsubscribe_url = url(~p"/newsletter/unsubscribe/#{subscriber.unsubscribe_token}")

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(subscriber.email))
    |> subject(send.subject)
    # RFC 8058 one-click unsubscribe: mail clients render a native
    # "unsubscribe" affordance and POST here, improving deliverability.
    |> header("List-Unsubscribe", "<#{unsubscribe_url}>")
    |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
    |> html_body(wrap(send.subject, html, unsubscribe_url))
  end

  # Minimal HTML-email shell around the fired content. `html` is server-rendered
  # from sanitized blocks (trusted); the subject is HTML-escaped as it's
  # editor-controlled. The footer carries the required unsubscribe link.
  defp wrap(subject, html, unsubscribe_url) do
    """
    <!DOCTYPE html>
    <html>
      <body style="margin:0;padding:0;background:#f6f6f6;">
        <div style="max-width:640px;margin:0 auto;padding:24px;background:#ffffff;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#111;line-height:1.5;">
          <h1 style="font-size:22px;margin:0 0 16px;">#{h(subject)}</h1>
          #{html}
          <hr style="border:none;border-top:1px solid #e5e5e5;margin:32px 0 16px;" />
          <p style="font-size:12px;color:#888;">
            You're receiving this because you subscribed.
            <a href="#{unsubscribe_url}" style="color:#888;">Unsubscribe</a>.
          </p>
        </div>
      </body>
    </html>
    """
  end

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
