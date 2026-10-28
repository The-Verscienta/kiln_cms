defmodule KilnCMS.Provenance.Settings do
  @moduledoc """
  The instance's generated content-signing key (#1929): one row, written once.

  Provenance is on by default from 1.7, and signing needs a key. An operator
  can still mount one (`KILN_PROVENANCE_KEY_FILE`, or the
  `KILN_PROVENANCE_PRIVATE_KEY` variable the compiled config names), and that
  wins. A fresh install that sets neither gets one from `/setup`: an RSA-2048
  PEM generated here and stored AES-256-GCM-encrypted under
  `secret_key_base` (`KilnCMS.Keys.Vault`), the same at-rest model as the
  database-provider DKIM key, and rotated with it by
  `mix kiln.vault.reencrypt`.

  There is no rotate action on purpose. A manifest names the key that signed
  it, and replacing this one would leave every manifest signed with it
  unverifiable unless its public half were registered as retired first. An
  operator who wants another key mounts it and registers this one's public
  half (`public_key_pem/0`) through `KILN_PROVENANCE_RETIRED_KEY_FILES`.

  Instance-wide and tenant-less, so platform-admin only, like
  `KilnCMS.Mail.Settings`. Signing reads the row as the system
  (`KilnCMS.Provenance.stored_key/0`).
  """
  use Ash.Resource,
    domain: KilnCMS.Firing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "provenance_settings"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # Generates the key. A second call fails on the singleton identity: a key
    # that signed manifests is never silently replaced.
    create :generate do
      accept []
      change KilnCMS.Provenance.Settings.Changes.GenerateKey
    end
  end

  policies do
    # PLATFORM-admin only: tenant-less, like `Mail.Settings` (#419). `/setup`
    # generates the key as the admin it has just created.
    policy always() do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end
  end

  attributes do
    uuid_primary_key :id

    # Constant column backing the unique "there is one row" identity.
    attribute :singleton, :integer do
      allow_nil? false
      default 0
      writable? false
    end

    attribute :private_key_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      allow_nil? false
      sensitive? true
      writable? false
    end

    # `sha256:<hex>` over the SPKI DER, as manifests name it.
    attribute :key_id, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    # An RSA-2048 public key PEM is about 450 bytes.
    attribute :public_key_pem, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    timestamps()
  end

  identities do
    identity :singleton_row, [:singleton]
  end
end
