defmodule KilnCMS.Federation.SiteFederation do
  @moduledoc """
  Whether this site is a fediverse actor, and the identity it federates under
  (#491).

  Off by default, and the row exists so that saying "on" is a deliberate,
  attributable act — the same posture `KilnCMS.CMS.SiteLinkCheck` takes, for a
  stronger version of the same reason. Turning link checking on makes the server
  fetch URLs the site's own editors chose. Turning federation on makes it sign
  and POST to servers chosen by **strangers**, indefinitely, with no one
  watching.

  ## The origin is pinned, not derived

  `origin` is captured when federation is first enabled and never recomputed.
  An actor's `id` is its permanent name in the fediverse: remote servers store
  it, deduplicate on it, and address deliveries to it. `KilnCMSWeb.Tenant.base_url/1`
  is *not* stable enough to be that name — it changes the day an operator adds
  a `custom_domain`, and every follower on every remote instance would be left
  holding an id that 404s, with no mechanism to learn the new one.

  So the pin is the identity, and moving a federating site to a new domain is a
  migration with a redirect story, not a settings edit. `origin` is absent from
  `default_accept` for that reason: it is set once by `:enable`, and a form that
  could edit it would be a form that could silently orphan every follower.

  ## The keypair

  RSA-2048, generated on `:enable` (`KilnCMS.Keys.generate_rsa_pem/0`). The
  private half is encrypted at rest with `KilnCMS.Keys.Vault`; the public half
  is stored in cleartext because it is published verbatim in the actor
  document — the same split `KilnCMS.Mail.Settings` makes for DKIM.

  Rotation is deliberately **not** modelled the way `KilnCMS.Provenance.KeyRegistry`
  models it. Provenance can retire a key and still verify old signatures because
  it controls both sides. Here the other side is thousands of remote servers
  that cached `publicKeyPem` from the actor document at follow time, on their own
  schedule; there is no retired-key set that helps. Rotating means re-signing
  under a new key and letting peers re-fetch, which is a phase-2 concern.
  """
  use Ash.Resource,
    domain: KilnCMS.Federation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "site_federation"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # `origin`, `username` and the keypair are all absent: identity is minted
    # once by `:enable` and is not a thing a settings form edits.
    default_accept [:enabled, :display_name, :summary]

    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org
      upsert_fields [:enabled, :display_name, :summary]
    end

    # Turn federation on, minting this site's permanent identity. Idempotent by
    # upsert on the org, but the identity fields are only written when absent —
    # re-enabling a site that was switched off keeps the actor its followers
    # already know.
    create :enable do
      description "Enable federation, minting the site's permanent actor identity."

      upsert? true
      upsert_identity :one_per_org
      # **Only** `enabled`. The identity fields are deliberately absent, which
      # is what makes re-enabling keep the actor its followers already cached:
      # on an insert they are written, on a conflict Postgres leaves the stored
      # ones alone. Doing this in a change instead would not work — an upsert
      # create's changeset data is a fresh struct, not the existing row, so
      # there is nothing to compare against.
      upsert_fields [:enabled]

      argument :origin, :string, allow_nil?: false
      argument :username, :string, allow_nil?: false

      change set_attribute(:enabled, true)
      change KilnCMS.Federation.Changes.MintIdentity
    end

    update :disable do
      require_atomic? false
      accept []
      change set_attribute(:enabled, false)
    end

    # Written by the delivery worker, system-side. Its own action so no settings
    # form can backdate the "last federated" line.
    update :record_delivery do
      require_atomic? false
      accept []
      change set_attribute(:last_delivered_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # Editors read it: the federation panel shows whether the site is
    # followable, and an editor looking at an empty follower list deserves to
    # know it is empty because federation is off.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Deciding this deployment federates is an admin act.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :enabled, :boolean do
      default false
      allow_nil? false
      public? true
    end

    # The scheme+host this site's actor is permanently named under. See the
    # moduledoc: this is identity, not configuration.
    attribute :origin, :string do
      constraints max_length: KilnCMS.Limits.url()
      writable? false
      public? true
    end

    # The `preferredUsername` half of `@user@host`. Written once with `origin`.
    attribute :username, :string do
      constraints max_length: KilnCMS.Limits.identifier()
      writable? false
      public? true
    end

    attribute :display_name, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :summary, :string, public?: true, constraints: [max_length: KilnCMS.Limits.line()]

    # Published verbatim in the actor document, so cleartext by design.
    attribute :public_key_pem, :string do
      writable? false
      public? true
    end

    # AES-256-GCM via `KilnCMS.Keys.Vault`. Never public: it signs every
    # outbound delivery, and anyone holding it can speak as this site.
    attribute :private_key_encrypted, :binary do
      writable? false
      public? false
      sensitive? true
    end

    attribute :last_delivered_at, :utc_datetime_usec do
      writable? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :one_per_org, [:org_id]
  end

  @doc """
  The decrypted RSA private key PEM for a settings row, or `nil`.

  `nil` rather than an error when the vault cannot open it: `secret_key_base`
  rotation orphans database-stored keys (see `KilnCMS.Keys.Vault`), and the
  honest response to "this site can no longer sign" is that it stops
  delivering, not that every caller crashes.
  """
  @spec private_key_pem(t()) :: String.t() | nil
  def private_key_pem(%{private_key_encrypted: nil}), do: nil

  def private_key_pem(%{private_key_encrypted: encrypted}) do
    case KilnCMS.Keys.Vault.decrypt(encrypted) do
      {:ok, pem} -> pem
      {:error, _reason} -> nil
    end
  end
end
