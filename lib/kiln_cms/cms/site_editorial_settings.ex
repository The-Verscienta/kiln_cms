defmodule KilnCMS.CMS.SiteEditorialSettings do
  @moduledoc """
  Per-site editorial workflow settings (#818).

  Two questions: whether publishing a piece of content completes the open
  editorial tasks on it, and whether editors may publish on this site at all
  (`editors_can_publish`, resolved by `KilnCMS.CMS.EditorialSettings`). The
  resource is named for the category rather than a setting so the second switch
  had somewhere to go.

  **Write it through `KilnCMS.CMS.EditorialSettings.save/2`.** `:save` is an
  upsert and every column has a default, so a save that omits a column writes
  that column's default over what the site chose — saving the task default
  alone would quietly take publishing away from editors.

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
  # The shared one-row-per-org shape — tenancy, `:one_per_org`, the `:save`
  # upsert, the write policy — comes from `KilnCMS.CMS.OrgSettings` (#1080).
  # Editors read it: the task list and the content editor's task panel both
  # explain what publishing will do to an open task, and that sentence is
  # wrong if they cannot see the setting. Changing it is an admin act.
  use KilnCMS.CMS.OrgSettings,
    table: "site_editorial_settings",
    accept: [:auto_complete_tasks_on_publish, :editors_can_publish],
    read: :editor,
    update?: false

  attributes do
    # `true` is what #501 shipped unconditionally. See the moduledoc on why this
    # default is the opposite of `SiteLinkCheck`'s.
    attribute :auto_complete_tasks_on_publish, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # Whether an editor may publish (and schedule a publish) directly, rather
    # than submitting for an admin's review. Defaults to `false` — the rule
    # every install had before this existed — so an upgrade never widens who
    # can put content in front of visitors; `/setup` asks a new site instead.
    # Read through `KilnCMS.CMS.EditorialSettings.editors_can_publish?/1`, which
    # fails closed.
    attribute :editors_can_publish, :boolean do
      default false
      allow_nil? false
      public? true
    end
  end
end
