defmodule KilnCMS.CMS.RelatedLink do
  @moduledoc """
  SPIKE (#2025 follow-up): the curated related-content rows of
  `content_links` (`kind: :related`, no `field`) as a join resource of their
  own, so `related_<type>s` can be ordered by `position` in SQL.

  Same table as `KilnCMS.CMS.ContentLink`, `migrate? false`, narrowed by a
  `base_filter`. Within it `(source_id, target_id)` is unique — the table's
  `unique_field_link` index is `(org_id, source_id, target_id, kind, field)`
  with NULLs not distinct — which is what Ash needs before it will load a
  many-to-many with a `parent()` sort (a lateral join).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_links"
    repo KilnCMS.Repo
    migrate? false
    # Codegen asks for it with an identity under a base filter; `migrate?
    # false` means no index is ever generated from it.
    base_filter_sql "kind = 'related' AND field IS NULL"
  end

  resource do
    base_filter expr(kind == :related and is_nil(field))
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:source_id, :target_id, :position]
    end
  end

  policies do
    policy action_type([:create, :update, :destroy]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    policy action_type(:read) do
      access_type :runtime
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :cms_bookkeeping}
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if KilnCMS.CMS.Checks.ThroughRelatedJoin
      authorize_if KilnCMS.CMS.Checks.LinkEndsReadable
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
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

    attribute :source_id, :uuid, allow_nil?: false, public?: true
    attribute :target_id, :uuid, allow_nil?: false, public?: true
    attribute :kind, :atom, allow_nil?: false, default: :related, writable?: false, public?: true
    attribute :field, :string, writable?: false, public?: false
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, writable?: false, public?: false
  end

  identities do
    identity :unique_related_link, [:source_id, :target_id]
  end
end
