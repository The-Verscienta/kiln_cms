defmodule KilnCMS.Backups.DestinationConfig do
  @moduledoc """
  A backup destination a platform admin added (#2220): somewhere in-app
  backups copy their finished files, beside `BACKUP_DIR` and the env
  destination (`BACKUP_RCLONE_REMOTE`), which is not stored and never one of
  these rows (`KilnCMS.Backups.Destination`, decision E2).

  A row names an adapter by its `kind` (`c:Kiln.BackupDestination.kind/0`),
  and carries that adapter's fields (`fields/0`): the non-secret ones in
  `settings`, the `:secret` ones encrypted together in `secrets_encrypted`.
  A row whose adapter is no longer installed (its plugin removed) still
  reads, and can still be disabled, renamed or deleted; a backup records it
  as failed until it is.

  ## Secrets

  `secrets_encrypted` is a JSON object of the secret fields, encrypted with
  `KilnCMS.Keys.Vault` (`Changes.StoreSecrets`). It is `sensitive?`, not
  writable, not public, never read back into a form, and decrypted only by
  `to_config/1`, just before an adapter is called. A blank secret on update
  keeps the stored one. Its type is `KilnCMS.Keys.Vault.Ciphertext`, so
  `mix kiln.vault.reencrypt` walks it across a `SECRET_KEY_BASE` rotation; a
  ciphertext no key opens is `{:error, :undecryptable}`, and the admin
  enters the secrets again.

  ## Where it writes never changes

  The location settings (Local `path`; Rclone `remote_name` and `path`) are
  fixed at create (critic change 2): retention on a destination deletes only
  what this installation recorded sending to that destination's key, so
  moving the key to another place would let it delete what it never sent
  there. Moving a destination is adding a new one. A new destination may not
  be, contain or sit inside the env remote or any other row
  (`Validations.AdapterSettings`).

  ## Instance-wide, platform admins only

  No `multitenancy` block, and people are gated on the global role
  (`KilnCMS.Accounts.Checks.PlatformAdmin`), never `OrgAdmin`. A platform
  admin reads, creates, updates and destroys destinations, each write audited
  in the instance security log. The backup pipeline reads them as the
  `:backups` system actor (`:read` and `:enabled` only) and records a Test's
  result (`:record_test_result`, the system actor's alone). Not exposed
  through JSON:API, GraphQL or MCP.

  ## At most eight enabled

  The step chain holds the cluster's backup lock through every destination,
  one after another (decision E8).
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.DestinationConfig.{Audit, Changes, Validations}
  alias KilnCMS.Keys.Vault

  @max_enabled 8

  @editable [:name, :enabled, :position, :settings, :prune]

  postgres do
    table "backup_destinations"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # What the step chain sends to, in order.
    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [position: :asc, inserted_at: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:kind | @editable]

      # The `:secret` fields, by name. Blank or missing values are none.
      argument :secrets, :map, sensitive?: true, default: %{}

      change Changes.Normalize
      change Changes.StoreSecrets
      validate Validations.AdapterSettings

      change {KilnCMS.Security.Changes.Record,
              type: :backup_destination_created,
              scope: :instance,
              mode: :in_transaction,
              target: &Audit.target/2,
              metadata: &Audit.created/2}
    end

    # `kind` is not accepted: an adapter's settings mean nothing to another.
    update :update do
      primary? true
      accept @editable
      require_atomic? false

      argument :secrets, :map, sensitive?: true, default: %{}

      change Changes.Normalize
      change Changes.StoreSecrets
      validate Validations.AdapterSettings

      change {KilnCMS.Security.Changes.Record,
              type: :backup_destination_changed,
              scope: :instance,
              mode: :in_transaction,
              target: &Audit.target/2,
              metadata: &Audit.changed/2,
              when: &Audit.changed?/2}
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {KilnCMS.Security.Changes.Record,
              type: :backup_destination_deleted,
              scope: :instance,
              mode: :in_transaction,
              target: &Audit.target/2,
              metadata: &Audit.deleted/2}
    end

    # A Test's outcome (`KilnCMS.Backups.test_destination/2`), recorded after
    # the adapter call and outside its transaction. The `:backups` system
    # actor's alone, so no person can mark a destination as tested. The
    # platform admin who pressed Test is the event's actor, passed in the
    # changeset context by `test_destination/2`.
    update :record_test_result do
      accept []
      require_atomic? false

      argument :ok, :boolean, allow_nil?: false
      argument :error, :string
      argument :node, :string

      change Changes.SetTestResult

      change {KilnCMS.Security.Changes.Record,
              type: :backup_destination_tested,
              scope: :instance,
              mode: :in_transaction,
              user: &Audit.tested_by/2,
              target: &Audit.target/2,
              metadata: &Audit.tested/2}
    end
  end

  policies do
    # Instance-wide and tenant-less: the global role, never `OrgAdmin`. The
    # backup pipeline and the form's own checks (the cap, overlap) read as the
    # `:backups` system actor, narrowed to the two reads they use.
    policy action_type(:read) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin

      forbid_unless action([:read, :enabled])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end

    # A platform admin manages destinations; the pipeline never does.
    policy action([:create, :update, :destroy]) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end

    # Only `test_destination/2` records a Test, as the system actor, after
    # reading the row as the admin who asked.
    policy action(:record_test_result) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      constraints max_length: 80
      public? true
    end

    # The adapter's `kind/0`. Kept when the adapter is uninstalled.
    attribute :kind, :string do
      allow_nil? false
      constraints max_length: 32, match: ~r/\A[a-z0-9_]{1,32}\z/
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    # Order in the step chain, ascending; ties by creation.
    attribute :position, :integer do
      allow_nil? false
      default 0
      constraints min: 0, max: 10_000
      public? true
    end

    # The adapter's non-secret fields, by name. Never a secret
    # (`Validations.AdapterSettings` refuses a `:secret` field here).
    attribute :settings, :map do
      allow_nil? false
      default %{}
      public? true
    end

    # Set only by `Changes.StoreSecrets`: the JSON object of the `:secret`
    # fields, vault-encrypted. `nil` is "no secrets".
    attribute :secrets_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      sensitive? true
      writable? false
      public? false
    end

    # Retention on this destination after each upload (decision E4).
    attribute :prune, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :last_tested_at, :utc_datetime_usec, public?: true
    attribute :last_test_ok, :boolean, public?: true

    # Redacted of the destination's secrets and cut by `Changes.SetTestResult`.
    attribute :last_test_error, :string do
      constraints max_length: KilnCMS.Limits.line()
      public? true
    end

    # The node the Test ran on: a Local destination is checked on the node
    # that runs the call, and another node may see another disk.
    attribute :last_test_node, :string do
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_name, [:name]
  end

  @doc "How many destinations may be enabled at once (decision E8)."
  @spec max_enabled() :: pos_integer()
  def max_enabled, do: @max_enabled

  @doc "The key a destination's results are recorded under: `\"dest:<id>\"`."
  @spec key(%__MODULE__{} | String.t()) :: String.t()
  def key(%__MODULE__{id: id}), do: key(id)
  def key(id) when is_binary(id), do: "dest:" <> id

  @doc """
  The `Kiln.BackupDestination.Config` an adapter is called with for
  `destination`, its secrets decrypted now. `{:error, :undecryptable}` when
  no key opens them (`SECRET_KEY_BASE` changed with no
  `PREVIOUS_SECRET_KEY_BASE`, or a database restored under another key).
  """
  @spec to_config(%__MODULE__{}) :: {:ok, Config.t()} | {:error, :undecryptable}
  def to_config(%__MODULE__{} = destination) do
    with {:ok, secrets} <- decrypt_secrets(destination.secrets_encrypted) do
      {:ok,
       %Config{
         id: destination.id,
         key: destination.id && key(destination),
         kind: destination.kind,
         settings: destination.settings || %{},
         secrets: secrets
       }}
    end
  end

  @doc """
  The secret fields `ciphertext` holds: `%{}` for none,
  `{:error, :undecryptable}` when no key opens it or it is not a JSON
  object of strings.
  """
  @spec decrypt_secrets(binary() | nil) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, :undecryptable}
  def decrypt_secrets(nil), do: {:ok, %{}}

  def decrypt_secrets(ciphertext) when is_binary(ciphertext) do
    with {:ok, json} <- Vault.decrypt(ciphertext),
         {:ok, %{} = secrets} <- Jason.decode(json),
         true <- Enum.all?(secrets, fn {_name, value} -> is_binary(value) end) do
      {:ok, secrets}
    else
      _ -> {:error, :undecryptable}
    end
  end

  @doc false
  # The one place secrets are encrypted: a JSON object of strings, or `nil`
  # for none.
  @spec encrypt_secrets(%{optional(String.t()) => String.t()}) :: binary() | nil
  def encrypt_secrets(secrets) when map_size(secrets) == 0, do: nil

  def encrypt_secrets(secrets) when is_map(secrets),
    do: secrets |> Jason.encode!() |> Vault.encrypt()
end
