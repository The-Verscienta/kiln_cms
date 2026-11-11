defmodule KilnCMS.Security.InstanceEvent do
  @moduledoc """
  One entry of the **instance** security log (#2541): an event about the
  installation as a whole rather than one site, such as a platform admin
  canceling a backup.

  The per-site log (`KilnCMS.Security.Event`) is readable by each site's
  admins. An instance-wide event written there would have to pick a site (it
  used to be the default one), whose admins, who need not be platform admins,
  would then see a platform admin's email address and the instance's backup
  stamps. This log is readable by **platform admins only**.

  ## A table of its own, with no tenant

  Like `KilnCMS.Backups.Run`, there is no `multitenancy` block and the read
  gate is `KilnCMS.Accounts.Checks.PlatformAdmin`, never `OrgAdmin` (which
  resolves a tenant-less subject to the default org). A nullable `org_id` on
  `security_events` was rejected: Ash's attribute multitenancy cannot express
  "no tenant", so every site read would have to be audited never to reach those
  rows, and the site log's foreign key rules out a sentinel org. Here no site
  read can reach an instance row: they are different tables.

  ## Shape

  The site log's columns without `org_id`: `type` (one of `types/0`, or a
  `KilnCMS.Types.UnknownAtom` for a type a newer release recorded),
  `actor_id` / `actor_label`, `target_type` / `target_id`, `ip`,
  `user_agent`, and a typed `metadata` allowlist per type
  (`metadata_keys/1`), applied by `KilnCMS.Security.Changes.SanitizeMetadata`.

  Append-only: a `record` create and reads, plus the `:security` system actor's
  `anonymize_actor` (erasure) and `prune` (retention,
  `KilnCMS.Security.instance_retention_days/0`). No person, a platform admin
  included, can create, update or destroy an event. No instance event raises a
  security alert.

  Not an API surface: absent from JSON:API, GraphQL and MCP.
  """
  use Ash.Resource,
    domain: KilnCMS.Security,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @types [
    # A platform admin stopped a running in-app backup (#2218).
    :backup_canceled
  ]

  @metadata_keys %{
    backup_canceled: ~w(stamp step)
  }

  # Alerts: none of these types raises one today. Instance events could carry
  # alerts later (`AlertDispatch.first_event_id` has no foreign key).

  @doc "Every instance event type."
  @spec types() :: [atom()]
  def types, do: @types

  @doc "The metadata keys `type` may carry (strings). None for an unknown type."
  @spec metadata_keys(atom() | KilnCMS.Types.UnknownAtom.t() | nil) :: [String.t()]
  def metadata_keys(type), do: Map.get(@metadata_keys, type, [])

  @doc false
  def max_metadata_keys, do: KilnCMS.Security.Event.max_metadata_keys()
  @doc false
  def max_metadata_value, do: KilnCMS.Security.Event.max_metadata_value()

  @default_org KilnCMS.Accounts.Organization.default_id()
  @columns "id, type, actor_id, actor_label, target_type, target_id, ip, user_agent, metadata, inserted_at"

  postgres do
    table "instance_security_events"
    repo KilnCMS.Repo

    # The `backup_canceled` events recorded before this log existed sat in the
    # default site's log, where that site's admins could read them (#2541).
    # Moved, not copied or deleted: the audit trail survives, and only platform
    # admins can read it. The down migration moves them back (the default org
    # has a fixed id) before the table is dropped; with no default org the
    # foreign key fails the rollback rather than dropping the rows.
    custom_statements do
      statement :move_backup_canceled do
        up "WITH moved AS (DELETE FROM security_events WHERE type = 'backup_canceled' " <>
             "RETURNING #{@columns}) " <>
             "INSERT INTO instance_security_events (#{@columns}) SELECT #{@columns} FROM moved"

        down "WITH moved AS (DELETE FROM instance_security_events WHERE type = 'backup_canceled' " <>
               "RETURNING #{@columns}) " <>
               "INSERT INTO security_events (org_id, #{@columns}) " <>
               "SELECT '#{@default_org}', #{@columns} FROM moved"

        after_tables ["security_events"]
      end
    end

    custom_indexes do
      index [:inserted_at]
      index [:type, :inserted_at]
      index [:actor_id]
      index [:target_id]
    end
  end

  actions do
    defaults [:read]

    # The instance log page's list: filterable, newest first, keyset-paged.
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

    # The erasure sweep's read (`KilnCMS.Security.anonymize_actor/1`).
    read :by_actor do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(actor_id == ^arg(:user_id) or target_id == ^arg(:user_id))
      pagination keyset?: true, required?: false
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
    # Reading is a platform admin's act (the effective role, so a temporary
    # platform grant reads until it expires). A site admin, the default site's
    # included, is refused. The `:security` system actor is admitted to the
    # two reads erasure and retention make, never to `read` / `list`.
    policy action_type(:read) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
      forbid_unless action([:by_actor, :older_than])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :security}
    end

    # Writes are the `:security` system actor's, by action name. No person,
    # platform admin included, records, rewrites or deletes an event.
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

  attributes do
    uuid_primary_key :id

    # `KnownAtom`, as on the site log (#2509): a type a newer release added
    # loads as `KilnCMS.Types.UnknownAtom` instead of failing every read.
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
end
