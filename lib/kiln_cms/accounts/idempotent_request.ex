defmodule KilnCMS.Accounts.IdempotentRequest do
  @moduledoc """
  One `Idempotency-Key` a caller has used on the headless write surface, and
  the response it got — so a retry of the same request replays that response
  instead of creating a second document or running a second transition
  (`KilnCMSWeb.Plugs.Idempotency`, `docs/api.md#idempotent-writes`).

  A row is claimed (`:claim`, status `:in_progress`) before the request runs,
  and settled (`:complete`) with the response after. The unique identity on
  `(org_id, scope, key)` is what makes two concurrent retries safe: only one
  claim can insert, and the other is told the request is still in flight.

  `scope` is the actor the key belongs to (`"user:<id>"`), so one caller can
  never replay — or collide with — another's keys. `fingerprint` is a hash of
  the method, path, query and body: the same key sent with a different request
  is a client bug, answered with a 422 rather than with the first request's
  response.

  Rows live 24 hours (`ttl_hours/0`), then an hourly AshOban trigger prunes
  them. No actor-facing surface reads this table: the plug is the only caller,
  as a system component, and the policy forbids everything else.
  """
  use Ash.Resource,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  @ttl_hours 24

  @doc "Hours a key (and its stored response) is kept."
  @spec ttl_hours() :: pos_integer()
  def ttl_hours, do: @ttl_hours

  postgres do
    table "idempotent_requests"
    repo KilnCMS.Repo
  end

  oban do
    use_tenant_from_record? true

    triggers do
      trigger :prune do
        action :destroy
        queue :default
        scheduler_cron "17 * * * *"
        list_tenants KilnCMS.Accounts.ListOrgIds
        where expr(inserted_at <= ago(^@ttl_hours, :hour))
        worker_read_action :read
        worker_module_name KilnCMS.Accounts.IdempotentRequest.Workers.Prune
        scheduler_module_name KilnCMS.Accounts.IdempotentRequest.Schedulers.Prune
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :claim do
      accept [:scope, :key, :fingerprint]
      change set_attribute(:status, :in_progress)
    end

    read :lookup do
      get? true
      argument :scope, :string, allow_nil?: false
      argument :key, :string, allow_nil?: false
      filter expr(scope == ^arg(:scope) and key == ^arg(:key))
    end

    # A stale `:in_progress` claim (its request crashed before it could settle)
    # taken over by a retry, or an expired row reused for a fresh request.
    update :reclaim do
      accept [:fingerprint]
      change set_attribute(:status, :in_progress)
      change set_attribute(:response_status, nil)
      change set_attribute(:response_headers, %{})
      change set_attribute(:response_body, nil)
    end

    update :complete do
      accept [:response_status, :response_headers, :response_body]
      change set_attribute(:status, :completed)
    end
  end

  policies do
    # The prune trigger runs as a system job.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # System table: `KilnCMSWeb.Plugs.Idempotency` reads and writes it with
    # `authorize?: false`, and there is no actor-facing path to it at all.
    policy always() do
      forbid_if always()
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

    attribute :scope, :string, allow_nil?: false, constraints: [max_length: 100]
    attribute :key, :string, allow_nil?: false, constraints: [max_length: 255]
    attribute :fingerprint, :string, allow_nil?: false, constraints: [max_length: 64]

    attribute :status, :atom do
      allow_nil? false
      default :in_progress
      constraints one_of: [:in_progress, :completed]
    end

    attribute :response_status, :integer
    attribute :response_headers, :map, default: %{}

    # The bytes the first response sent (JSON, so a string), replayed as-is.
    attribute :response_body, :string, constraints: [trim?: false, allow_empty?: true]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_key, [:scope, :key]
  end
end
