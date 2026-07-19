defmodule KilnCMS.Automation.Rule do
  @moduledoc """
  A no-code editorial automation rule — Kiln's answer to Directus Flows (#342).

  "**When** X happens **to** this content type, **do** Y." A rule pairs a
  lifecycle trigger (`published` / `unpublished` / `updated`) — optionally scoped
  to one content type — with a single reaction (`send_email`, `broadcast`,
  `invalidate_cache`, `reindex`). Rules are admin-managed data; the executor
  (`KilnCMS.Automation`) evaluates them off-request on Oban when the matching
  editorial event fires. No embedded scripting runtime — pure Elixir over the
  primitives Kiln already runs (Oban + state machine + PubSub + MTA).
  """
  use Ash.Resource,
    domain: KilnCMS.Automation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  # Lifecycle events an editorial rule can trigger on — the same verbs the
  # webhook system emits (`KilnCMS.CMS.WebhookEndpoint.verbs/0`), which is where
  # automation is evaluated from.
  @triggers [:published, :unpublished, :updated]

  # Reactions. HTTP/Slack notifications are the (signed, SSRF-safe) webhook
  # feature's job; automation adds the reactions webhooks can't do.
  # `:flag_duplicates` / `:suggest_tags` (#377) are the embedding-driven
  # editorial-intelligence reactions — e.g. "on in_review → email the editors
  # any near-duplicates" as a lightweight review gate (the :in_review trigger
  # itself ships with #375).
  @action_kinds [
    :send_email,
    :broadcast,
    :invalidate_cache,
    :reindex,
    :flag_duplicates,
    :suggest_tags
  ]

  @doc "Lifecycle events a rule can trigger on."
  def triggers, do: @triggers

  @doc "Reaction kinds a rule can perform."
  def action_kinds, do: @action_kinds

  admin do
    resource_group :system
    table_columns [:name, :trigger_event, :content_type, :action, :enabled]
  end

  postgres do
    table "automation_rules"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :name,
      :description,
      :trigger_event,
      :content_type,
      :action,
      :config,
      :enabled
    ]

    create :create, primary?: true

    update :update do
      primary? true
      require_atomic? false
    end

    # The executor's lookup: enabled rules for a lifecycle event, matching either
    # a specific content type or any (`content_type` is nil).
    read :matching do
      argument :trigger_event, :atom, allow_nil?: false
      argument :content_type, :string, allow_nil?: false

      filter expr(
               enabled == true and trigger_event == ^arg(:trigger_event) and
                 (is_nil(content_type) or content_type == ^arg(:content_type))
             )
    end
  end

  policies do
    # Editor-workflow configuration is admin-only; the executor reads with
    # `authorize?: false` (system job).
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  # Multi-tenancy (epic #336): a rule belongs to one site, so a lifecycle event
  # only fires its own org's rules. `global?: true` keeps the tenant optional;
  # the executor's `:matching` scan (`authorize?: false`) is scoped to the
  # publishing record's org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped create,
    # else the default org; never accepted from input (absent from `default_accept`).
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    attribute :trigger_event, :atom do
      allow_nil? false
      constraints one_of: @triggers
      public? true
    end

    # nil = any content type; otherwise the public type name ("post", "page", a
    # dynamic type's name).
    attribute :content_type, :string, public?: true

    attribute :action, :atom do
      allow_nil? false
      constraints one_of: @action_kinds
      public? true
    end

    # Action parameters (e.g. `%{"to" => …, "subject" => …}` for send_email).
    attribute :config, :map, allow_nil?: false, default: %{}, public?: true

    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
