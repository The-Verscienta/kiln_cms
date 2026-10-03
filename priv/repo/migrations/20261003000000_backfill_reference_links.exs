defmodule KilnCMS.Repo.Migrations.BackfillReferenceLinks do
  @moduledoc """
  Data migration (#1594): writes a `content_links` edge for every
  `:reference` custom field value stored before 1.1. See
  `KilnCMS.CMS.ContentLinks.Backfill`, which `mix kiln.links.backfill` also
  runs.

  Hand-written *data* migration — Ash owns the schema, but a backfill can't be
  generated. Expand-safe: it only inserts rows (and deletes reference edges no
  stored value implies, of which a 1.0 database has none); a release before
  1.1 never writes a `kind = 'reference'` edge and reads one as an ordinary
  link (`:reference` is an atom it already has). Plain SQL
  naming only long-standing columns, so it still runs when an install upgrades
  past later releases in one step. Idempotent.

  Ordering keeps `content_links` guarded by a unique index at every moment:
  `ContentLinkReferenceEdges1` builds the new `(…, kind, field)` index
  `CONCURRENTLY` while the 1.0 `(source, target, kind)` index still stands,
  `DropContentLinkUniqueLinkIndex` drops the old one, and only then does this
  run. It has to come after the drop, not between: two reference fields
  naming the same target are two legitimate rows the old index would refuse.
  `down/0` deletes the reference edges, so rolling back the drop can recreate
  the 1.0 index.
  """
  use Ecto.Migration

  def up do
    KilnCMS.CMS.ContentLinks.Backfill.run(repo())
  end

  def down do
    execute "DELETE FROM content_links WHERE kind = 'reference'"
  end
end
