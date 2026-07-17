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
  """
  use Oban.Worker, queue: :newsletter, max_attempts: 8
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Mail
  alias KilnCMS.Newsletter

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"newsletter_send_id" => send_id, "subscriber_id" => subscriber_id}
      }) do
    send = Newsletter.get_send!(send_id, authorize?: false, not_found_error?: false)

    subscriber =
      Newsletter.get_subscriber!(subscriber_id, authorize?: false, not_found_error?: false)

    cond do
      is_nil(send) ->
        {:cancel, "newsletter send #{send_id} not found"}

      is_nil(subscriber) ->
        {:cancel, "subscriber #{subscriber_id} not found"}

      subscriber.status != :confirmed ->
        {:cancel, "subscriber not confirmed (#{subscriber.status})"}

      Mail.suppressed?(to_string(subscriber.email)) ->
        {:cancel, "recipient suppressed (bounced)"}

      true ->
        deliver(send, subscriber)
    end
  end

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
        |> Mail.deliver_for_worker()
        |> record_outcome(send)

      {:error, :not_fired} ->
        {:cancel, "no fired :web artifact for #{send.content_type} #{send.content_id}"}
    end
  end

  defp record_outcome(:ok, send) do
    {:ok, _} = Newsletter.record_sent(send, authorize?: false)
    :ok
  end

  defp record_outcome({:cancel, reason}, send) do
    {:ok, _} = Newsletter.record_failed(send, authorize?: false)
    {:cancel, reason}
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
