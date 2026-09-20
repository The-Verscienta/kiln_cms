defmodule KilnCMS.CMS.Changes.StoreRelayPassword do
  @moduledoc """
  Encrypts a site's SMTP relay password into `SiteMailRelay.password_encrypted`
  (`KilnCMS.Keys.Vault`), from the `:password` argument.

    * a password given — encrypt and store it;
    * none given — keep the stored one, because the form never holds it to send
      back;
    * no username — clear it, because a password with no username is never
      sent, and keeping one nobody can see is keeping a secret for nothing;
    * a username, and no password given or stored — refuse. The relay would
      be asked to authenticate with nothing, and every send would fail.

  The key is derived from `SECRET_KEY_BASE`, so rotating that makes the stored
  password unreadable — see `docs/secrets-rotation.md`. `KilnCMS.Mail.SiteRelay`
  answers that by holding the site's mail rather than sending it through the
  operator's relay, and the settings page says the password needs re-entering.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys.Vault

  @impl true
  def change(changeset, _opts, _context) do
    cond do
      blank?(Ash.Changeset.get_attribute(changeset, :username)) ->
        Ash.Changeset.force_change_attribute(changeset, :password_encrypted, nil)

      password = present(Ash.Changeset.get_argument(changeset, :password)) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :password_encrypted,
          Vault.encrypt(password)
        )

      is_nil(changeset.data.password_encrypted) ->
        Ash.Changeset.add_error(changeset,
          field: :password,
          message: "is required when a username is set"
        )

      true ->
        changeset
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp blank?(value), do: is_nil(present(value))
end
