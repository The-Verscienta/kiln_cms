defmodule KilnCMS.Forms.NotificationWorker do
  @moduledoc """
  Mails a form's `notify_email` a summary of one accepted submission (queued
  by `KilnCMS.Forms.submit/3`, off the visitor's request path). Every value is
  visitor-supplied, so the whole table is HTML-escaped. Delivery + backoff
  mirror the workflow mails (`Mail.deliver_for_worker/2`).

  The job carries the form's and the submission's ids, never the submitted
  data (#2992): it reads the submission back when it runs
  (`KilnCMS.Forms.delivery_submission/2`). A submission deleted or marked
  spam in the meantime sends nothing.

  A job queued by a release before that carries the `data` itself. It is
  still delivered, and the `data` is dropped from its row once it finishes
  (`KilnCMS.Jobs.PrivateArgs`).

  ## Suppressed addresses (#3051)

  A `notify_email` on the instance-wide suppression list, or on the site's
  own (`KilnCMS.Mail.check_suppression/2`), is sent nothing: the job
  completes (it is not a delivery failure on /editor/mail) and logs a warning
  naming the job, the form and the site, never the address. A list that
  cannot be read raises, so the job retries rather than sending past it. Both
  job shapes are checked.
  """
  require Logger

  use Oban.Worker, queue: :mail, max_attempts: 5

  import Swoosh.Email

  alias KilnCMS.{CMS, Forms, Mail}
  alias KilnCMS.Jobs.PrivateArgs

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"form_id" => form_id, "submission_id" => submission_id} = args} = job
      ) do
    tenant = tenant(args)

    with {:ok, form} <- notifying_form(form_id, tenant),
         {:ok, submission} <- Forms.delivery_submission(submission_id, tenant),
         :ok <- Mail.check_suppression(form.notify_email, org_id: tenant) do
      deliver(job, form, submission.data, tenant)
    else
      :skip -> :ok
      {:skip, :suppressed} -> suppressed(job, form_id, tenant)
      {:error, error} -> {:error, error}
    end
  end

  # Queued before #2992, with the submitted data in the args. Remove once no
  # release that wrote this shape can still have a job queued (the Pruner
  # deletes finished rows after a week; a retrying mail job is done within a
  # day): no earlier than the release after the one that stopped writing it.
  def perform(%Oban.Job{args: %{"form_id" => form_id, "data" => data} = args} = job) do
    PrivateArgs.finishing(job, PrivateArgs.keys(__MODULE__), fn ->
      tenant = tenant(args)

      with {:ok, form} <- notifying_form(form_id, tenant),
           :ok <- Mail.check_suppression(form.notify_email, org_id: tenant) do
        deliver(job, form, data, tenant)
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
    Logger.info("form notification job #{id}: submission no longer in the job, nothing sent")
    :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # `org_id` scopes the form re-fetch to its site (epic #336); pre-#336 jobs
  # carry none — a nil tenant reads globally, finding the row by its unique id.
  defp tenant(args), do: args["org_id"] || KilnCMS.Accounts.default_org_id()

  # As the form pipeline's system actor, `authorize_with: :error` (#1659): a
  # refused read would filter to "form deleted" and the submission's
  # notification would silently never go out. A refusal fails the job,
  # which retries.
  defp notifying_form(form_id, tenant) do
    case CMS.get_form(form_id, actor: Forms.system(), authorize_with: :error, tenant: tenant) do
      {:ok, %{notify_email: to} = form} when is_binary(to) and to != "" -> {:ok, form}
      {:error, %Ash.Error.Forbidden{} = error} -> {:error, error}
      # Form deleted or notifications switched off since — nothing to send.
      _ -> :skip
    end
  end

  # `notify_email` is on the instance-wide suppression list or the site's own
  # (#3051). Completed, not cancelled: a cancelled `mail` job is listed as a
  # delivery failure on /editor/mail, and this is the list doing its job. A
  # warning, not info: an admin typed this address and is no longer told about
  # submissions. Never the address itself.
  defp suppressed(%Oban.Job{id: id}, form_id, tenant) do
    Logger.warning(
      "form notification job #{id} not sent: form #{form_id}'s notify address is " <>
        "suppressed (org #{tenant}); clear it on /editor/mail or /editor/site-mail"
    )

    :ok
  end

  defp deliver(%Oban.Job{id: id}, form, data, tenant) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(form.notify_email)
    |> subject("New submission: #{form.name}")
    |> html_body(body(form, data))
    |> Mail.ensure_message_id("form-#{id}")
    # Through the site's own relay when it has one (#1322).
    |> Mail.deliver_for_worker(org_id: tenant)
  end

  defp body(form, data) do
    rows =
      Enum.map_join(data, "", fn {key, value} ->
        "<tr><td style=\"padding:4px 12px 4px 0\"><strong>#{h(key)}</strong></td>" <>
          "<td style=\"padding:4px 0\">#{h(value)}</td></tr>"
      end)

    """
    <p>The form <strong>#{h(form.name)}</strong> received a new submission:</p>
    <table>#{rows}</table>
    """
  end

  defp h(value) do
    value |> Forms.display_value() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
