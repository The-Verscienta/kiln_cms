defmodule KilnCMS.CMS.Comment do
  @moduledoc """
  An editorial comment anchored to a specific block within a piece of content
  (#404, the last unbuilt piece of the collaboration epic #350) — feedback
  during review, never delivered content. Surfaced in the block editor only;
  never reachable from the public or headless delivery surface.

  Anchored the same soft-polymorphic way as `KilnCMS.CMS.Consent` /
  `KilnCMS.CMS.HistoryAnchor` — `content_type` + `content_id`, no FK, because
  it has to resolve across compiled content types AND dynamic `:entry` types
  alike — plus a `block_id`: the stable id every block carries regardless of
  type (`Kiln.Block`), not FK-checked either, since blocks live inside a jsonb
  array rather than a table of their own.

  Every comment on the same block belongs to **one** thread — the issue's own
  wording is "a comment thread anchored to a block id", singular. The first
  comment on a block *is* the thread (`thread_id` stays nil); every comment
  after it is routed to that same thread automatically by
  `KilnCMS.CMS.Changes.RouteToBlockThread` — a client only ever says "add a
  comment to this block", never which thread, so there is nothing for it to
  get wrong. Resolving is therefore a property of the block's one thread: only
  the root (`thread_id: nil`) can be resolved/unresolved, and a reply has no
  resolved state of its own.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :content
    table_columns [:content_type, :block_id, :body, :resolved_at, :inserted_at]
  end

  postgres do
    table "comments"
    repo KilnCMS.Repo

    custom_indexes do
      index [:org_id, :content_type, :content_id, :block_id],
        name: "comments_block_lookup_index"
    end
  end

  actions do
    defaults [:read]

    create :add do
      description "Add a comment to a block (starts or continues its one thread)."
      primary? true
      accept [:content_type, :content_id, :block_id, :body]

      change KilnCMS.CMS.Changes.RouteToBlockThread
      change KilnCMS.CMS.Changes.BroadcastComment
      change {KilnCMS.CMS.Changes.NotifyComment, event: :comment_added}

      change fn changeset, context ->
        case context.actor do
          %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :author_id, id)
          _ -> changeset
        end
      end
    end

    update :resolve do
      description "Mark a block's comment thread resolved (root comment only)."
      accept []
      require_atomic? false

      validate KilnCMS.CMS.Validations.CommentIsThreadRoot

      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change KilnCMS.CMS.Changes.BroadcastComment
      change {KilnCMS.CMS.Changes.NotifyComment, event: :comment_resolved}

      change fn changeset, context ->
        case context.actor do
          %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :resolved_by_id, id)
          _ -> changeset
        end
      end
    end

    update :unresolve do
      description "Reopen a resolved thread (root comment only)."
      accept []
      require_atomic? false

      validate KilnCMS.CMS.Validations.CommentIsThreadRoot

      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_by_id, nil)
      change KilnCMS.CMS.Changes.BroadcastComment
    end

    read :for_content do
      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false

      filter expr(content_type == ^arg(:content_type) and content_id == ^arg(:content_id))
      prepare build(sort: [inserted_at: :asc])
    end

    read :unresolved_for_content do
      description """
      The unresolved thread *roots* on a piece of content — one row per block
      that still has an open discussion.

      Only roots (`thread_id` is nil) are returned, because resolution is a
      property of the block's one thread and a reply carries no resolved state
      of its own. So the row count is the count of blocks needing attention,
      which is what the editor header and the governance cards report — no
      `Enum.uniq_by(:block_id)` at the call site to get it right.
      """

      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false

      filter expr(
               content_type == ^arg(:content_type) and content_id == ^arg(:content_id) and
                 is_nil(thread_id) and is_nil(resolved_at)
             )

      prepare build(sort: [inserted_at: :asc])
    end

    read :for_block do
      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false
      argument :block_id, :uuid, allow_nil?: false

      filter expr(
               content_type == ^arg(:content_type) and content_id == ^arg(:content_id) and
                 block_id == ^arg(:block_id)
             )

      prepare build(sort: [inserted_at: :asc])
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Editor-facing only — no audience/public-read carve-out, unlike content
    # links: a comment thread is never part of a delivered document.
    policy action_type([:create, :read]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    policy action_type(:update) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end
  end

  # Multi-tenancy (epic #336): a comment belongs to the same site as the
  # content it annotates. `global?: true` keeps the tenant optional.
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

    # Soft polymorphic reference to the content item (matches Consent /
    # HistoryAnchor), not an FK — has to reach dynamic `:entry` types too.
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    # The block's own stable id (`Kiln.Block`'s `uuid_primary_key :id`), not
    # FK-checked — blocks are embedded in a jsonb array, not a table.
    attribute :block_id, :uuid, allow_nil?: false, public?: true

    # nil on the comment that starts a block's thread; the root's own id on
    # every reply. Never client-writable — `RouteToBlockThread` sets it.
    attribute :thread_id, :uuid do
      writable? false
      public? true
    end

    attribute :body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    # The user who wrote the comment — stamped from the acting user, not
    # accepted from input.
    attribute :author_id, :uuid do
      allow_nil? false
      writable? false
      public? true
    end

    attribute :resolved_at, :utc_datetime_usec do
      writable? false
      public? true
    end

    attribute :resolved_by_id, :uuid do
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

    belongs_to :author, KilnCMS.Accounts.User do
      source_attribute :author_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :resolved_by, KilnCMS.Accounts.User do
      source_attribute :resolved_by_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
