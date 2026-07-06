defmodule KilnCMS.Repo.Migrations.AddScheduledUnpublishIndexes do
  @moduledoc """
  Partial index backing the every-minute AshOban `unpublish_scheduled`
  scheduler — the same treatment the July 2026 performance audit gave the
  `publish_scheduled` scan. Only rows that can still transition are indexed,
  so the index stays tiny (embargoed published content).
  """
  use Ecto.Migration

  # The core content-type tables built on KilnCMS.CMS.Content. Downstream
  # project tables get the matching unpublish index from their own overlay
  # migration — the core migration must not name them, or a core-only build
  # fails on a table it never creates.
  @content_tables ~w(pages posts entries)a

  def change do
    for table <- @content_tables do
      create index(table, [:unpublish_at],
               name: "#{table}_scheduled_unpublish_index",
               where: "unpublish_at IS NOT NULL AND state = 'published'"
             )
    end

    # The entries table postdates the hot-path-index migration, so it never
    # got the publish-scan / published-feed indexes every other content table
    # has — the same minute cron scans it. Repaired here.
    create index(:entries, [:scheduled_at],
             name: "entries_scheduled_publish_index",
             where: "scheduled_at IS NOT NULL AND state IN ('draft', 'in_review')"
           )

    create index(:entries, ["published_at DESC"],
             name: "entries_published_feed_index",
             where: "state = 'published'"
           )
  end
end
