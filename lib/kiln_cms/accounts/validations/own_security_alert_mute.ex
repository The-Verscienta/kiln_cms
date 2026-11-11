defmodule KilnCMS.Accounts.Validations.OwnSecurityAlertMute do
  @moduledoc """
  Only the account holder may change their own `notify_on_security_alert`
  (#2245). `:update_notification_prefs` is otherwise open to a platform admin
  for anyone (the policy bypass), and a security alert someone else can mute
  for you is one an intruder holding that power would mute first.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, context) do
    actor_id =
      case context.actor do
        %{id: id} -> id
        _none -> nil
      end

    if Ash.Changeset.changing_attribute?(changeset, :notify_on_security_alert) and
         actor_id != changeset.data.id do
      {:error,
       InvalidAttribute.exception(
         field: :notify_on_security_alert,
         message: "can only be changed by the account holder"
       )}
    else
      :ok
    end
  end
end
