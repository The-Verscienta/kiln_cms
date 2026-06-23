defmodule KilnCMS.CMS.PageTag do
  @moduledoc """
  Join resource backing the `Page` ⇄ `Tag` many-to-many. Managed implicitly
  through `manage_relationship` on the parent `Page`; not exposed via the public
  APIs (traversed through the parent's `tags`/`pages` relationships).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "page_tags"
    repo KilnCMS.Repo

    references do
      reference :page, on_delete: :delete
      reference :tag, on_delete: :delete
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
    belongs_to :page, KilnCMS.CMS.Page do
      primary_key? true
      allow_nil? false
    end

    belongs_to :tag, KilnCMS.CMS.Tag do
      primary_key? true
      allow_nil? false
    end
  end
end
