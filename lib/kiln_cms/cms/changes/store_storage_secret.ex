defmodule KilnCMS.CMS.Changes.StoreStorageSecret do
  @moduledoc """
  Encrypts a site's object-storage secret access key into
  `StorageProfile.secret_access_key_encrypted` (`KilnCMS.Keys.Vault`), from
  the `:secret_access_key` argument.

    * a secret given — encrypt and store it;
    * none given, on an update — keep the stored one, because the form never
      holds it to send back;
    * none given, on a create — take the `:secret_access_key_encrypted`
      argument (a moved site keeping its key, see
      `Changes.SaveStorageProfile`), else refuse: a profile nobody can sign a
      request with would fail every upload.

  The key is derived from `SECRET_KEY_BASE`, so rotating that makes the stored
  secret unreadable — see `docs/secrets-rotation.md`.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys.Vault

  @impl true
  def change(changeset, _opts, _context) do
    secret = present(Ash.Changeset.get_argument(changeset, :secret_access_key))

    cond do
      secret ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :secret_access_key_encrypted,
          Vault.encrypt(secret)
        )

      changeset.action_type == :create ->
        carry(changeset)

      true ->
        changeset
    end
  end

  defp carry(changeset) do
    case Ash.Changeset.get_argument(changeset, :secret_access_key_encrypted) do
      encrypted when is_binary(encrypted) ->
        Ash.Changeset.force_change_attribute(changeset, :secret_access_key_encrypted, encrypted)

      _none ->
        Ash.Changeset.add_error(changeset, field: :secret_access_key, message: "is required")
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
