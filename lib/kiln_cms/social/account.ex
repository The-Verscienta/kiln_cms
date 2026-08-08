defmodule KilnCMS.Social.Account do
  @moduledoc """
  A social account Kiln may announce to (#497) — one per provider per site.

  Holds the operator's own credential for an existing account on an existing
  network. This is not a fediverse identity: that is `KilnCMS.Federation`, which
  makes Kiln itself an actor. Here Kiln is a client posting to someone's
  account, which is why the credential is a secret and not a keypair.

  ## Credentials

  Whatever the provider needs, encrypted at rest with `KilnCMS.Keys.Vault`
  (AES-256-GCM), the same treatment the DKIM private key and the federation
  signing key get:

    * Bluesky — an **app password** (Settings → App Passwords), never the
      account password. `handle` identifies the account.
    * Mastodon — an access token with `write:statuses`, plus the `instance_url`
      it belongs to.

  The credential is `sensitive?` and never public on any API. It is not in
  `default_accept` either: it arrives through the `:set_credential` argument so
  a blank submission from the settings form means *unchanged* rather than
  *erase*, the same distinction `KilnCMS.CMS.Changes.ApplyAccessPassword` draws
  and for the same reason — a form that re-submits every field would otherwise
  silently unconfigure a working account.
  """
  use Ash.Resource,
    domain: KilnCMS.Social,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  @providers [:bluesky, :mastodon]

  @doc "Providers with a core implementation."
  def providers, do: @providers

  admin do
    resource_group :system
    table_columns [:provider, :handle, :enabled, :last_posted_at]
  end

  postgres do
    table "social_accounts"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
      require_atomic? false
      change KilnCMS.Social.Changes.BustAccounts
    end

    default_accept [:provider, :handle, :instance_url, :enabled]

    create :create do
      primary? true
      argument :credential, :string, sensitive?: true, allow_nil?: false
      change KilnCMS.Social.Changes.SetCredential
      change KilnCMS.Social.Changes.BustAccounts
      validate KilnCMS.Social.Validations.ProviderFields
    end

    update :update do
      primary? true
      require_atomic? false
      # Blank means unchanged — see the moduledoc.
      argument :credential, :string, sensitive?: true
      change KilnCMS.Social.Changes.SetCredential
      change KilnCMS.Social.Changes.BustAccounts
      validate KilnCMS.Social.Validations.ProviderFields
    end

    # Stamped after a successful post, so the settings page can show an account
    # that has actually worked recently rather than one that merely exists.
    update :record_post do
      accept []
      require_atomic? false
      change set_attribute(:last_posted_at, &DateTime.utc_now/0)
    end

    read :enabled_for_provider do
      argument :provider, :atom, allow_nil?: false
      filter expr(enabled == true and provider == ^arg(:provider))
    end
  end

  policies do
    # Credentials for the site's public voice — admin-only. The announcer reads
    # with `authorize?: false` as a system job.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): an account belongs to one site, so one org's
  # publish can never post to another org's timeline.
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

    attribute :provider, :atom do
      allow_nil? false
      constraints one_of: @providers
      public? true
    end

    # Bluesky: the account handle (`example.bsky.social`). Mastodon: display
    # only — the token identifies the account there.
    attribute :handle, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    # Mastodon only: the instance origin. Operator-supplied, so every request
    # to it goes through `KilnCMS.SafeFetch` rather than a bare HTTP client —
    # otherwise this column is a server-side request forgery primitive with an
    # admin-facing form attached to it.
    attribute :instance_url, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    attribute :credential_encrypted, :binary do
      writable? false
      public? false
      sensitive? true
    end

    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true

    attribute :last_posted_at, :utc_datetime_usec do
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
    # One account per provider per site in v1. Multiple accounts on the same
    # network is a real want (a brand and a personal handle), but it turns the
    # automation rule's `provider` config into a picker and the ledger's dedupe
    # key into a triple — deferred rather than half-built.
    identity :one_per_provider, [:provider]
  end

  @doc """
  The decrypted credential, or `nil` when it cannot be read.

  `nil` rather than raising: `secret_key_base` rotating (or a restored backup
  from another deployment) must stop this account posting, not crash every
  publish that happens to match a rule.
  """
  @spec credential(t()) :: String.t() | nil
  def credential(%{credential_encrypted: nil}), do: nil

  def credential(%{credential_encrypted: encrypted}) do
    case KilnCMS.Keys.Vault.decrypt(encrypted) do
      {:ok, secret} -> secret
      {:error, _reason} -> nil
    end
  end

  @type t :: %__MODULE__{}
end
