defmodule KilnCMS.CMS.Validations.WebhookFormatEvents do
  @moduledoc """
  A Slack-format webhook endpoint (#2245) receives security events only: every
  name in its `events` must start with `security.`.

  Content events carry document bodies that have no meaningful Slack
  rendering, and a Slack endpoint failing them would auto-disable it and land
  the noise on the security notices. By the `security.` prefix, not by
  membership of `KilnCMS.CMS.WebhookEndpoint.security_events/0`, so a kind a
  later release adds is allowed too, as the console's picker treats it.

  On `:create` always; on `:update` only when `events` (or `format`, which
  `:update` does not accept) is changing, so an endpoint saved before this
  rule can still be switched on or off.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    with :slack <- Ash.Changeset.get_attribute(changeset, :format),
         true <-
           changeset.action_type == :create or
             Ash.Changeset.changing_attribute?(changeset, :events) or
             Ash.Changeset.changing_attribute?(changeset, :format),
         [_ | _] <- non_security(Ash.Changeset.get_attribute(changeset, :events)) do
      {:error,
       InvalidAttribute.exception(
         field: :events,
         # Translated where the form shows it (`translate_error/1`).
         message: dgettext_noop("errors", "Slack endpoints can only receive security events")
       )}
    else
      _ -> :ok
    end
  end

  defp non_security(events),
    do: events |> List.wrap() |> Enum.reject(&match?("security." <> _, &1))

  @impl true
  def describe(_opts),
    do: [message: "Slack endpoints can only receive security events", vars: []]
end
