defmodule KilnCMS.CMS.TagGroup do
  @moduledoc """
  A named bucket of `Tag`s — the organizing layer above tags themselves.

  Tags are a flat many-to-many vocabulary, which stops scaling once a site has
  more than a couple dozen of them: the editor's tag picker becomes an
  undifferentiated wall of checkboxes. A tag group gives that wall structure —
  the picker renders one section per group, alphabetized within it.

  A tag belongs to at most one group (`Tag.tag_group_id`, nullable); tags
  without one are shown under "Ungrouped".

  Groups may be scoped to specific content types via `content_types`, so a
  site can offer a different tag vocabulary per type ("Post themes" on posts
  only). An **empty** list means the group applies everywhere — the same
  empty-means-unrestricted convention the RBAC type scopes use (see
  `KilnCMS.Accounts.Scoping`), and for the same reason: the list is tiny and
  matched in Elixir, never in SQL.

  Like `Category` and `Tag`, this is a lightweight, editor-managed,
  world-readable lookup resource (no versioning/workflow/soft-delete) — that
  shared shape comes from `KilnCMS.CMS.Taxonomy`, and what follows is a group's
  alone.
  """
  use KilnCMS.CMS.Taxonomy,
    type: :tag_group,
    accept: [:position, :content_types],
    includes: [:tags],
    admin_columns: [:name, :slug, :position, :inserted_at],
    # Picker order: the editor-chosen `position` first, name as the tiebreaker,
    # so an unordered set of groups still reads alphabetically. On the primary
    # read so every caller (the picker, the taxonomy manager, REST/GraphQL) gets
    # it without repeating it; internal uses are unaffected by an ORDER BY.
    read_sort: [position: :asc, name: :asc],
    # `KnownContentTypes` resolves each entry against the (per-org, DB-backed)
    # type registry, which can't run inside an atomic UPDATE.
    atomic_update?: false

  validations do
    # `content_types` is in `default_accept`, so without this every non-LiveView
    # write path (AshAdmin, seeds, code interfaces) could file a group under a
    # content type that doesn't exist — a UI checkbox is not a data-level guard
    # (#526). Only on writes; a stale entry on an existing row is not re-checked
    # on read.
    validate {KilnCMS.CMS.Validations.KnownContentTypes, []}, on: [:create, :update]
  end

  attributes do
    # Manual ordering of the picker's sections; ties break on name.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    # Content types this group applies to, as public type-name strings
    # (`"page"`, `"post"`, or a dynamic `TypeDefinition`'s name — the same
    # currency `KilnCMS.CMS.ContentTypes.type_name/1` speaks, so compiled and
    # admin-defined types are addressed uniformly).
    #
    # EMPTY MEANS EVERY TYPE, not "no types" — a group is unrestricted until an
    # editor narrows it. Matched in Elixir at the call site (the list is tiny),
    # mirroring `KilnCMS.Accounts.Scoping.permitted?/4`.
    attribute :content_types, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end
  end

  relationships do
    has_many :tags, KilnCMS.CMS.Tag do
      public? true
    end
  end

  aggregates do
    # Usage count for the taxonomy management UI (and public APIs).
    count :tag_count, :tags do
      public? true
    end
  end
end
