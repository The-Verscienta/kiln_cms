defmodule KilnCMS.CMS.Changes.StoreMeilisearchKey do
  @moduledoc """
  Encrypts a site's Meilisearch API key into `SiteMeilisearch.api_key_encrypted`
  (`KilnCMS.Keys.Vault`), from the `:api_key` argument.

    * a key given — encrypt and store it;
    * none given — keep the stored one, because the form never holds it to send
      back;
    * none given or stored, and the row switched on — refuse. Every request
      would be refused by the instance, and the site's search would sit in
      retries until someone noticed.

  The key is derived from `SECRET_KEY_BASE`, so rotating that makes the stored
  key unreadable — see `docs/secrets-rotation.md`.
  `KilnCMS.Search.Meilisearch.SiteInstance` answers that by holding the site's
  indexing (and sending its search to Postgres), never by using the operator's
  instance, and the settings page says the key needs re-entering.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys.Vault

  @impl true
  def change(changeset, _opts, _context) do
    cond do
      key = present(Ash.Changeset.get_argument(changeset, :api_key)) ->
        Ash.Changeset.force_change_attribute(changeset, :api_key_encrypted, Vault.encrypt(key))

      is_nil(changeset.data.api_key_encrypted) and
          Ash.Changeset.get_attribute(changeset, :enabled) == true ->
        Ash.Changeset.add_error(changeset, field: :api_key, message: "is required")

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
