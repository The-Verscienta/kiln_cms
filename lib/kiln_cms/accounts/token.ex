defmodule KilnCMS.Accounts.Token do
  @moduledoc """
  Stores AshAuthentication tokens (sign-in/confirmation/reset JWTs) so they
  can be verified and revoked. Managed entirely by AshAuthentication.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.TokenResource, AshOban]

  postgres do
    table "tokens"
    repo KilnCMS.Repo
  end

  # Privacy retention (#224): expired auth tokens (sign-in/reset/magic/confirm
  # JWTs) carry a subject + jti and otherwise accumulate forever. A nightly
  # AshOban trigger runs `:expunge_expired`, so an expired token is purged within
  # ~24h of expiry. See docs/data-flows.md and config `:token_retention`.
  oban do
    triggers do
      trigger :expunge_expired do
        action :expunge_expired
        read_action :expired
        worker_read_action :expired
        queue :default
        scheduler_cron "0 4 * * *"
        where expr(expires_at < now())

        worker_module_name KilnCMS.Accounts.Token.AshOban.Worker.ExpungeExpired
        scheduler_module_name KilnCMS.Accounts.Token.AshOban.Scheduler.ExpungeExpired
      end
    end
  end

  actions do
    defaults [:read]

    read :expired do
      description "Look up all expired tokens."
      # Keyset pagination is required for the AshOban `:expunge_expired` trigger;
      # `required?: false` keeps any direct callers returning a plain list.
      pagination keyset?: true, required?: false
      filter expr(expires_at < now())
    end

    read :get_token do
      description "Look up a token by JTI or token, and an optional purpose."
      get? true
      argument :token, :string, sensitive?: true
      argument :jti, :string, sensitive?: true
      argument :purpose, :string, sensitive?: false

      prepare AshAuthentication.TokenResource.GetTokenPreparation
    end

    action :revoked?, :boolean do
      description "Returns true if a revocation token is found for the provided token"
      argument :token, :string, sensitive?: true
      argument :jti, :string, sensitive?: true

      run AshAuthentication.TokenResource.IsRevoked
    end

    create :revoke_token do
      description "Revoke a token. Creates a revocation token corresponding to the provided token."
      accept [:extra_data]
      argument :token, :string, allow_nil?: false, sensitive?: true

      change AshAuthentication.TokenResource.RevokeTokenChange
    end

    create :revoke_jti do
      description "Revoke a token by JTI. Creates a revocation token corresponding to the provided jti."
      accept [:extra_data]
      argument :subject, :string, allow_nil?: false, sensitive?: true
      argument :jti, :string, allow_nil?: false, sensitive?: true

      change AshAuthentication.TokenResource.RevokeJtiChange
    end

    create :store_token do
      description "Stores a token used for the provided purpose."
      accept [:extra_data, :purpose]
      argument :token, :string, allow_nil?: false, sensitive?: true
      change AshAuthentication.TokenResource.StoreTokenChange
    end

    destroy :expunge_expired do
      description "Deletes expired tokens."
      change filter(expr(expires_at < now()))
    end

    update :revoke_all_stored_for_subject do
      description "Revokes all stored tokens for a specific subject."
      accept [:extra_data]
      argument :subject, :string, allow_nil?: false, sensitive?: true
      change AshAuthentication.TokenResource.RevokeAllStoredForSubjectChange
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      description "AshAuthentication can interact with the token resource"
      authorize_if always()
    end

    # The nightly `:expunge_expired` trigger reads + destroys as a trusted system
    # job (no actor); let AshOban's scheduler/worker through.
    bypass AshOban.Checks.AshObanInteraction do
      description "AshOban can run the expired-token expunge trigger"
      authorize_if always()
    end
  end

  attributes do
    attribute :jti, :string do
      primary_key? true
      public? true
      allow_nil? false
      sensitive? true
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :purpose, :string do
      allow_nil? false
      public? true
    end

    attribute :extra_data, :map do
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
