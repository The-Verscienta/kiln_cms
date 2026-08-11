defmodule KilnCMS.Forms.AutoresponderWorker do
  @moduledoc """
  Mails a form's **submitter** their confirmation email (#468,
  `KilnCMS.Forms.Autoresponder`) — the twin of `KilnCMS.Forms.NotificationWorker`,
  which mails the admin instead. Queued by `KilnCMS.Forms.submit/3`'s internal
  record step only when `Autoresponder.eligible?/3` found somewhere to send
  it. Delivery + backoff mirror the other mail workers
  (`Mail.deliver_for_worker/2`).
  """
  use Oban.Worker, queue: :mail, max_attempts: 5

  import Swoosh.Email

  alias KilnCMS.CMS
  alias KilnCMS.Forms.Autoresponder
  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: id,
        args: %{"form_id" => form_id, "to" => to, "data" => data} = args
      }) do
    # `org_id` scopes the form/fields re-fetch to its site (epic #336), same
    # reasoning as NotificationWorker's re-fetch.
    tenant = args["org_id"] || KilnCMS.Accounts.default_org_id()

    case CMS.get_form(form_id, authorize?: false, tenant: tenant) do
      {:ok, %{autoresponder_enabled: true} = form} ->
        fields = CMS.form_fields_for!(form_id, authorize?: false, tenant: tenant)
        {subject, body} = Autoresponder.render(form, fields, data)

        new()
        |> from(Application.fetch_env!(:kiln_cms, :email_from))
        |> to(to)
        |> subject(subject)
        |> html_body(body)
        |> Mail.ensure_message_id("form-autoresponder-#{id}")
        |> Mail.deliver_for_worker()

      # Form deleted or the autoresponder switched off since it was queued —
      # nothing to send. (Not an error: the visitor's submission still
      # succeeded; this is best-effort follow-up mail.)
      _ ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)
end
