defmodule KilnCMS.CMS.Changes.StoreAiApiKey do
  @moduledoc """
  Encrypts a site's AI provider API key into `SiteAiProvider.api_key_encrypted`
  (`KilnCMS.Keys.Vault`), from the `:api_key` argument.

    * a key given — encrypt and store it;
    * none given, and the provider and base URL unchanged — keep the stored
      one, because the form never holds it to send back;
    * none given, and the provider or base URL **changed** — drop it. The key
      was entered for the old destination, and the form never showed it to
      whoever is editing now; keeping it would let an edit send a secret the
      editor never saw to a host the editor chose;
    * a hosted provider with no key given or kept — refuse. Every request
      would fail, and worse, an empty key is the case where a client library
      goes looking for one of its own (see `KilnCMS.LLM.SiteProvider`).

  An `:openai_compatible` endpoint may have no key (a self-hosted server that
  takes none). A hosted provider's `base_url` is cleared, since it is never
  used and a stale one on the row would read as if it were.

  The key is derived from `SECRET_KEY_BASE`, so rotating that makes the stored
  key unreadable — see `docs/secrets-rotation.md`. `KilnCMS.LLM.SiteProvider`
  answers that by refusing the site's AI requests rather than sending them
  through the operator's provider, and the settings page says the key needs
  re-entering.
  """
  use Ash.Resource.Change

  alias KilnCMS.Keys.Vault

  @impl true
  def change(changeset, _opts, _context) do
    provider = Ash.Changeset.get_attribute(changeset, :provider)
    changeset = clear_unused_base_url(changeset, provider)

    cond do
      key = present(Ash.Changeset.get_argument(changeset, :api_key)) ->
        Ash.Changeset.force_change_attribute(changeset, :api_key_encrypted, Vault.encrypt(key))

      destination_changed?(changeset) ->
        changeset
        |> Ash.Changeset.force_change_attribute(:api_key_encrypted, nil)
        |> require_key(provider, "must be entered again when the provider or URL changes")

      is_nil(changeset.data.api_key_encrypted) ->
        require_key(changeset, provider, "is required for this provider")

      true ->
        changeset
    end
  end

  defp clear_unused_base_url(changeset, :openai_compatible), do: changeset

  defp clear_unused_base_url(changeset, _hosted),
    do: Ash.Changeset.force_change_attribute(changeset, :base_url, nil)

  # Only an existing row has a destination to change from. A create — including
  # the upsert, whose conflict path leaves the stored key alone anyway — has
  # nothing to drop.
  defp destination_changed?(%{action_type: :update, data: data} = changeset) do
    not is_nil(data.api_key_encrypted) and
      (Ash.Changeset.get_attribute(changeset, :provider) != data.provider or
         Ash.Changeset.get_attribute(changeset, :base_url) != data.base_url)
  end

  defp destination_changed?(_changeset), do: false

  defp require_key(changeset, :openai_compatible, _message), do: changeset

  defp require_key(changeset, _hosted, message),
    do: Ash.Changeset.add_error(changeset, field: :api_key, message: message)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
