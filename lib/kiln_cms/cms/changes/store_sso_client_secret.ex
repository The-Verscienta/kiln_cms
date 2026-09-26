defmodule KilnCMS.CMS.Changes.StoreSsoClientSecret do
  @moduledoc """
  Encrypts a site's OIDC client secret into
  `SiteSsoProvider.client_secret_encrypted` (`KilnCMS.Keys.Vault`), from the
  `:client_secret` argument.

    * a secret given — encrypt and store it;
    * none given — keep the stored one, because the form never holds it to send
      back;
    * none given or stored, on a provider that is switched on — refuse. Every
      sign-in would fail at the token endpoint.

  The key is derived from `SECRET_KEY_BASE`, so rotating that makes the stored
  secret unreadable — see `docs/secrets-rotation.md`. `KilnCMS.Accounts.SiteSso`
  answers that by making the site's single sign-on unavailable (never by
  offering the operator's provider instead), and the settings page says the
  secret needs re-entering.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys.Vault

  @impl true
  def change(changeset, _opts, _context) do
    cond do
      secret = present(Ash.Changeset.get_argument(changeset, :client_secret)) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :client_secret_encrypted,
          Vault.encrypt(secret)
        )

      is_nil(changeset.data.client_secret_encrypted) and
          Ash.Changeset.get_attribute(changeset, :enabled) == true ->
        Ash.Changeset.add_error(changeset,
          field: :client_secret,
          message: "is required"
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
end
