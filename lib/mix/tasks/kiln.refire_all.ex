defmodule Mix.Tasks.Kiln.RefireAll do
  @shortdoc "Re-fire every published document's artifacts (re-fire sweep)"
  @moduledoc """
  Enqueues a `KilnCMS.Firing.FireWorker` for every published Page, Post, and
  dynamic Entry, refreshing their fired artifacts on all surfaces. Run after a
  deploy that changes what firing produces — e.g. the `:llm` surface or the
  expanded schema.org `:json_ld` composition (#357, GEO) — so content
  published before the deploy picks the changes up.

      mix kiln.refire_all

  On a prod release, call the same sweep against the running node instead:

      /app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"

  Jobs run through the normal `:firing` Oban queue (bounded concurrency,
  retries); editorial state, versions, and timestamps are untouched.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    counts = KilnCMS.Firing.Sweep.run()
    total = counts |> Map.values() |> Enum.sum()

    Mix.shell().info(
      "Enqueued re-fire jobs for #{total} published document(s): #{inspect(counts)}"
    )
  end
end
