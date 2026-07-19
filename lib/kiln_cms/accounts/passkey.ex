defmodule KilnCMS.Accounts.Passkey do
  @moduledoc """
  A WebAuthn credential ("passkey") registered to a user account (#331).

  One row per authenticator credential: the base64url credential id (the
  client-side handle), the COSE public key it verified with, and the signature
  counter for clone detection. A user can hold several (laptop, phone, security
  key). The ceremony itself — challenge minting, attestation and assertion
  verification — lives in `KilnCMS.Accounts.WebAuthn`; this resource is the
  storage + self-service management surface (list/rename/remove in
  `/editor/settings`).

  Writes happen only from the ceremony code after cryptographic verification
  (`authorize?: false` system calls); the policies expose reads and destroys to
  the credential's owner (and admins).
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "passkeys"
    repo KilnCMS.Repo

    references do
      reference :user, on_delete: :delete
    end

    custom_indexes do
      # The settings page lists by user; sign-in looks up by credential id
      # (served by the unique identity index).
      index [:user_id]
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_user do
      description "A user's registered passkeys (backs /editor/settings)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    # Called by KilnCMS.Accounts.WebAuthn after Wax verified the attestation —
    # never from user input directly.
    create :register do
      accept [:user_id, :name, :credential_id, :public_key, :sign_count]
    end

    # Post-authentication bookkeeping (clone-detection counter + last use).
    update :bump_usage do
      accept [:sign_count]
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Owners see and manage their own credentials.
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # `register`/`bump_usage` run `authorize?: false` from the ceremony code.
    policy action([:register, :bump_usage]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    # A user-facing label ("MacBook Touch ID", "YubiKey").
    attribute :name, :string do
      allow_nil? false
      default "Passkey"
      public? true
    end

    # base64url (unpadded) encoding of the raw credential id — globally unique
    # per WebAuthn spec (enforced by the identity below).
    attribute :credential_id, :string do
      allow_nil? false
      public? false
    end

    # The COSE public key as an Erlang term (`:erlang.term_to_binary/1` of the
    # CBOR-decoded map Wax returns) — opaque storage, decoded only for Wax.
    attribute :public_key, :binary do
      allow_nil? false
      public? false
      sensitive? true
    end

    # WebAuthn signature counter (0 for most synced/platform passkeys).
    attribute :sign_count, :integer do
      allow_nil? false
      default 0
      public? false
    end

    attribute :last_used_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    # A credential id belongs to exactly one account (WebAuthn requirement).
    identity :unique_credential, [:credential_id]
  end
end
