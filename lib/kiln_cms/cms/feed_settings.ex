defmodule KilnCMS.CMS.FeedSettings do
  @moduledoc """
  Per-org syndication policy (#719): which content types appear in this site's
  feeds, and which of them carry their rendered body rather than a summary.

  Both used to be `config :kiln_cms, :feeds` only, which is the wrong grain for
  a multi-tenant install — `full_content` in particular has a real disclosure
  consequence, and the switch lived in a file a tenant admin cannot edit. This
  row is the per-org layer above that config; see `KilnCMS.Feeds` for how the
  two resolve.

  One row per organization — the `KilnCMS.CMS.FormSpamSettings` shape: admin-only
  settings with no `paper_trail` history and no public read policy (the delivery
  path reads it as a system read, cached, exactly as `KilnCMS.Branding` does).
  The row is created lazily by `:save`, never by a read, so a site that never
  touches the page costs nothing.

  ## Why both columns are nullable

  `nil` means *"inherit the operator default"*; `[]` means *"the admin said none"*.
  Collapsing the two would make an admin who clears the full-content list fall
  back to a config that turns it on for everyone — the exact inversion this
  issue exists to remove. `/editor/feeds` writes explicit lists on save and drops
  the whole row on "reset", which is how an admin gets back to `nil`.
  """
  # The shared one-row-per-org shape comes from `KilnCMS.CMS.OrgSettings`
  # (#1080). Never delivered as a document the way branding is: the resolved
  # policy reaches the delivery path through `KilnCMS.Feeds`, which reads it as
  # a system read. So no public read here.
  use KilnCMS.CMS.OrgSettings,
    table: "feed_settings",
    accept: [:excluded_types, :full_content_types],
    read: :admin,
    admin_columns: [:excluded_types, :full_content_types, :updated_at]

  # A ceiling on how many type names one list may carry. Comfortably above any
  # real site's type count, and there only so a settings row can never make a
  # per-request `not in` scan unbounded.
  @max_types 1_000

  # On a conflict AshPostgres narrows the `:save` upsert's fields to the
  # attributes the changeset actually carries, so omitting one column leaves it
  # alone rather than nulling it — which is what makes a partial
  # `save_feed_settings(%{full_content_types: […]})` safe. That narrowing is
  # computed across a whole *batch*, so a bulk upsert mixing rows that set
  # different columns would write NULL into the one a given row omitted, and a
  # NULL here does not mean "unchanged", it means "inherit the operator
  # config" — the inversion #719 exists to remove. Write these one row at a
  # time, which is all `/editor/feeds` and the code interface ever do.
  changes do
    change KilnCMS.CMS.Changes.BustFeedSettings, on: [:create, :update, :destroy]
  end

  attributes do
    # Content-type **names** (`"post"`, `"page"`, a dynamic type's own name), the
    # same spelling `config :kiln_cms, :feeds` uses and the one `ContentTypes`
    # descriptors carry. Names rather than ids because compiled types have no
    # row to point at, and a name that no longer resolves is inert rather than a
    # dangling reference.
    #
    # Bounded like `FormSpamSettings`' keyword list: a settings value must never
    # be able to make a per-request filter unbounded. The bounds are sized to
    # what a content type can actually be, not picked round: a name is a
    # `TypeDefinition.name` (or a compiled type's), so it is held to
    # `KilnCMS.Limits.line()` there and a tighter cap here would make a legally
    # created type impossible to exclude — the save would fail with a length
    # error naming a constraint no admin can see, on every subsequent visit to
    # the page. The list bound is `@max_types` for the same reason: exclusions
    # are derived by subtraction over *every* type a site has.
    attribute :excluded_types, {:array, :string} do
      allow_nil? true
      public? true
      constraints max_length: @max_types, items: [max_length: KilnCMS.Limits.line()]
    end

    attribute :full_content_types, {:array, :string} do
      allow_nil? true
      public? true
      constraints max_length: @max_types, items: [max_length: KilnCMS.Limits.line()]
    end
  end
end
