defmodule KilnCMS.Repo.Migrations.BackfillBlockIds do
  @moduledoc """
  Assigns a stable id to every stored block that predates block ids.

  Blocks carry a writable uuid primary key so identity survives reorders,
  version restores, and — with the collab CRDT prototype — keys each block's
  Yjs fragment. Rows written through Ash already have ids (generated at write
  time); this backfills the long tail so collaborative sessions get stable
  fragment keys everywhere, instead of the positional fallback.

  Handles both stored shapes per element: the legacy block map
  (`{"type": ..., "content": ...}` — id at the top level) and the typed union
  envelope (`{"type": ..., "value": {...}}` — id inside `value`). Idempotent:
  elements that already carry an id are left untouched. Top-level elements
  only — legacy nested `children` aren't part of the typed model.

  `down` is a no-op: ids are additive and harmless to older code.
  """
  use Ecto.Migration

  @tables ~w(pages posts entries)

  def up do
    for table <- @tables do
      execute("""
      UPDATE #{table}
      SET blocks = (
        SELECT array_agg(
          CASE
            -- Typed union envelope: id lives inside "value".
            WHEN elem ? 'value' AND elem ? 'type' THEN
              CASE
                WHEN elem -> 'value' ? 'id' THEN elem
                ELSE jsonb_set(elem, '{value,id}', to_jsonb(gen_random_uuid()::text))
              END
            -- Legacy block map: id lives at the top level.
            WHEN elem ? 'id' THEN elem
            ELSE elem || jsonb_build_object('id', gen_random_uuid()::text)
          END
          ORDER BY ord
        )
        FROM unnest(blocks) WITH ORDINALITY AS t(elem, ord)
      )
      WHERE blocks IS NOT NULL
        AND array_length(blocks, 1) > 0
        AND EXISTS (
          SELECT 1 FROM unnest(blocks) AS e
          WHERE NOT (
            CASE
              WHEN e ? 'value' AND e ? 'type' THEN e -> 'value' ? 'id'
              ELSE e ? 'id'
            END
          )
        )
      """)
    end
  end

  def down, do: :ok
end
