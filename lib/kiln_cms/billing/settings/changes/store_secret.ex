defmodule KilnCMS.Billing.Settings.Changes.StoreSecret do
  @moduledoc """
  Encrypt a pasted billing secret into its database column and switch that
  secret's provider to `:database`.

  The zero-ops default tier: no env var or mounted file to arrange, at the cost
  of an encryption key derived from `SECRET_KEY_BASE`
  (`KilnCMS.Keys.Providers.Database`). Rotating `SECRET_KEY_BASE` therefore
  invalidates the stored secret — `KilnCMS.Keys.describe_error/1` says as much
  when decryption later fails.

  The pasted value is trimmed: a key copied from a dashboard or a mounted secret
  file routinely carries trailing whitespace, which would otherwise be sent
  inside the `Authorization` header.
  """
  use Ash.Resource.Change

  alias KilnCMS.Billing.Settings
  alias KilnCMS.Keys.Vault

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &store/1)
  end

  defp store(changeset) do
    key = Ash.Changeset.get_argument(changeset, :key)
    value = changeset |> Ash.Changeset.get_argument(:value) |> to_string() |> String.trim()

    {provider_field, config_field, encrypted_field} = Settings.fields(key)

    if value == "" do
      Ash.Changeset.add_error(changeset, field: :value, message: "can't be blank")
    else
      changeset
      |> Ash.Changeset.force_change_attribute(provider_field, :database)
      # The pointer config is meaningless for the database provider, and leaving
      # a stale env var name behind would misreport the source in the console.
      |> Ash.Changeset.force_change_attribute(config_field, %{})
      |> Ash.Changeset.force_change_attribute(encrypted_field, Vault.encrypt(value))
    end
  end
end
