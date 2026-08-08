defmodule Mix.Tasks.Kiln.Occurrences.Backfill do
  @shortdoc "Fill in next_occurrence_at for content that predates the what's-on index"
  @moduledoc """
  Computes `next_occurrence_at` for existing content, once (#766).

      mix kiln.occurrences.backfill

  The migration that added the column could not fill it — the value comes out of
  `KilnCMS.Events.Occurrences`, not out of other columns — and the hourly sweep
  will not fill it either: the sweep visits rows whose occurrence has **passed**,
  and a `NULL` has not passed anything. So on a site that had events before
  upgrading, `/<plural>` and `/<plural>/index.json` stay empty until every event
  happens to be re-saved. **Run this once after upgrading.**

  Idempotent and interruptible: it writes only the rows whose value actually
  changes, so a second run over a finished site writes nothing.

  ## Options

      --org <uuid>    just this organization (default: every one)
      --batch <n>     rows per page (default 500)
      --all-types     visit every content type, not only event-shaped ones

  `--all-types` matters in one case: a type that lost its `datetime_range` field
  while holding future-dated values. Those rows are invisible to the sweep
  (their value has not passed) and to the default pass (their type is no longer
  event-shaped), so nothing else will correct them. It costs a full scan of
  every content table, which is why it is not the default.

  ## In a release

  There is no Mix in a release image, so call the module:

      bin/kiln_cms eval 'KilnCMS.Events.Backfill.run()'
  """
  use Mix.Task

  alias KilnCMS.Events.Backfill

  @requirements ["app.start"]

  @switches [org: :string, batch: :integer, all_types: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    shell = Mix.shell()

    run_opts =
      [on_type: &report(shell, &1, &2)]
      |> put_if(opts[:batch], :batch)
      |> put_if(opts[:all_types], :all_types)

    result =
      case opts[:org] do
        nil -> Backfill.run(run_opts)
        org_id -> Backfill.run_org(org_id, run_opts)
      end

    shell.info(
      "Backfill complete: #{result.written} record(s) updated, " <>
        "#{result.scanned} scanned."
    )
  end

  defp put_if(opts, nil, _key), do: opts
  defp put_if(opts, value, key), do: Keyword.put(opts, key, value)

  # Only the types that actually produced a write, so a site with twenty content
  # types and one event type prints one line rather than twenty.
  defp report(_shell, _descriptor, %{written: 0}), do: :ok

  defp report(shell, descriptor, result) do
    shell.info("  #{descriptor.type}: #{result.written}/#{result.scanned} updated")
  end
end
