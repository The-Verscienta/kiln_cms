defmodule KilnCMS.CMS.Validations.SecurityAlertKinds do
  @moduledoc """
  A site may turn off only the security alert kinds this release knows
  (`KilnCMS.Security.Alerts.site_kinds/0`) — checked for the kinds a write
  **adds** to `disabled_kinds`, not for the ones already stored (#2245).

  A kind a newer release added and the site turned off stays in the row after
  a rollback; refusing every later save over it would leave the page unable to
  save anything. So the stored list is the baseline: on `:update` the row being
  updated, on the `:save` upsert the site's current row, read as
  `KilnCMS.OrgSettings.system(:security_alerts)`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Security.Alerts

  @impl true
  def validate(changeset, _opts, _context) do
    submitted = Ash.Changeset.get_attribute(changeset, :disabled_kinds) || []
    known = Enum.map(Alerts.site_kinds(), &Atom.to_string/1)

    case (submitted -- stored(changeset)) -- known do
      [] ->
        :ok

      unknown ->
        {:error,
         InvalidAttribute.exception(
           field: :disabled_kinds,
           message: "has unknown alert kinds: %{kinds}",
           vars: [kinds: Enum.join(unknown, ", ")]
         )}
    end
  end

  defp stored(%{action_type: :update, data: data}), do: data.disabled_kinds || []

  defp stored(changeset) do
    case KilnCMS.CMS.list_site_security_alerts(
           tenant: changeset.tenant,
           actor: KilnCMS.OrgSettings.system(:security_alerts),
           authorize_with: :error
         ) do
      {:ok, [row | _]} -> row.disabled_kinds || []
      _none -> []
    end
  end
end
