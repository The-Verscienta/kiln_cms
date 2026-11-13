defmodule KilnCMS.Security.Validations.PlatformAlertKinds do
  @moduledoc """
  A platform admin may turn off only the platform alert kinds this release
  lets them (`KilnCMS.Security.Alerts.platform_optional_kinds/0`), checked
  for the kinds a save **adds** to `disabled_kinds` (#2245), the way
  `KilnCMS.CMS.Validations.SecurityAlertKinds` checks a site's: a kind a newer
  release made optional and turned off stays in the row after a rollback, and
  refusing every later save over it would leave the setting unsaveable.

  The stored row is read as `KilnCMS.Security.alerts_system/0` with
  `authorize_with: :error`; one that cannot be read is the empty baseline,
  the strict direction.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts

  @impl true
  def validate(changeset, _opts, _context) do
    submitted = Ash.Changeset.get_attribute(changeset, :disabled_kinds) || []
    optional = Enum.map(Alerts.platform_optional_kinds(), &Atom.to_string/1)

    case (submitted -- stored()) -- optional do
      [] ->
        :ok

      refused ->
        {:error,
         InvalidAttribute.exception(
           field: :disabled_kinds,
           message: "has alert kinds that cannot be turned off: %{kinds}",
           vars: [kinds: Enum.join(refused, ", ")]
         )}
    end
  end

  defp stored do
    case Security.list_platform_alert_settings(
           actor: Security.alerts_system(),
           authorize_with: :error
         ) do
      {:ok, [row | _]} -> row.disabled_kinds || []
      _none_or_unreadable -> []
    end
  end
end
