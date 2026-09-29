defmodule KilnCMS.Newsletter.SendWorker do
  @moduledoc """
  Fan-out coordinator for a newsletter campaign.

  Enqueued once per `send_as_newsletter/2` call. Resolves the confirmed
  subscribers for the campaign's segment, stamps the recipient count, and
  enqueues one `KilnCMS.Newsletter.MailWorker` job per recipient — so the
  triggering request never blocks on delivery and each recipient retries
  independently. Runs on the dedicated `:newsletter` queue so a large blast
  can't starve transactional `:mail`.

  ## Safe to re-run

  A second run of the same send — a retry after a crash part-way through the
  fan-out, or a rescue by `Oban.Lifeline` after a deploy killed it (#1718) —
  re-enqueues only the recipients the first run did not reach: `MailWorker`
  is `unique` on `{newsletter_send_id, subscriber_id}` across every job
  state, so a recipient who already has a job (queued, delivered, or
  cancelled) is not mailed twice.

  ## Authorization

  Runs as `KilnCMS.Newsletter.system/0` (#1659), admitted on `NewsletterSend`
  for the read and the `mark_*` bookkeeping and on `Subscriber` for the
  `:confirmed` read. Both reads fail closed: a refusal is logged and retried,
  never read as "no such send" or "no subscribers".
  """
  use Oban.Worker, queue: :newsletter, max_attempts: 3

  require Logger

  alias KilnCMS.Newsletter
  alias KilnCMS.Newsletter.MailWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"newsletter_send_id" => send_id, "org_id" => tenant}})
      when is_binary(tenant) do
    # The enqueuer carries the campaign's org (newsletter.ex); under strict
    # tenancy (#419) the send lookup itself needs it.
    #
    # As `Newsletter.system/0` (#1659), failing CLOSED: a refused read under
    # the filter answers `nil`, which is "send not found" and would cancel the
    # campaign for good. `authorize_with: :error` makes it a Forbidden, which
    # is logged and retried.
    case Newsletter.get_send(send_id,
           actor: Newsletter.system(),
           authorize_with: :error,
           not_found_error?: false,
           tenant: tenant
         ) do
      {:ok, nil} -> {:cancel, "newsletter send #{send_id} not found"}
      {:ok, send} -> fan_out(send)
      {:error, error} -> retry("read newsletter send #{send_id}", error)
    end
  end

  # A job with no `org_id` was enqueued by a release before 0.12, which ran it
  # against the default org with a deprecation warning. 1.0 removed that
  # fallback (#1543): the job is cancelled with a logged error, never retried.
  def perform(%Oban.Job{args: args}),
    do: KilnCMS.Deprecations.cancel_legacy_job(__MODULE__, args)

  # The whole fan-out runs under the campaign's own site (epic #336): the
  # recipient set is that org's confirmed subscribers, and each per-recipient
  # job carries the org so `MailWorker` settles under it.
  defp fan_out(send) do
    org = send.org_id

    # The recipient list is the decision this job exists to make, so it fails
    # CLOSED (#1659): a refused read under the filter answers `[]`, and `[]`
    # would stamp zero recipients and mark the campaign `:sent` having mailed
    # nobody, with no way to send it again. With `:error` the job logs and
    # retries, and the campaign stays where it was.
    with {:ok, recipients} <-
           Newsletter.confirmed_subscribers(send.segment_id,
             actor: Newsletter.system(),
             authorize_with: :error,
             tenant: org
           ),
         {:ok, send} <-
           Newsletter.mark_sending(send, %{total_recipients: length(recipients)},
             actor: Newsletter.system(),
             tenant: org
           ) do
      Enum.each(recipients, fn subscriber ->
        %{"newsletter_send_id" => send.id, "subscriber_id" => subscriber.id, "org_id" => org}
        |> MailWorker.new()
        |> Oban.insert!()
      end)

      # "Sent" here means fully dispatched to the queue; per-recipient outcomes
      # accrue in sent_count/failed_count as the mail jobs run. A failure here
      # retries the job, which enqueues nobody twice (see "Safe to re-run").
      case Newsletter.mark_sent(send, actor: Newsletter.system(), tenant: org) do
        {:ok, _send} -> :ok
        {:error, error} -> retry("mark newsletter send #{send.id} sent", error)
      end
    else
      {:error, error} -> retry("fan out newsletter send #{send.id}", error)
    end
  end

  defp retry(what, error) do
    Logger.error(
      "Newsletter.SendWorker could not #{what}, will retry: " <> Exception.message(error)
    )

    {:error, error}
  end
end
