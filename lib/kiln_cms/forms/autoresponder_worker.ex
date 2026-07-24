defmodule KilnCMS.Forms.AutoresponderWorker do
  @moduledoc """
  Mails the submitter a confirmation of their own submission (phase 6) —
  queued by `KilnCMS.Forms.submit/3` when the form has the autoresponder
  enabled and the visitor supplied an email. Subject and body come from the
  form's templates with `{{field_name}}` placeholders interpolated from the
  submitted data; every value is visitor-supplied, so the body is
  HTML-escaped before the (escape-free) placeholders are substituted with
  escaped values. Delivery + backoff mirror `NotificationWorker`.
  """
  use Oban.Worker, queue: :mail, max_attempts: 5

  import Swoosh.Email

  alias KilnCMS.{CMS, Mail}

  @placeholder ~r/\{\{\s*([a-z][a-z0-9_]*)\s*\}\}/

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"form_id" => form_id, "data" => data, "to" => to} = args}) do
    case CMS.get_form(form_id,
           authorize?: false,
           tenant: args["org_id"] || KilnCMS.Accounts.default_org_id()
         ) do
      {:ok, %{autoresponder_enabled: true} = form} ->
        email =
          new()
          |> from(Application.fetch_env!(:kiln_cms, :email_from))
          |> to(to)
          |> subject(interpolate(form.autoresponder_subject || "", data, & &1))
          |> html_body(body(form, data))
          |> Mail.ensure_message_id("form-auto-#{id}")

        # Replies should reach the site's inbox, not bounce off the sender.
        email =
          case reply_to(form) do
            nil -> email
            address -> reply_to(email, address)
          end

        Mail.deliver_for_worker(email)

      # Form deleted or the autoresponder switched off since — nothing to send.
      _ ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  defp reply_to(%{notify_email: notify}) when is_binary(notify) and notify != "" do
    notify |> String.split(",") |> List.first() |> String.trim()
  end

  defp reply_to(_form), do: nil

  # Escape the template FIRST (placeholders carry no HTML characters, so they
  # survive), then substitute escaped values — untrusted data never lands raw.
  defp body(form, data) do
    (form.autoresponder_body || "")
    |> h()
    |> interpolate(data, &h/1)
    |> String.replace("\n", "<br>\n")
  end

  defp interpolate(template, data, transform) do
    Regex.replace(@placeholder, template, fn _match, name ->
      data |> Map.get(name, "") |> display() |> transform.()
    end)
  end

  defp display(value) when is_list(value), do: Enum.join(value, ", ")
  defp display(value), do: to_string(value)

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
