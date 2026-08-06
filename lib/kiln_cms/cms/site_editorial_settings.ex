defmodule KilnCMS.CMS.SiteEditorialSettings do
  @moduledoc """
  Per-site editorial workflow settings (#818).

  Today that is one question: whether publishing a piece of content completes
  the open editorial tasks on it. The resource is named for the category rather
  than the setting because this is where the next such switch belongs — a
  `site_auto_complete_tasks` table would have to be replaced the first time
  editorial workflow grows a second option.

  ## Absence is the default, and the default is "on"

  Nothing creates a row on a read. A site that has never opened the settings
  page has no row, and `KilnCMS.CMS.TaskSettings` resolves that to the shipped
  default rather than writing one — the same shape as
  `KilnCMS.CMS.SiteLinkCheck` and for the same reason: looking at a page should
  not be a write.

  The default differs from `SiteLinkCheck`'s, though, and deliberately. That one
  defaults to **off** because turning it on makes the server issue outbound
  requests, so the row exists to make "on" a deliberate act. This one defaults
  to **on**, because auto-completion is the behaviour #501 shipped and every
  existing install already has it — a row that defaulted to off would silently
  change what happens on publish for everyone who upgrades.

  ## This is the default, not the verdict

  A task may override it (`KilnCMS.CMS.Task.auto_complete_on_publish`), which is
  the case this setting alone cannot serve: a follow-up task that should outlive
  the publish it is attached to. Resolve the pair through
  `KilnCMS.CMS.TaskSettings.auto_complete?/2` rather than reading either half
  directly.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "site_editorial_settings"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept [:auto_complete_tasks_on_publish]

    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org
      upsert_fields [:auto_complete_tasks_on_publish]
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # Editors read it: the task list and the content editor's task panel both
    # explain what publishing will do to an open task, and that sentence is
    # wrong if they cannot see the setting.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Changing what publishing does to everyone's tasks is an admin act.
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

    # `true` is what #501 shipped unconditionally. See the moduledoc on why this
    # default is the opposite of `SiteLinkCheck`'s.
    attribute :auto_complete_tasks_on_publish, :boolean do
      default true
      allow_nil? false
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
    identity :one_per_org, [:org_id]
  end
end
