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

  Runs after `ContentLinkReferenceEdges1`, which builds the unique index its
  `ON CONFLICT DO NOTHING` relies on. `down/0` deletes the reference edges,
  so the schema rollback after it can restore the 1.0 unique index
  `(source, target, kind)` — which two reference fields naming the same
  target would violate.
  """
  use Ecto.Migration

  def up do
    KilnCMS.CMS.ContentLinks.Backfill.run(repo())
  end

  def down do
    execute "DELETE FROM content_links WHERE kind = 'reference'"
  end
end
