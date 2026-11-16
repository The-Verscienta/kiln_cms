defmodule KilnCMS.Backups.DestinationConfig.Changes.StoreSecrets do
  @moduledoc """
  Encrypts a destination's `:secret` fields into
  `DestinationConfig.secrets_encrypted` (`KilnCMS.Keys.Vault`), from the
  `:secrets` argument (#2220).

    * a secret given — stored, encrypted with the others as one JSON object;
    * a secret left blank or not sent — the stored one is kept, because the
      form never holds it to send back;
    * nothing given — the column is not touched at all, so an edit of the
      name or the order never re-encrypts, and a row whose ciphertext no key
      opens keeps that ciphertext for a later `PREVIOUS_SECRET_KEY_BASE` to
      recover.

  When the stored secrets can't be decrypted, what is given replaces them:
  whatever they held is already lost, and `Validations.AdapterSettings`
  refuses the save when a required one is still missing.

  The key is derived from `SECRET_KEY_BASE` — see `docs/secrets-rotation.md`.
  Which keys are secret fields is the validation's to check; the plaintext
  never leaves this function except as ciphertext.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.DestinationConfig

  @impl true
  def change(changeset, _opts, _context) do
    case given(changeset) do
      given when map_size(given) == 0 ->
        changeset

      given ->
        stored = stored(changeset)

        Ash.Changeset.force_change_attribute(
          changeset,
          :secrets_encrypted,
          DestinationConfig.encrypt_secrets(Map.merge(stored, given))
        )
    end
  end

  @doc """
  The non-blank secrets the changeset's `:secrets` argument carries, keyed
  by string and trimmed. Values that are not strings are left out here (and
  refused by the validation).
  """
  @spec given(Ash.Changeset.t()) :: %{optional(String.t()) => String.t()}
  def given(changeset) do
    case Ash.Changeset.get_argument(changeset, :secrets) do
      secrets when is_map(secrets) ->
        for {name, value} <- secrets,
            is_binary(value),
            value = String.trim(value),
            value != "",
            into: %{},
            do: {to_string(name), value}

      _none ->
        %{}
    end
  end

  defp stored(%{action_type: :update, data: data}) do
    case DestinationConfig.decrypt_secrets(data.secrets_encrypted) do
      {:ok, secrets} -> secrets
      {:error, :undecryptable} -> %{}
    end
  end

  defp stored(_create), do: %{}
end
