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
  # automation is evaluated from. `:in_review` / `:returned_to_draft` are the
  # review-workflow transitions (#375), so "on `in_review` → notify" rules work.
  #
  # `:assigned` / `:overdue` (#501) are task-domain, not content-type-domain —
  # `KilnCMS.Notifications.Tasks` dispatches them as `"task.assigned"` /
  # `"task.overdue"` through the same `KilnCMS.Webhooks.dispatch/3` funnel.
  # `Automation.handle_event/3` only ever splits the event string on its first
  # "." and matches the verb against this list, so a literal `"task"` type
  # works with no executor changes — a rule scoped to `content_type: "task"`
  # matches exactly like one scoped to `content_type: "page"`.
  @triggers [
    :published,
    :unpublished,
    :updated,
    :in_review,
    :returned_to_draft,
    :assigned,
    :overdue
  ]

  # Reactions. HTTP/Slack notifications are the (signed, SSRF-safe) webhook
  # feature's job; automation adds the reactions webhooks can't do.
  # `:newsletter` (#376) fans a published document out to subscribers via the
  # existing newsletter machinery — "on publish → send the newsletter".
  # `:flag_duplicates` / `:suggest_tags` / `:suggest_links` / `:suggest_metadata`
  # (#377) are the editorial-intelligence reactions — e.g. "on in_review → email
  # the editors any near-duplicates" as a lightweight review gate.
  #
  # Every one of them **suggests and never writes**, which is the design answer
  # to the reason this issue's automation form was held back: drafted metadata
  # lands in `<meta>` tags on the public site, so a successful prompt injection
  # buys SEO cloaking on the operator's own domain, and human-in-the-loop is the
  # primary control against that. Automation makes the *computation* unattended;
  # accepting a value stays a click in the editor. A reaction that wrote
  # `seo_description` on a state transition would remove the primary control
  # entirely — see `KilnCMS.Seo.Generator`.
  # `:social_post` (#497) announces a publish to the site's configured Bluesky /
  # Mastodon accounts (`KilnCMS.Social`). Config: `"provider"` (required) and an
  # optional `"template"`. It is the one reaction that writes somewhere the
  # operator cannot quietly undo, which is why the machinery behind it is
  # at-most-once rather than at-least-once.
  @action_kinds [
    :send_email,
    :broadcast,
    :invalidate_cache,
    :reindex,
    :newsletter,
    :flag_duplicates,
    :suggest_tags,
    :suggest_links,
    :suggest_metadata,
    :social_post
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
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  validations do
    # `config` is a free map read defensively by every reaction, so a rule with
    # a missing or misspelled key saved fine, listed as enabled, and did
    # nothing — forever, with the only evidence in a server log (#944). On
    # create and update both: an action can be changed on an existing rule, and
    # the config that suited the old one usually does not suit the new one.
    validate KilnCMS.Automation.Validations.ActionConfig, on: [:create, :update]
  end

  # Multi-tenancy (epic #336): a rule belongs to one site, so a lifecycle event
  # only fires its own org's rules. `global?: true` keeps the tenant optional;
  # the executor's `:matching` scan (`authorize?: false`) is scoped to the
  # publishing record's org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
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

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :description, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

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
