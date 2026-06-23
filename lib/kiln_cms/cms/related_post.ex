defmodule KilnCMS.CMS.RelatedPost do
  @moduledoc """
  Self-referential join resource backing the `Post` ⇄ `Post` "related posts"
  many-to-many. `source` is the post the relation is configured on; `related`
  is the post it links to. Directional (A→B does not imply B→A); managed through
  `manage_relationship` on the parent `Post`.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "related_posts"
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
    belongs_to :source, KilnCMS.CMS.Post do
      primary_key? true
      allow_nil? false
    end

    belongs_to :related, KilnCMS.CMS.Post do
      primary_key? true
      allow_nil? false
    end
  end
end
