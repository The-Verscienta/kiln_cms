defmodule KilnCMS.Accounts.ApiKey do
  @moduledoc """
  A hashed, revocable API key bound to a `User`, for third-party / headless
  **read** access to the delivery API.

  A key authenticates as its owning user, so it inherits that user's read scope
  (role + audiences). The headless HTTP surface exposes only reads (JSON:API and
  GraphQL are read-only — decision D7), and the content policy additionally
  forbids any mutation performed with an API key, so a leaked key can never write
  regardless of the owner's role. For a pure public-content integrator, mint a
  key on a dedicated `:viewer` account.

  Only the SHA-256 hash of the key is stored; the plaintext is returned **once**
  at creation, in `key.__metadata__.plaintext_api_key`. Keys look like
  `kiln_<base62>_<crc>` — the `kiln_` prefix lets the auth plug tell them apart
  from JWT bearer tokens (and enables GitHub-style secret-scanning revocation).
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Secret-scanning-friendly prefix baked into every generated key. Kept in sync
  # with the auth plug (KilnCMSWeb.Plugs.ApiKeyAuth) that routes on it.
  @prefix "kiln"
  def prefix, do: @prefix

  postgres do
    table "api_keys"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :for_user do
      description "All keys minted for a user, newest first (admin key management)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [created_at: :desc])
    end

    create :create do
      primary? true
      description "Mint an API key. The plaintext is returned once in metadata."
      accept [:user_id, :name, :expires_at]

      change {AshAuthentication.Strategy.ApiKey.GenerateApiKey,
              prefix: @prefix, hash: :api_key_hash}
    end

    update :revoke do
      description "Revoke a key immediately (idempotent). Sets `revoked_at`."
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # The API-key sign-in flow looks up the key through the user's
    # `valid_api_keys` relationship as a trusted auth interaction.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Minting, listing and revoking keys is an operator task — admins only.
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    # Human-facing label so an admin can tell keys apart in the UI.
    attribute :name, :string, allow_nil?: false, public?: true

    # SHA-256 of the plaintext key. Never returned by reads.
    attribute :api_key_hash, :binary do
      allow_nil? false
      sensitive? true
    end

    # Keys are always expiring — no immortal credentials.
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # Non-nil once revoked; excluded from `valid` and from auth lookups.
    attribute :revoked_at, :utc_datetime_usec, public?: true

    create_timestamp :created_at
  end

  relationships do
    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
    end
  end

  calculations do
    calculate :valid, :boolean, expr(is_nil(revoked_at) and expires_at > now())
  end

  identities do
    identity :unique_api_key_hash, [:api_key_hash]
  end
end
