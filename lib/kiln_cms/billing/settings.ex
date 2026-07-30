defmodule KilnCMS.Billing.Settings do
  @moduledoc """
  Singleton instance-wide payment-provider credentials (#337 Phase 2).

  Key material follows the provider model (`KilnCMS.Keys`), exactly as
  `KilnCMS.Mail.Settings` does for the DKIM key: this row stores *which*
  provider holds each secret and its pointer config, and only the `:database`
  provider persists the secret here, encrypted (`KilnCMS.Keys.Vault`).

  Two secrets, configured independently, because they rotate on different
  cadences — the API key is an account-wide bearer credential, the webhook
  signing secret is per-endpoint and rotates whenever an operator re-creates the
  endpoint in the provider's dashboard. An operator may well hold the API key in
  a Vault-mounted file while pasting the `whsec_…` into the console.

  There is deliberately **no publishable-key field**: hosted checkout means we
  redirect to a provider-hosted URL and never mount their JS, so the
  publishable key has no use here. Add one only if an embedded flow ever lands.

  ## Instance-wide, unlike tiers

  This row is **instance-wide** (one provider account per instance — #337 open
  question 1) and therefore has no `multitenancy` block, so its policy gates on
  the global `User.role`. `KilnCMS.Billing.MembershipTier` is the opposite: it is
  per-site and gates on `KilnCMS.CMS.Checks.OrgAdmin`. That asymmetry is
  load-bearing — see the hazard documented on `KilnCMS.CMS.SiteBranding`.

  The row is created lazily (`KilnCMS.Billing.ensure_settings!/0`) and unique by
  the constant `singleton` column.
  """
  use Ash.Resource,
    domain: KilnCMS.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @providers ["database", "env", "file"]
  @secrets [:secret_key, :webhook_secret]

  postgres do
    table "billing_settings"
    repo KilnCMS.Repo

    # The provider sets are enforced in the Ash layer (`one_of` below), but Ash
    # casts these columns to atoms on *read*, so an out-of-band write of any
    # other string would crash every read of the singleton — taking down
    # checkout and the webhook receiver together. DB-level CHECKs make the bad
    # write impossible in the first place.
    check_constraints do
      check_constraint :secret_key_provider, "billing_secret_key_provider_must_be_known",
        check: "secret_key_provider IN ('database', 'env', 'file')"

      check_constraint :webhook_secret_provider, "billing_webhook_secret_provider_must_be_known",
        check: "webhook_secret_provider IN ('database', 'env', 'file')"

      check_constraint :provider, "billing_provider_must_be_known",
        check: "provider IN ('stripe')"
    end
  end

  actions do
    defaults [:read]

    # Lazy get-or-create; all real state arrives via the update actions.
    create :init do
      accept []
    end

    # Store a pasted secret in the encrypted database column. `Mail.Settings`
    # never needed this shape because DKIM keys are *generated*; a provider API
    # key is pasted, so this is the one action with no exact precedent.
    update :store_secret do
      accept []
      require_atomic? false

      argument :key, :atom do
        allow_nil? false
        constraints one_of: @secrets
      end

      argument :value, :string do
        allow_nil? false
        sensitive? true
      end

      change KilnCMS.Billing.Settings.Changes.StoreSecret
    end

    # Point a secret at an env var or file. Checks the source is readable and
    # non-empty before switching, so a typo can't silently disable billing.
    update :configure_key_source do
      accept []
      require_atomic? false

      argument :key, :atom do
        allow_nil? false
        constraints one_of: @secrets
      end

      argument :provider, :atom do
        allow_nil? false
        constraints one_of: [:env, :file]
      end

      argument :config, :map, default: %{}

      change KilnCMS.Billing.Settings.Changes.ConfigureKeySource
    end

    # Stamped after a successful credential probe, so the console can show
    # which account is wired up and whether it is live or test mode.
    update :record_verification do
      accept [:provider_account_id, :livemode, :verification_error]
      require_atomic? false
      change set_attribute(:last_verified_at, &DateTime.utc_now/0)
    end

    # The operator's "disconnect": nulls both secrets and resets the providers.
    # With no credentials `KilnCMS.Billing.configured?/0` is false, so no tier is
    # offered and no outbound call is made.
    update :clear_credentials do
      accept []
      require_atomic? false
      change KilnCMS.Billing.Settings.Changes.ClearCredentials
    end
  end

  policies do
    # PLATFORM-admin only, NOT a per-org tier (#419) — mirroring
    # `KilnCMS.Mail.Settings`: this is an instance-wide singleton with no
    # `multitenancy` block, so an `OrgAdmin` check would resolve a tenant-less
    # subject to the DEFAULT org and let a default-org membership admin rewrite
    # payment credentials for every site. The checkout path and webhook receiver
    # read with `authorize?: false` as system callers
    # (`KilnCMS.Billing.credentials/0`).
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
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

    attribute :provider, :atom do
      allow_nil? false
      default :stripe
      constraints one_of: [:stripe]
      public? true
    end

    attribute :secret_key_provider, :atom do
      allow_nil? false
      default :database
      constraints one_of: [:database, :env, :file]
      public? true
    end

    # Provider-specific pointer (%{"var" => ...} / %{"path" => ...}); never key
    # material. Empty for the database provider.
    attribute :secret_key_provider_config, :map, allow_nil?: false, default: %{}, public?: true

    attribute :secret_key_encrypted, :binary do
      sensitive? true
      writable? false
    end

    attribute :webhook_secret_provider, :atom do
      allow_nil? false
      default :database
      constraints one_of: [:database, :env, :file]
      public? true
    end

    attribute :webhook_secret_provider_config, :map,
      allow_nil?: false,
      default: %{},
      public?: true

    attribute :webhook_secret_encrypted, :binary do
      sensitive? true
      writable? false
    end

    # Non-secret confirmations for the console — which account, and whether the
    # keys are live or test.
    attribute :provider_account_id, :string, public?: true
    attribute :livemode, :boolean, public?: true
    attribute :last_verified_at, :utc_datetime_usec, public?: true
    attribute :verification_error, :string, public?: true

    timestamps()
  end

  identities do
    identity :singleton_row, [:singleton]
  end

  @doc "The secrets this resource holds, in console display order."
  def secrets, do: @secrets

  @doc "Valid provider names, as the DB CHECK spells them."
  def provider_names, do: @providers

  @doc "The attribute names backing `key` — `{provider, config, encrypted}`."
  @spec fields(:secret_key | :webhook_secret) :: {atom(), atom(), atom()}
  def fields(:secret_key),
    do: {:secret_key_provider, :secret_key_provider_config, :secret_key_encrypted}

  def fields(:webhook_secret),
    do: {:webhook_secret_provider, :webhook_secret_provider_config, :webhook_secret_encrypted}
end
