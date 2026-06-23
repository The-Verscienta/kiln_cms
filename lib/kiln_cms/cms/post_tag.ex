defmodule KilnCMS.CMS.PostTag do
  @moduledoc """
  Join resource backing the `Post` ⇄ `Tag` many-to-many. Managed implicitly
  through `manage_relationship` on the parent `Post`; not exposed via the public
  APIs (traversed through the parent's `tags`/`posts` relationships).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "post_tags"
    repo KilnCMS.Repo

    references do
      # Drop the link rows when either side is hard-deleted.
      reference :post, on_delete: :delete
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

    # Readable by anyone so published content can load its tags for public /
    # headless delivery.
    policy action_type(:read) do
      authorize_if always()
    end

    # Link/unlink is an editing action — editors only (admins via the bypass).
    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :editor)
    end
  end

  relationships do
    belongs_to :post, KilnCMS.CMS.Post do
      primary_key? true
      allow_nil? false
    end

    belongs_to :tag, KilnCMS.CMS.Tag do
      primary_key? true
      allow_nil? false
    end
  end
end
