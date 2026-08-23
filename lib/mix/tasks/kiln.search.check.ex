defmodule Mix.Tasks.Kiln.Search.Check do
  @moduledoc """
  Fails when a content type's table is missing its `search_vector` column,
  trigger, or GIN index.

  Every `KilnCMS.CMS.Content` resource gets a `:search` action that filters on
  a **trigger-maintained `search_vector` column**. The column is deliberately
  not an Ash attribute — the database keeps it correct however a row is
  written — so `mix ash.codegen` cannot generate it, and a content type added
  after the core migrations needs its own one-liner
  (`KilnCMS.Migrations.add_search_vector/1`).

  Nothing catches that omission: the resource compiles, the codegen migration
  applies, the editor works, the type publishes. The first sign is a query, and
  the failure is not confined to the new type — a global search sweeps every
  registered content type, so one missing column used to 500 the search page,
  the editor palette and the search API for every query on the site (#295).

  This is the gate for it, and it wants a **migrated database** rather than
  source:

  ```bash
  mix kiln.search.check
  ```

  It prints the missing pieces per table and the migration that closes each
  gap. The helper it names is idempotent, so pasting it is safe on a table
  that is only missing (say) its index.
  """
  @shortdoc "Fails on a content table with no search_vector column/trigger/index"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    case KilnCMS.Search.SchemaCheck.report() do
      [] ->
        Mix.shell().info(
          "Search: every content table carries its search_vector column, trigger and index."
        )

      gaps ->
        shell = Mix.shell()

        Enum.each(gaps, fn gap ->
          shell.error(
            "#{gap.table} (#{inspect(gap.resource)}) is missing: " <>
              Enum.map_join(gap.missing, ", ", &to_string/1)
          )

          shell.info("\n" <> KilnCMS.Search.SchemaCheck.migration(gap))
        end)

        Mix.raise("""
        #{length(gaps)} content table(s) cannot answer a keyword search.

        `search_vector` is maintained by a database trigger, not by Ash, so
        `mix ash.codegen` does not create it — each content type's table needs
        the migration printed above, ordered AFTER the codegen migration that
        creates the table. A table reported as missing only `table` has no
        migration at all yet: run `mix ash.migrate` first.

        See `KilnCMS.Migrations.add_search_vector/1` and #295.
        """)
    end
  end
end
