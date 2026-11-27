defmodule KilnCMS.Forms.AutoresponderWorker do
  @moduledoc """
  Mails a form's **submitter** their confirmation email (#468,
  `KilnCMS.Forms.Autoresponder`) — the twin of `KilnCMS.Forms.NotificationWorker`,
  which mails the admin instead. Queued by `KilnCMS.Forms.submit/3`'s internal
  record step only when `Autoresponder.eligible?/3` found somewhere to send
  it. Delivery + backoff mirror the other mail workers
  (`Mail.deliver_for_worker/2`).

  The job carries the form's and the submission's ids, never the submitted
  data or the submitter's address (#2992). It reads the submission back when
  it runs (`KilnCMS.Forms.delivery_submission/2`) and asks
  `Autoresponder.eligible?/3` again against the form as it is then: a
  submission deleted or marked spam since, an autoresponder switched off, or
  an email field removed or renamed since sends nothing.

  A job queued by a release before that carries the `data` and the `to`
  address itself. It is still delivered to that address, and both are dropped
  from its row once it finishes (`KilnCMS.Jobs.PrivateArgs`).

  ## Suppressed addresses (#3051)

  Visitors type this address, so it is the mail most likely to reach a dead or
  complaining mailbox. An address on the instance-wide suppression list, or on
  the site's own (`KilnCMS.Mail.check_suppression/2`), is sent nothing: the
  job completes (it is not a delivery failure on /editor/mail) and logs at
  info level, naming the job, the form and the site, never the address. A
  list that cannot be read raises, so the job retries rather than sending past
  it. Both job shapes are checked; a legacy job's `data` and `to` are dropped
  on a skip as on a send.
  """
  require Logger

  use Oban.Worker, queue: :mail, max_attempts: 5

  import Swoosh.Email

  alias KilnCMS.{CMS, Forms}
  alias KilnCMS.Forms.Autoresponder
  alias KilnCMS.Jobs.PrivateArgs
  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"form_id" => form_id, "submission_id" => submission_id} = args} = job
      ) do
    tenant = tenant(args)

    with {:ok, form, fields} <- responding_form(form_id, tenant),
         {:ok, submission} <- Forms.delivery_submission(submission_id, tenant),
         {true, to} <- Autoresponder.eligible?(form, submission.data, fields),
         :ok <- Mail.check_suppression(to, org_id: tenant) do
      deliver(job, form, fields, to, submission.data, tenant)
    else
      :skip -> :ok
      false -> :ok
      {:skip, :suppressed} -> suppressed(job, form_id, tenant)
      {:error, error} -> {:error, error}
    end
  end

  # Queued before #2992, with the submitted data and the address in the args.
  # Remove on the same terms as `NotificationWorker`'s legacy clause.
  def perform(%Oban.Job{args: %{"form_id" => form_id, "to" => to, "data" => data} = args} = job) do
    PrivateArgs.finishing(job, PrivateArgs.keys(__MODULE__), fn ->
      tenant = tenant(args)

      with {:ok, form, fields} <- responding_form(form_id, tenant),
           :ok <- Mail.check_suppression(to, org_id: tenant) do
        deliver(job, form, fields, to, data, tenant)
      else
        :skip -> :ok
        {:skip, :suppressed} -> suppressed(job, form_id, tenant)
        {:error, error} -> {:error, error}
      end
    end)
  end

  # A job holding neither shape: a legacy job whose `data` was already dropped
  # (`PrivateArgs.finishing/3` forgets before Oban acks it, so a node lost in
  # between leaves it executing with no data, and Lifeline re-queues it). The
  # mail went out; nothing is left to send.
  def perform(%Oban.Job{id: id}) do
    # `:ok`, not `{:cancel, _}`: a cancelled `mail` job is listed as a delivery
    # failure on /editor/mail, and nothing failed here.
    Logger.info("form autoresponder job #{id}: submission no longer in the job, nothing sent")
    :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # `org_id` scopes the form/fields re-fetch to its site (epic #336), same
  # reasoning as NotificationWorker's re-fetch.
  defp tenant(args), do: args["org_id"] || KilnCMS.Accounts.default_org_id()

  # As the form pipeline's system actor, `authorize_with: :error` (#1659): a
  # refused read would filter to "form deleted" (or "no fields", which
  # renders every `[field:…]` token empty) and the visitor's confirmation
  # would silently never go out. A refusal fails the job, which retries.
  defp responding_form(form_id, tenant) do
    opts = [actor: Forms.system(), authorize_with: :error, tenant: tenant]

    case CMS.get_form(form_id, opts) do
      {:ok, %{autoresponder_enabled: true} = form} ->
        {:ok, form, CMS.form_fields_for!(form_id, opts)}

      {:error, %Ash.Error.Forbidden{} = error} ->
        {:error, error}

      # Form deleted or the autoresponder switched off since it was queued —
      # nothing to send. (Not an error: the visitor's submission still
      # succeeded; this is best-effort follow-up mail.)
      _ ->
        :skip
    end
  end

  # The submitter's address is on the instance-wide suppression list or the
  # site's own (#3051). Completed, not cancelled: a cancelled `mail` job is
  # listed as a delivery failure on /editor/mail. Info, not a warning: the
  # visitor typed this address, and a bounced one is the list working. Never
  # the address itself.
  defp suppressed(%Oban.Job{id: id}, form_id, tenant) do
    Logger.info(
      "form autoresponder job #{id} not sent: the submitter's address is suppressed " <>
        "(form #{form_id}, org #{tenant})"
    )

    :ok
  end

  defp deliver(%Oban.Job{id: id}, form, fields, to, data, tenant) do
    {subject, body} = Autoresponder.render(form, fields, data)

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to)
    |> subject(subject)
    |> html_body(body)
    |> Mail.ensure_message_id("form-autoresponder-#{id}")
    # Through the site's own relay when it has one (#1322).
    |> Mail.deliver_for_worker(org_id: tenant)
  end
end
