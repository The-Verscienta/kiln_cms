defmodule KilnCMS.Federation.Follower do
  @moduledoc """
  A remote actor following this site (#491).

  One row per `(org, actor_uri)`. `inbox_uri` is where deliveries go — usually
  the actor's personal inbox, but a `sharedInbox` when the remote server
  publishes one, which is how a single POST reaches every follower on a large
  instance instead of one POST each.

  ## Failures are expected, and bounded

  Instances disappear without saying so — that is the normal case, not the
  exception. `consecutive_failures` counts exhausted deliveries and any success
  resets it; past `KilnCMS.Federation.drop_follower_after/0` the row is
  dropped. Without that ceiling a site accumulates dead followers forever and
  every publish pays to time out against all of them.
  """
  use Ash.Resource,
    domain: KilnCMS.Federation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "federation_followers"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    default_accept []

    read :deliverable do
      description "Followers a publish should be delivered to."
      prepare build(sort: [inserted_at: :asc])
    end

    create :follow do
      description "Record (or refresh) a remote actor's follow."
      upsert? true
      upsert_identity :one_per_actor
      upsert_fields [:inbox_uri, :shared_inbox_uri, :consecutive_failures]

      argument :actor_uri, :string, allow_nil?: false
      argument :inbox_uri, :string, allow_nil?: false
      argument :shared_inbox_uri, :string

      change set_attribute(:actor_uri, arg(:actor_uri))
      change set_attribute(:inbox_uri, arg(:inbox_uri))
      change set_attribute(:shared_inbox_uri, arg(:shared_inbox_uri))
      # A re-follow clears the failure count: the remote server is plainly
      # talking to us again, whatever happened before.
      change set_attribute(:consecutive_failures, 0)
    end

    update :record_failure do
      require_atomic? false
      accept []
      change increment(:consecutive_failures)
      change set_attribute(:last_failed_at, &DateTime.utc_now/0)
    end

    update :record_success do
      require_atomic? false
      accept []
      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:last_delivered_at, &DateTime.utc_now/0)
    end
  end

  # The inbox writes these with `authorize?: false`, the same way
  # `KilnCMS.Webhooks` dispatches: a remote `Follow` authenticates with an HTTP
  # signature, and there is no Kiln user behind it to be an actor. A `bypass`
  # would be the wrong tool — it skips every policy below it for anyone it
  # matches, which is a much wider hole than the one being opened.
  policies do
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

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

    attribute :actor_uri, :string do
      constraints max_length: KilnCMS.Limits.url()
      allow_nil? false
      public? true
    end

    attribute :inbox_uri, :string do
      constraints max_length: KilnCMS.Limits.url()
      allow_nil? false
      public? true
    end

    # Preferred when present: one POST reaches every follower on that instance.
    attribute :shared_inbox_uri, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    attribute :consecutive_failures, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :last_delivered_at, :utc_datetime_usec, public?: true
    attribute :last_failed_at, :utc_datetime_usec, public?: true

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
    identity :one_per_actor, [:org_id, :actor_uri]
  end

  @doc "Where a delivery to this follower should be POSTed."
  @spec delivery_inbox(t()) :: String.t()
  def delivery_inbox(%{shared_inbox_uri: shared}) when is_binary(shared) and shared != "",
    do: shared

  def delivery_inbox(%{inbox_uri: inbox}), do: inbox
end
