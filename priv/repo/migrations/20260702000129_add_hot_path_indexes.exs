defmodule KilnCMS.Repo.Migrations.AddHotPathIndexes do
  @moduledoc """
  Indexes for query paths that previously seq-scanned (July 2026 performance
  audit): the every-minute scheduled-publish scan, the published feeds, the
  re-fire reference walk, and several reverse-lookup foreign keys Postgres
  doesn't index automatically.
  """
  use Ecto.Migration

  # The core content-type tables built on KilnCMS.CMS.Content. Downstream
  # project tables get the same indexes from their own overlay migration — the
  # core migration must not name them, or a core-only build fails on a table it
  # never creates.
  @content_tables ~w(pages posts)a

  def change do
    for table <- @content_tables do
      # The AshOban :publish_scheduled scheduler scans for due content every
      # minute; only rows that can still transition are indexed.
      create index(table, [:scheduled_at],
               name: "#{table}_scheduled_publish_index",
               where: "scheduled_at IS NOT NULL AND state IN ('draft', 'in_review')"
             )

      # The :published read (blog index, JSON:API/GraphQL feeds) filters on
      # state and sorts published_at DESC.
      create index(table, ["published_at DESC"],
               name: "#{table}_published_feed_index",
               where: "state = 'published'"
             )

      # Search facet filters and reverse relationships (MediaItem's
      # featured_pages/featured_posts, Category contents).
      create index(table, [:category_id], name: "#{table}_category_id_index")
      create index(table, [:author_id], name: "#{table}_author_id_index")
      create index(table, [:featured_image_id], name: "#{table}_featured_image_id_index")
    end

    # Firing's invalidation wave looks edges up by target
    # (`Firing.edges_to/3`); the unique index leads with from_*.
    create index(:reference_edges, [:to_type, :to_id])

    # "What links to me" — has_many :incoming_links joins on target_id.
    create index(:content_links, [:target_id])

    # Tag.page_count/post_count aggregates join taggings on tag_id (loaded on
    # every TaxonomyLive mount); the unique index leads with subject_id.
    create index(:taggings, [:tag_id])

    # Analytics dashboard's :top read sorts by views.
    create index(:content_views, ["views DESC"], name: "content_views_views_index")
  end
end
