defmodule KilnCMS.CMS.RelatedLink do
  @moduledoc """
  The curated related-content rows of `content_links` — `kind: :related` and
  no `field` — as the join resource of every `related_<type>s` relationship
  (#2025).

  It is the same table as `KilnCMS.CMS.ContentLink`, read through a
  `base_filter`, and `migrate? false`: it owns no column, index or migration,
  and every row it reads or writes is an ordinary `ContentLink` row. It
  exists for one reason. Within those rows `(source_id, target_id)` is
  unique (the table's `unique_field_link` index is `(org_id, source_id,
  target_id, kind, field)` with NULLs not distinct), and Ash loads a
  many-to-many with a sort that reaches its source — `parent()`, which takes a
  lateral join — only through a join resource unique on those two keys. With
  `ContentLink` as the join it was not, because reference edges share the
  table, so `related_<type>s` came back in no particular order. Through this
  resource it is sorted by each link's `position`
  (`KilnCMS.CMS.RelatedOrder`).

  The base filter also keeps out what is not curated related content, which a
  preparation on the `ContentLink` join used to do (#1594): reference edges,
  and payload links (R8) of any other kind. A managed unrelate can only find
  a curated row, so removing a related record never deletes a reference edge
  to the same target.

  ## Writes

  `manage_relationship` refuses a relationship whose filter uses `parent()`
  and applies its sort to the lookup of the records it relates, where there
  is no parent to bind. So `related_<type>s` is read-only, and the
  `related_<type>_ids` arguments manage an unsorted private twin over this
  same join, `curated_<type>s` (`write_relationship/1`). Both see the same
  rows.

  Policies are `ContentLink`'s for people, unchanged: a join row is part of
  editing (writes need an editor, and never a read-only API key), and a row
  is read through the related join (`Checks.ThroughRelatedJoin`), by an
  editor, or when both of its ends are readable.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_links"
    repo KilnCMS.Repo
    # `ContentLink` owns the table, its indexes and its migrations.
    migrate? false
    # Asked for by an identity under a base filter. Never turned into an
    # index: nothing is generated for this resource.
    base_filter_sql "kind = 'related' AND field IS NULL"
  end

  resource do
    base_filter expr(kind == :related and is_nil(field))
  end

  actions do
    defaults [:read, :destroy]

    # What `manage_relationship` writes: the two ends. `kind` defaults to
    # `:related` and `field` stays NULL, so the row is inside the base
    # filter; its `position` is set after the write
    # (`Changes.OrderRelatedLinks`).
    create :create do
      primary? true
      accept [:source_id, :target_id]
    end
  end

  policies do
    policy action_type([:create, :destroy]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    policy action_type(:read) do
      access_type :runtime
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if KilnCMS.CMS.Checks.ThroughRelatedJoin
      authorize_if KilnCMS.CMS.Checks.LinkEndsReadable
    end

    policy action_type([:create, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end
  end

  # As `ContentLink`'s: the tenant comes from the content changeset.
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

    attribute :source_id, :uuid, allow_nil?: false, public?: true
    attribute :target_id, :uuid, allow_nil?: false, public?: true

    # Fixed by the base filter; declared so a create writes them.
    attribute :kind, :atom, allow_nil?: false, default: :related, writable?: false
    attribute :field, :string, writable?: false
    attribute :metadata, :map, allow_nil?: false, default: %{}, writable?: false

    attribute :position, :integer, allow_nil?: false, default: 0, public?: true
  end

  identities do
    # True of every row the base filter admits — see the moduledoc.
    identity :unique_related_link, [:source_id, :target_id]
  end

  @doc """
  The relationship the `related_<type>_ids` arguments write through for a
  `related_<type>s` relationship: its unsorted twin `curated_<type>s` (see
  "Writes"). Any other relationship writes through itself.
  """
  @spec write_relationship(atom()) :: atom()
  def write_relationship(relationship) do
    case Atom.to_string(relationship) do
      # The twin is declared by the same macro as the relationship, so the
      # atom exists.
      "related_" <> rest -> String.to_existing_atom("curated_" <> rest)
      _other -> relationship
    end
  end
end
