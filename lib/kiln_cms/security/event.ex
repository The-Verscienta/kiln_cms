defmodule KilnCMS.Security.Event do
  @moduledoc """
  One entry of an org's security audit log (#2241).

  Append-only: there is a `record` create and reads, plus two system-actor
  maintenance actions (`anonymize_actor`, `prune`). No person, admin included,
  can create, update or destroy an event. Reading is org-admin only; editors,
  viewers and anonymous callers are refused, and another org's admin sees
  nothing (tenant-scoped).

  ## Shape

    * `type` - one of `types/0`, or a `KilnCMS.Types.UnknownAtom` for a type
      a newer release recorded (#2509).
    * `actor_id` / `actor_label` - who did it. `actor_id` is a plain uuid (no
      foreign key: erasure nils it, and a deleted account must not cascade into
      the log). `actor_label` is an email snapshot, recorded only for known
      users; an unknown-account sign-in failure stores none, so the log is not
      an account-enumeration oracle.
    * `target_type` / `target_id` - what was acted on (a user, an API key...).
    * `ip`, `user_agent` - raw, kept until retention or erasure removes them.
    * `metadata` - a typed allowlist per event type (`metadata_keys/1`), scalar
      values, length-capped, applied by `Changes.SanitizeMetadata`.

  Not an API surface: absent from JSON:API, GraphQL and MCP.
  """
  use Ash.Resource,
    domain: KilnCMS.Security,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @types [
    :sign_in,
    :sign_in_failed,
    :sign_in_locked,
    :second_factor_enrolled,
    :second_factor_removed,
    :recovery_code_used,
    :passkey_added,
    :passkey_removed,
    :role_granted,
    :role_revoked,
    :member_invited,
    :invitation_revoked,
    :elevation_granted,
    :api_key_created,
    :api_key_revoked,
    :sso_config_changed,
    :org_setting_changed,
    :ip_auto_blocked,
    :session_idle_expired,
    :all_sessions_revoked,
    :admin_access_refused,
    :admin_allowlist_changed,
    :admin_allowlist_overridden,
    :sign_in_unlock_requested,
    :sign_in_unlocked,
    :sign_in_unlock_refused,
    :registration_queued,
    :registration_approved,
    :registration_rejected,
    :backup_canceled
  ]

  # The only metadata keys each type may carry. None names a person: who is in
  # `actor_*` / `target_*`, which erasure knows how to scrub.
  @metadata_keys %{
    sign_in: ~w(method),
    sign_in_failed: ~w(method reason),
    sign_in_locked: ~w(method scope),
    second_factor_enrolled: ~w(kind),
    second_factor_removed: ~w(kind via),
    recovery_code_used: ~w(remaining),
    passkey_added: ~w(name),
    passkey_removed: ~w(name via),
    role_granted: ~w(role previous_role),
    role_revoked: ~w(role),
    member_invited: ~w(role resent),
    invitation_revoked: ~w(role),
    elevation_granted: ~w(role minutes),
    api_key_created: ~w(name scope),
    api_key_revoked: ~w(name),
    sso_config_changed: ~w(provider change),
    org_setting_changed: ~w(setting),
    ip_auto_blocked: ~w(reason count window_minutes block_minutes),
    session_idle_expired: ~w(timeout_minutes tier surface),
    all_sessions_revoked: ~w(count except_self),
    admin_access_refused: ~w(surface),
    admin_allowlist_changed: ~w(state count added removed),
    admin_allowlist_overridden: ~w(change count),
    sign_in_unlock_requested: ~w(surface),
    sign_in_unlocked: ~w(was_locked),
    sign_in_unlock_refused: ~w(reason),
    registration_queued: ~w(method),
    registration_approved: ~w(role via),
    registration_rejected: ~w(outcome),
    backup_canceled: ~w(stamp step)
  }

  @max_metadata_keys 8
  @max_metadata_value 200

  @doc "Every event type."
  @spec types() :: [atom()]
  def types, do: @types

  @doc "The metadata keys `type` may carry (strings). None for an unknown type."
  @spec metadata_keys(atom() | KilnCMS.Types.UnknownAtom.t() | nil) :: [String.t()]
  def metadata_keys(type), do: Map.get(@metadata_keys, type, [])

  @doc false
  def max_metadata_keys, do: @max_metadata_keys
  @doc false
  def max_metadata_value, do: @max_metadata_value

  postgres do
    table "security_events"
    repo KilnCMS.Repo

    custom_indexes do
      index [:org_id, :inserted_at]
      index [:org_id, :type, :inserted_at]
      index [:org_id, :actor_id]
      index [:org_id, :target_id]
    end
  end

  actions do
    defaults [:read]

    # The admin console's list: filterable, newest first, keyset-paged.
    read :list do
      argument :type, :atom, constraints: [one_of: @types]
      argument :actor_id, :uuid
      argument :since, :utc_datetime_usec
      argument :until, :utc_datetime_usec

      filter expr(is_nil(^arg(:type)) or type == ^arg(:type))
      filter expr(is_nil(^arg(:actor_id)) or actor_id == ^arg(:actor_id))
      filter expr(is_nil(^arg(:since)) or inserted_at >= ^arg(:since))
      filter expr(is_nil(^arg(:until)) or inserted_at <= ^arg(:until))

      prepare build(sort: [inserted_at: :desc, id: :desc])
      pagination keyset?: true, offset?: false, required?: false, default_limit: 50
    end

    # Every event one user acted in or is the target of: the rows the erasure
    # sweep (`KilnCMS.Security.anonymize_actor/1`) scrubs. A bulk update
    # authorizes its query as a read, so the sweep needs a read of its own for
    # the system actor to be admitted to.
    read :by_actor do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(actor_id == ^arg(:user_id) or target_id == ^arg(:user_id))
      # Lets the bulk update stream the matches in keyset chunks.
      pagination keyset?: true, required?: false
    end

    # Has this address signed in on this site since `since`? The scanner guard's
    # one read (#2253), so it never blocks an address a person signed in from.
    read :sign_in_from_ip do
      argument :ip, :string, allow_nil?: false
      argument :since, :utc_datetime_usec, allow_nil?: false
      filter expr(type == :sign_in and ip == ^arg(:ip) and inserted_at >= ^arg(:since))
    end

    # The retention prune's read: events strictly older than the cutoff.
    read :older_than do
      argument :cutoff, :utc_datetime_usec, allow_nil?: false
      filter expr(inserted_at < ^arg(:cutoff))
    end

    create :record do
      primary? true

      accept [
        :type,
        :actor_id,
        :actor_label,
        :target_type,
        :target_id,
        :ip,
        :user_agent,
        :metadata
      ]

      change KilnCMS.Security.Changes.SanitizeMetadata
    end

    update :anonymize_actor do
      description "Scrub a user's identity from an event (erasure), keeping the event."
      accept []
      require_atomic? false
      argument :user_id, :uuid, allow_nil?: false
      change KilnCMS.Security.Changes.ScrubUser
    end

    destroy :prune do
      description "Retention: delete an event past its window."
      require_atomic? false
    end
  end

  policies do
    # Reading is an org-admin act (a platform admin is admin on every org via
    # `Scoping.effective_tier/2`). The system actor is admitted to the two
    # reads the maintenance sweeps need, never to the plain `read` / `list`.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
      forbid_unless action([:by_actor, :older_than, :sign_in_from_ip])

      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :security, action: [:by_actor, :older_than]}

      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :scanner_guard, action: :sign_in_from_ip}
    end

    # Writes are the `:security` system actor's, by action name. No person,
    # admin included, records, rewrites or deletes an event.
    policy action_type(:create) do
      forbid_unless action(:record)
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :security}
    end

    policy action_type(:update) do
      forbid_unless action(:anonymize_actor)
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :security}
    end

    policy action_type(:destroy) do
      forbid_unless action(:prune)
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :security}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # Set from the tenant, never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # `KnownAtom`, not `:atom`: a type a newer release added loads as
    # `KilnCMS.Types.UnknownAtom` instead of failing every read of the log
    # (#2509). Writes stay limited to `@types`.
    attribute :type, KilnCMS.Types.KnownAtom do
      allow_nil? false
      constraints one_of: @types
      public? true
    end

    # No foreign key: erasure nils it and an account's removal must not touch
    # the log.
    attribute :actor_id, :uuid, public?: true

    attribute :actor_label, :string,
      public?: true,
      constraints: [max_length: 254, trim?: true, allow_empty?: false]

    attribute :target_type, :string,
      public?: true,
      constraints: [max_length: 64, trim?: true, allow_empty?: false]

    attribute :target_id, :uuid, public?: true

    attribute :ip, :string,
      public?: true,
      constraints: [max_length: 45, trim?: true, allow_empty?: false]

    attribute :user_agent, :string,
      public?: true,
      constraints: [max_length: 512, trim?: true, allow_empty?: false]

    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    create_timestamp :inserted_at, public?: true, type: :utc_datetime_usec
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
