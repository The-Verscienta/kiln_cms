defmodule KilnCMS.CMS.Category do
  @moduledoc """
  A content category — taxonomy with a **one-to-many** relationship to content:
  a `Page`/`Post` `belongs_to` one category, and a category `has_many` pages and
  posts (the inverse). Categories are mutually exclusive per item (unlike the
  many-to-many `Tag`).

  Taxonomy is lightweight: no version history / workflow / soft-delete — just a
  plain editor-managed, world-readable lookup resource. Everything a category
  shares with `Tag` and `TagGroup` (the API surface, the RBAC policy stack,
  multitenancy, the slug identity and its index) comes from
  `KilnCMS.CMS.Taxonomy`; what follows is what is a category's alone.
  """
  use KilnCMS.CMS.Taxonomy,
    type: :category,
    plural: "categories",
    admin_columns: [:name, :slug, :description, :inserted_at]

  relationships do
    # One-to-many inverse of the `belongs_to :category` on each content type.
    has_many :pages, KilnCMS.CMS.Page do
      public? true
    end

    has_many :posts, KilnCMS.CMS.Post do
      public? true
    end
  end

  aggregates do
    # Usage counts for the taxonomy management UI (and public APIs).
    count :page_count, :pages do
      public? true
    end

    count :post_count, :posts do
      public? true
    end
  end
end
