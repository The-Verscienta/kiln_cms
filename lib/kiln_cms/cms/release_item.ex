defmodule KilnCMS.CMS.ReleaseItem do
  @moduledoc """
  One pending change inside a `KilnCMS.CMS.ContentRelease` (#500): "publish this
  page" or "take this post down", when the release goes live.

  Anchored the soft-polymorphic way every cross-type pointer in Kiln is —
  `content_type` + `content_id`, no foreign key — because content is spread
  across `Page`/`Post` plus every admin-defined dynamic type (D17), which share
  the `Entry` table. `KilnCMS.Firing.ReferenceEdge` is the precedent; `Comment`,
  `Task` and `Consent` use the same `{type, id}` pair.

  ## One open release per record

  > A record can appear in at most one open release.

  That is enforced by the database, not by the application: the
  `:one_pending_per_content` identity is a **partial** unique index over
  `(org_id, content_type, content_id) WHERE status = 'pending'`. Two editors
  adding the same page to two different releases at the same moment is exactly
  the race a check-then-insert loses, and it is the race that produces a
  half-planned campaign nobody can see.

  A partial index cannot reach across to the parent release's `state`, so
  `status` carries the reservation on the item itself and the release's own
  transitions maintain it (`KilnCMS.CMS.Releases`):

    * `:pending` — reserved. Set on add; held while the release is open,
      scheduled, publishing, or failed-and-retryable.
    * `:applied` — the change was made at go-live. Rollback undoes exactly these.
    * `:skipped` — the change was already true when the release fired (someone
      published the page by hand first). Not a failure: the release's desired end
      state holds. Rollback leaves these alone, because the release didn't put
      them there.
    * `:cancelled` — removed from the release, or the release was archived
      without shipping.
    * `:rolled_back` — undone by a group rollback.

  ## Prior state, captured at go-live

  `prior_state` and `prior_version_id` are recorded **before** each item's
  transition runs, which is the only moment they are knowable. They are what
  makes group rollback exact rather than approximate: an unpublish item knows
  which published version was live before it took the content down, so rolling
  back restores *that* body even if someone edited the record while it was dark.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  @statuses [:pending, :applied, :skipped, :cancelled, :rolled_back]

  @doc "Every lifecycle status a release item can hold."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  admin do
    resource_group :content
    table_columns [:content_type, :action, :status, :inserted_at]
  end

  postgres do
    table "release_items"
    repo KilnCMS.Repo

    references do
      # Deleting a release takes its items with it — the items have no meaning
      # without the bundle, and the destroy action refuses on any release that
      # actually shipped (`Validations.ReleaseDeletable`).
      reference :release, on_delete: :delete
    end

    # SQL for the partial `:one_pending_per_content` identity, so the generated
    # unique index only constrains rows still reserving their content.
    identity_wheres_to_sql one_pending_per_content: "status = 'pending'"

    custom_indexes do
      index [:org_id, :release_id, :status], name: "release_items_release_status_index"
    end
  end

  actions do
    defaults [:read]

    create :add do
      description "Add a content record to a release."
      primary? true
      accept [:release_id, :content_type, :content_id, :action]

      validate KilnCMS.CMS.Validations.KnownContentType
      # Granular RBAC (#332) reaches this resource through the `content_type`
      # attribute, not through the resource being written — see the validation.
      # Without it, "add to release" is a hole straight through the type scope,
      # and the release preview link renders whatever went through it.
      validate KilnCMS.CMS.Validations.EditableReleaseContent
      validate KilnCMS.CMS.Validations.ReleaseOpenForEdit
      change KilnCMS.CMS.Changes.StampReleaseItemAdder
    end

    update :cancel do
      description "Remove the item from its release; the content is free again."
      accept []
      require_atomic? false

      validate KilnCMS.CMS.Validations.ReleaseOpenForEdit
      change set_attribute(:status, :cancelled)
    end

    # System actions, run by `KilnCMS.CMS.Releases` inside the go-live /
    # rollback transaction. Not reachable by any actor (no policy authorizes
    # them) — the release's own admin-gated transitions are the gate.
    update :mark_applied do
      description "System: the item's change was made at go-live."
      accept []
      require_atomic? false

      argument :prior_state, :atom
      argument :prior_version_id, :uuid

      change set_attribute(:status, :applied)
      change set_attribute(:prior_state, arg(:prior_state))
      change set_attribute(:prior_version_id, arg(:prior_version_id))
      change set_attribute(:applied_at, &DateTime.utc_now/0)
    end

    update :mark_skipped do
      description "System: the item's change was already true when the release fired."
      accept []
      require_atomic? false

      argument :prior_state, :atom

      change set_attribute(:status, :skipped)
      change set_attribute(:prior_state, arg(:prior_state))
      change set_attribute(:applied_at, &DateTime.utc_now/0)
    end

    update :mark_rolled_back do
      description "System: the item's change was undone by a group rollback."
      accept []
      require_atomic? false

      change set_attribute(:status, :rolled_back)
    end

    # The unvalidated twin of `:cancel`, for `Changes.CancelPendingReleaseItems`.
    # It runs from an `after_action` hook on the release's own `:archive`, by
    # which point the release row already reads `:archived` inside the
    # transaction — so `:cancel`'s `ReleaseOpenForEdit` validation would refuse
    # the very write that archiving requires.
    update :mark_cancelled do
      description "System: the release was closed out without shipping this item."
      accept []
      require_atomic? false

      change set_attribute(:status, :cancelled)
    end

    read :for_release do
      description "A release's items, in the order they were added."
      argument :release_id, :uuid, allow_nil?: false

      filter expr(release_id == ^arg(:release_id))
      prepare build(sort: [inserted_at: :asc])
    end

    read :for_release_with_status do
      description "A release's items in one status (go-live and rollback both scan this)."
      argument :release_id, :uuid, allow_nil?: false
      argument :status, :atom, allow_nil?: false

      filter expr(release_id == ^arg(:release_id) and status == ^arg(:status))
      prepare build(sort: [inserted_at: :asc])
    end

    read :for_releases do
      description "Items across several releases at once (the console's item counts)."
      argument :release_ids, {:array, :uuid}, allow_nil?: false

      filter expr(release_id in ^arg(:release_ids))
    end

    read :pending_for_content do
      description "The open reservation on one content record, if any."
      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false

      filter expr(
               content_type == ^arg(:content_type) and content_id == ^arg(:content_id) and
                 status == :pending
             )
    end
  end

  policies do
    # No blanket `OrgAdmin` bypass, for the reason spelled out on
    # `KilnCMS.CMS.ContentRelease`: a bypass skips every policy below it, which
    # would let a human call the `mark_*` writes and rewrite the `prior_state` /
    # `prior_version_id` that rollback restores from. `OrgEditor` matches admins
    # too, so nothing legitimate is lost.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Editors compose a release's contents. The `mark_*` writes carry no policy
    # on purpose: they are only ever reached from the release worker, which runs
    # `authorize?: false` after an admin claimed the release.
    policy action([:add, :cancel]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end
  end

  # Multi-tenancy (epic #336): an item belongs to the same site as its release
  # and its content. `global?: true` keeps the tenant optional.
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

    # Soft polymorphic reference to the content record — not an FK, so it can
    # reach dynamic `:entry` types by name too (matches Comment / Task).
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    attribute :action, :atom do
      description "What the release does to this record when it goes live."
      constraints one_of: [:publish, :unpublish]
      default :publish
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: @statuses
      default :pending
      allow_nil? false
      public? true
    end

    # Captured immediately BEFORE the item's transition runs — see the moduledoc.
    attribute :prior_state, :atom do
      writable? false
      public? true
    end

    attribute :prior_version_id, :uuid do
      writable? false
      public? true
    end

    attribute :applied_at, :utc_datetime_usec do
      writable? false
      public? true
    end

    attribute :added_by_id, :uuid do
      writable? false
      public? false
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

    belongs_to :release, KilnCMS.CMS.ContentRelease do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :added_by, KilnCMS.Accounts.User do
      source_attribute :added_by_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    # The issue's conflict rule, enforced in Postgres: at most one PENDING item
    # per content record per org. See the moduledoc for why this is a partial
    # index on the item rather than a check against the release's state.
    identity :one_pending_per_content, [:content_type, :content_id] do
      where expr(status == :pending)
      message "is already in another open release"
    end
  end
end
