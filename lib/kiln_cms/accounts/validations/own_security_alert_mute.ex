defmodule KilnCMS.Accounts.Validations.OwnSecurityAlertMute do
  @moduledoc """
  Only the account holder may change their own alert preferences:
  `notify_on_security_alert` (#2245) and `notify_on_backup` (#2229).
  `:update_notification_prefs` is otherwise open to a platform admin for
  anyone (the policy bypass), and an alert someone else can mute for you is
  one an intruder holding that power would mute first.

  `fields:` names the guarded attributes (default
  `[:notify_on_security_alert]`). A change to any other preference by a
  platform admin is still allowed.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    case Keyword.get(opts, :fields, [:notify_on_security_alert]) do
      [_ | _] = fields -> {:ok, Keyword.put(opts, :fields, fields)}
      _other -> {:error, "fields must be a non-empty list of attributes"}
    end
  end

  @impl true
  def validate(changeset, opts, context) do
    actor_id =
      case context.actor do
        %{id: id} -> id
        _none -> nil
      end

    guarded =
      opts
      |> Keyword.get(:fields, [:notify_on_security_alert])
      |> Enum.find(&Ash.Changeset.changing_attribute?(changeset, &1))

    if guarded && actor_id != changeset.data.id do
      {:error,
       InvalidAttribute.exception(
         field: guarded,
         message: "can only be changed by the account holder"
       )}
    else
      :ok
    end
  end
end
