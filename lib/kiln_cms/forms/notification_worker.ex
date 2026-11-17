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
  """
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
         {:ok, submission} <- Forms.delivery_submission(submission_id, tenant) do
      deliver(job, form, submission.data, tenant)
    else
      :skip -> :ok
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

      case notifying_form(form_id, tenant) do
        {:ok, form} -> deliver(job, form, data, tenant)
        :skip -> :ok
        {:error, error} -> {:error, error}
      end
    end)
  end

  # A job holding neither shape: a legacy job whose `data` was already dropped
  # (`PrivateArgs.finishing/3` forgets before Oban acks it, so a node lost in
  # between leaves it executing with no data, and Lifeline re-queues it). The
  # mail went out; nothing is left to send.
  def perform(%Oban.Job{}), do: {:cancel, "form submission no longer in the job"}

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
