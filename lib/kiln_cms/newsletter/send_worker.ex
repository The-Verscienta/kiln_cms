defmodule KilnCMS.Newsletter.SendWorker do
  @moduledoc """
  Fan-out coordinator for a newsletter campaign.

  Enqueued once per `send_as_newsletter/2` call. Resolves the confirmed
  subscribers for the campaign's segment, stamps the recipient count, and
  enqueues one `KilnCMS.Newsletter.MailWorker` job per recipient — so the
  triggering request never blocks on delivery and each recipient retries
  independently. Runs on the dedicated `:newsletter` queue so a large blast
  can't starve transactional `:mail`.
  """
  use Oban.Worker, queue: :newsletter, max_attempts: 3

  alias KilnCMS.Newsletter
  alias KilnCMS.Newsletter.MailWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"newsletter_send_id" => send_id} = args}) do
    # The enqueuer carries the campaign's org (newsletter.ex); under strict
    # tenancy (#419) the send lookup itself needs it (default-org fallback for
    # any legacy job that predates the arg).
    tenant = args["org_id"] || KilnCMS.Accounts.default_org_id()

    case Newsletter.get_send!(send_id,
           authorize?: false,
           not_found_error?: false,
           tenant: tenant
         ) do
      nil ->
        {:cancel, "newsletter send #{send_id} not found"}

      send ->
        # The whole fan-out runs under the campaign's own site (epic #336): the
        # recipient set is that org's confirmed subscribers, and each per-recipient
        # job carries the org so `MailWorker` settles under it.
        org = send.org_id

        recipients =
          Newsletter.confirmed_subscribers!(send.segment_id, authorize?: false, tenant: org)

        {:ok, send} =
          Newsletter.mark_sending(send, %{total_recipients: length(recipients)},
            authorize?: false,
            tenant: org
          )

        Enum.each(recipients, fn subscriber ->
          %{"newsletter_send_id" => send.id, "subscriber_id" => subscriber.id, "org_id" => org}
          |> MailWorker.new()
          |> Oban.insert!()
        end)

        # "Sent" here means fully dispatched to the queue; per-recipient outcomes
        # accrue in sent_count/failed_count as the mail jobs run.
        {:ok, _} = Newsletter.mark_sent(send, authorize?: false, tenant: org)
        :ok
    end
  end
end
