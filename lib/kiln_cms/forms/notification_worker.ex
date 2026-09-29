defmodule KilnCMS.Forms.NotificationWorker do
  @moduledoc """
  Mails a form's `notify_email` a summary of one accepted submission (queued
  by `KilnCMS.Forms.submit/3`, off the visitor's request path). Every value is
  visitor-supplied, so the whole table is HTML-escaped. Delivery + backoff
  mirror the workflow mails (`Mail.deliver_for_worker/2`).
  """
  use Oban.Worker, queue: :mail, max_attempts: 5

  import Swoosh.Email

  alias KilnCMS.{CMS, Forms, Mail}

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"form_id" => form_id, "data" => data} = args}) do
    # `org_id` scopes the form re-fetch to its site (epic #336); pre-#336 jobs
    # carry none — a nil tenant reads globally, finding the row by its unique id.
    tenant = args["org_id"] || KilnCMS.Accounts.default_org_id()

    # As the form pipeline's system actor, `authorize_with: :error` (#1659): a
    # refused read would filter to "form deleted" and the submission's
    # notification would silently never go out. A refusal fails the job,
    # which retries.
    case CMS.get_form(form_id, actor: Forms.system(), authorize_with: :error, tenant: tenant) do
      {:ok, %{notify_email: to} = form} when is_binary(to) and to != "" ->
        new()
        |> from(Application.fetch_env!(:kiln_cms, :email_from))
        |> to(to)
        |> subject("New submission: #{form.name}")
        |> html_body(body(form, data))
        |> Mail.ensure_message_id("form-#{id}")
        # Through the site's own relay when it has one (#1322).
        |> Mail.deliver_for_worker(org_id: tenant)

      {:error, %Ash.Error.Forbidden{} = error} ->
        {:error, error}

      # Form deleted or notifications switched off since — nothing to send.
      _ ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

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
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
