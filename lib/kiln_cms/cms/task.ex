defmodule KilnCMS.CMS.Task do
  @moduledoc """
  An editorial task (#501, the *ownership* half of editorial collaboration —
  `KilnCMS.CMS.Comment` from #404 is the *discussion* half): "who owns this
  content next, and by when." Kiln's workflow states say what stage content
  is in but never who's on the hook for the next step.

  Anchored the same soft-polymorphic way as `Comment` / `Consent` /
  `HistoryAnchor` — `content_type` + `content_id`, no FK, because it has to
  resolve across compiled content types AND dynamic `:entry` types alike.
  Deliberately lightweight: no sub-tasks, no priority levels, no board — an
  assignee, a due date, a note, and a status.

  ## Block anchoring

  Optionally narrowed one level further by `block_id` — the same stable
  `Kiln.Block` id `Comment` anchors to, and soft for the same reason (blocks
  live in a jsonb array, not a table). `nil` is the original shape and stays
  the default: a task on the whole document. A `block_id` says "this
  *paragraph* is what needs work", which is what turns a block's comment
  thread into accountable follow-up without leaving the block.

  Because the anchor is soft, deleting a block does **not** delete its tasks —
  they become orphans, still readable through `:for_content`, shown with a
  "block removed" label rather than vanishing silently. Nothing cascades.

  A record's open tasks are auto-completed when it publishes (see
  `KilnCMS.CMS.Changes.AutoCompleteTasks`, attached to `:publish` /
  `:publish_scheduled`) — publishing is the natural "done" signal for
  "get this reviewed/finished", and an editor who forgets to close out their
  own task shouldn't leave a stale queue entry behind. Reopening is manual.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :content
    table_columns [:content_type, :block_id, :assignee_id, :due_on, :status, :inserted_at]
  end

  postgres do
    table "tasks"
    repo KilnCMS.Repo

    custom_indexes do
      # `block_id` trails the content columns rather than getting an index of
      # its own: `:for_content` (three-column equality) still matches on the
      # leading prefix, and `:for_block` gets the whole key. Same single-index
      # shape `Comment` uses for the same pair of reads.
      index [:org_id, :content_type, :content_id, :block_id],
        name: "tasks_content_lookup_index"

      index [:org_id, :assignee_id, :status], name: "tasks_assignee_lookup_index"
    end
  end

  actions do
    defaults [:read]

    # The automation's idempotency probe (docs/content-lifecycles.md): the
    # health sweep re-fires every day a record stays overdue, so the reaction
    # asks this before creating anything. Narrow on purpose — content, kind and
    # open-ness — because that triple is exactly "someone has already been asked
    # to do this and has not done it yet".
    read :open_for_content_kind do
      description "Open tasks of one kind on one piece of content."
      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false
      argument :kind, :atom, allow_nil?: false

      filter expr(
               content_type == ^arg(:content_type) and content_id == ^arg(:content_id) and
                 kind == ^arg(:kind) and status == :open
             )
    end

    create :assign do
      description "Assign an editorial task on a piece of content."
      primary? true

      accept [
        :content_type,
        :content_id,
        :block_id,
        :assignee_id,
        :due_on,
        :note,
        :auto_complete_on_publish,
        :kind
      ]

      validate KilnCMS.CMS.Validations.AssigneeIsEditor

      change fn changeset, context ->
        case context.actor do
          %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :creator_id, id)
          _ -> changeset
        end
      end

      change KilnCMS.CMS.Changes.NotifyTaskAssigned
      change KilnCMS.CMS.Changes.BroadcastTaskBlock
    end

    update :update do
      description "Reassign a task, change its due date / note, or re-anchor it to a block."
      primary? true
      accept [:assignee_id, :due_on, :note, :auto_complete_on_publish, :block_id]
      require_atomic? false

      validate KilnCMS.CMS.Validations.AssigneeIsEditor

      # Reassigning resets the overdue-webhook gate: a task handed to someone
      # new shouldn't stay silently gated by the previous assignee's overdue
      # notice (and a later due-date push past "today" makes it not-overdue
      # again anyway, so the flag would be stale either way).
      change fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :assignee_id) or
             Ash.Changeset.changing_attribute?(changeset, :due_on) do
          Ash.Changeset.force_change_attribute(changeset, :overdue_notified_on, nil)
        else
          changeset
        end
      end

      change {KilnCMS.CMS.Changes.NotifyTaskAssigned, only_when: :reassigned}
      change KilnCMS.CMS.Changes.BroadcastTaskBlock
    end

    update :complete do
      description "Mark a task done."
      accept []
      require_atomic? false

      change KilnCMS.CMS.Changes.BroadcastTaskBlock
      change set_attribute(:status, :done)
      change set_attribute(:completed_at, &DateTime.utc_now/0)

      change fn changeset, context ->
        case context.actor do
          %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :completed_by_id, id)
          _ -> changeset
        end
      end
    end

    update :reopen do
      description "Reopen a completed task."
      accept []
      require_atomic? false

      change KilnCMS.CMS.Changes.BroadcastTaskBlock
      change set_attribute(:status, :open)
      change set_attribute(:completed_at, nil)
      change set_attribute(:completed_by_id, nil)
      change set_attribute(:overdue_notified_on, nil)
    end

    # System action: the digest worker stamps this after dispatching a
    # `task.overdue` automation event, so the same task doesn't re-fire that
    # event every day it stays overdue (the email digest, by contrast, is
    # SUPPOSED to repeat daily — see `KilnCMS.Notifications.TaskDigestWorker`).
    update :mark_overdue_notified do
      accept []
      require_atomic? false
      change set_attribute(:overdue_notified_on, &Date.utc_today/0)
    end

    read :for_content do
      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false

      filter expr(content_type == ^arg(:content_type) and content_id == ^arg(:content_id))
      prepare build(sort: [inserted_at: :asc])
    end

    read :for_block do
      description "A single block's tasks — the block-anchored twin of `Comment.for_block`."
      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false
      argument :block_id, :uuid, allow_nil?: false

      filter expr(
               content_type == ^arg(:content_type) and content_id == ^arg(:content_id) and
                 block_id == ^arg(:block_id)
             )

      prepare build(sort: [inserted_at: :asc])
    end

    read :open_for_content do
      description """
      Every open task on a piece of content, block-anchored or not — one query
      the editor groups by `block_id` in memory to drive per-block counts.

      Deliberately not a grouped/aggregate read: an editor open on a document
      has tens of tasks, not thousands, and returning the rows means the same
      query serves both the gutter counts and the task list without a second
      round trip. Grouping server-side would save nothing and cost a read that
      can't show *which* tasks.
      """

      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false

      filter expr(
               content_type == ^arg(:content_type) and content_id == ^arg(:content_id) and
                 status == :open
             )

      prepare build(sort: [inserted_at: :asc])
    end

    read :for_assignee do
      description "An assignee's open tasks (the my-tasks queue)."
      argument :assignee_id, :uuid, allow_nil?: false

      filter expr(assignee_id == ^arg(:assignee_id) and status == :open)
      prepare build(sort: [due_on: :asc_nils_last])
    end

    # Org-wide, system reads (calendar chips + the digest worker) — scoped by
    # tenant, not by actor, since both callers already resolve their own
    # authorization context (calendar: the viewing editor; digest: a cron job
    # with none).
    read :open_due_between do
      description "Open tasks due within a date window (calendar chips, digest)."
      argument :from, :date, allow_nil?: false
      argument :to, :date, allow_nil?: false

      filter expr(
               status == :open and not is_nil(due_on) and due_on >= ^arg(:from) and
                 due_on <= ^arg(:to)
             )

      prepare build(sort: [due_on: :asc])
    end

    read :due_within do
      description "Open tasks due today-or-earlier, or within `to` (the digest worker)."
      argument :to, :date, allow_nil?: false

      filter expr(status == :open and not is_nil(due_on) and due_on <= ^arg(:to))
      prepare build(sort: [due_on: :asc])
    end

    read :newly_overdue do
      description "Open, overdue tasks that haven't fired a task.overdue event yet."

      filter expr(
               status == :open and not is_nil(due_on) and due_on < today() and
                 is_nil(overdue_notified_on)
             )
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Editor-facing only — no audience/public-read carve-out, same as Comment:
    # a task is never part of a delivered document.
    policy action_type([:create, :read]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    policy action_type(:update) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end
  end

  # Multi-tenancy (epic #336): a task belongs to the same site as the content
  # it targets. `global?: true` keeps the tenant optional.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped
    # create, else the default org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Soft polymorphic reference to the content item (matches Comment /
    # Consent / HistoryAnchor), not an FK — has to reach dynamic `:entry`
    # types too.
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    # Optional narrowing to one block (`Kiln.Block`'s `uuid_primary_key :id`),
    # not FK-checked — blocks are embedded in a jsonb array, not a table, the
    # same reason `Comment.block_id` is soft. Unlike `Comment`'s, nullable:
    # `nil` is a task on the whole document, which is every task that existed
    # before this column and the default for the settings-panel form.
    attribute :block_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :due_on, :date, public?: true
    attribute :note, :string, public?: true, constraints: [max_length: KilnCMS.Limits.paragraph()]

    # Whether publishing this task's content completes it (#818).
    #
    # **`nil` is a third value, not a missing one**: it means "whatever the site
    # is set to" (`SiteEditorialSettings.auto_complete_tasks_on_publish`).
    # `true`/`false` override that for this task alone, which is the case the
    # site setting cannot serve — a follow-up task deliberately outliving the
    # publish it hangs off.
    #
    # So `allow_nil? true` and no default. A default of `true` here would be a
    # different feature: every task would carry an explicit opt-in written at
    # assign time, and changing the site setting afterwards would move none of
    # them. Resolve the pair with `KilnCMS.CMS.TaskSettings.auto_complete?/2`.
    attribute :auto_complete_on_publish, :boolean do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:open, :done]
      default :open
      allow_nil? false
      public? true
    end

    # Who raised this task, in kind rather than by creator. `:manual` is an
    # editor assigning work; `:lifecycle_review` is one raised automatically
    # because a record's freshness lapsed (docs/content-lifecycles.md).
    #
    # A column rather than a convention on `note`, because it is what makes the
    # automated half *idempotent*: a daily sweep re-fires for as long as content
    # stays overdue, and "is there already an open lifecycle task on this
    # content" has to be a query, not a string match on a human-editable field.
    # It is also the axis the task list filters on — an editor who wants to see
    # what they personally were asked to do should not have to wade through a
    # quarter's worth of automated review reminders.
    attribute :kind, :atom do
      constraints one_of: [:manual, :lifecycle_review]
      default :manual
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      writable? false
      public? true
    end

    attribute :completed_by_id, :uuid do
      writable? false
      public? true
    end

    # Set once the digest worker has dispatched a `task.overdue` automation
    # event for this task, so it fires once rather than once per day — see
    # `:mark_overdue_notified`. Cleared on reassignment/due-date change/reopen.
    attribute :overdue_notified_on, :date do
      writable? false
      public? false
    end

    # The user who created the task — stamped from the acting user, not
    # accepted from input.
    attribute :creator_id, :uuid do
      allow_nil? false
      writable? false
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

    belongs_to :assignee, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :creator, KilnCMS.Accounts.User do
      source_attribute :creator_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :completed_by, KilnCMS.Accounts.User do
      source_attribute :completed_by_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
