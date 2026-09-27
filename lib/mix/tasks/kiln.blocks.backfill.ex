defmodule Mix.Tasks.Kiln.Blocks.Backfill do
  @shortdoc "Rewrite block trees still stored in the legacy shape to the typed shape"

  @moduledoc """
  Rewrites every stored block tree still held in a pre-typed shape — on every
  content type, pages, posts, dynamic entries and overlay types alike, in both
  `blocks` and the working copy's `working_blocks` — to the typed shape at rest
  (#1537). See `KilnCMS.CMS.BlockBackfill` for exactly what counts as legacy.

      mix kiln.blocks.backfill [--dry-run] [--batch N] [--table NAME ...]

  **Run it once after upgrading to 0.12, against the running site.** It does
  not need a maintenance window: it writes each row with a compare-and-swap,
  touches no `updated_at`, version history or cache, and leaves alone a row
  an editor saves while it runs (that save already wrote the typed shape).

  Idempotent and resumable: a row already in the typed shape is only read, so
  an interrupted run is finished by running it again, and a second run over a
  finished database writes nothing.

  It **rewrites data**. Rolling the release pin back afterwards does not undo
  it — the older release reads the typed shape fine, since it is what every
  save has written since the storage flip, but the legacy maps are gone. Take
  the backup you would take before any data migration.

  A row it cannot convert without losing something is **reported and not
  written**, and the task then exits non-zero; so does a rich-text block whose
  `legacy_html` could not be carried over to Portable Text faithfully (that
  block keeps it). Both are listed by table, row id and block path. Fix them in
  the editor — or leave them: they keep reading exactly as they do today.

  In a release (no Mix): `bin/kiln_cms eval 'KilnCMS.Release.backfill_blocks()'`,
  with the same options as a keyword list (`dry_run: true`, `batch: 100`,
  `tables: ["pages"]`).

  ## Options

    * `--dry-run` — report what would change; write nothing.
    * `--batch N` — rows per page (default 200).
    * `--table NAME` — only this table; repeatable.
  """
  use Mix.Task

  alias KilnCMS.CMS.BlockBackfill

  @requirements ["app.start"]

  @switches [dry_run: :boolean, batch: :integer, table: :keep]

  @impl Mix.Task
  def run(argv) do
    {opts, _positional} = OptionParser.parse!(argv, strict: @switches)

    run_opts =
      opts
      |> Keyword.take([:dry_run, :batch])
      |> then(fn run_opts ->
        case Keyword.get_values(opts, :table) do
          [] -> run_opts
          tables -> Keyword.put(run_opts, :tables, tables)
        end
      end)

    case BlockBackfill.run_and_report(run_opts, fn line -> Mix.shell().info(line) end) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
