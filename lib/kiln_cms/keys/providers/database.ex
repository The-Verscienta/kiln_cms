defmodule KilnCMS.Keys.Providers.Database do
  @moduledoc """
  Key provider for material stored AES-256-GCM-encrypted in the settings row
  (`KilnCMS.Keys.Vault`). The zero-ops default — a key generated in the admin
  UI just works — but the least-preferred production tier: its encryption key
  derives from `secret_key_base`, so rotating that secret orphans the stored
  key unless the rotation keeps the old value readable and re-encrypts
  (`PREVIOUS_SECRET_KEY_BASE`, `mix kiln.vault.reencrypt` — #1487; see
  `docs/secrets-rotation.md`). Env/file providers are immune.

  `config` is assembled in-memory by `KilnCMS.Keys` from the settings row
  (`%{"encrypted" => <binary>}`); nothing secret is persisted in the
  provider-config column itself.
  """
  @behaviour KilnCMS.Keys.Provider

  alias KilnCMS.Keys.Vault

  @impl true
  def fetch(config) do
    case config["encrypted"] do
      nil -> {:error, :no_key_generated}
      encrypted -> Vault.decrypt(encrypted)
    end
  end

  @impl true
  def writable?, do: true
end
