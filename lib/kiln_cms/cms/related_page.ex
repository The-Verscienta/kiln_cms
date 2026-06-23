defmodule KilnCMS.CMS.RelatedPage do
  @moduledoc """
  Self-referential join resource backing the `Page` ⇄ `Page` "related pages"
  many-to-many. `source` is the page the relation is configured on; `related`
  is the page it links to. Directional; managed through `manage_relationship`
  on the parent `Page`.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "related_pages"
    repo KilnCMS.Repo

    references do
      reference :source, on_delete: :delete
      reference :related, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :create, :update, :destroy]
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :editor)
    end
  end

  relationships do
    belongs_to :source, KilnCMS.CMS.Page do
      primary_key? true
      allow_nil? false
    end

    belongs_to :related, KilnCMS.CMS.Page do
      primary_key? true
      allow_nil? false
    end
  end
end
