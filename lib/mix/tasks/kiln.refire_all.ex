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

  By default nothing is announced. `--notify` sends each re-fired document to
  the webhook endpoints and the change feed as `<type>.updated` with
  `"reason": "refire"` (#2463), for headless consumers that cache on webhooks
  rather than revalidate. It does not purge the CDN; purge once the sweep has
  drained (`KilnCMS.Firing.Sweep.pending/0` is `0`):

      mix kiln.refire_all --notify
      /app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run(notify: true)"
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [notify: :boolean])
    counts = KilnCMS.Firing.Sweep.run(notify: Keyword.get(opts, :notify, false))
    total = counts |> Map.values() |> Enum.sum()

    Mix.shell().info(
      "Enqueued re-fire jobs for #{total} published document(s): #{inspect(counts)}"
    )
  end
end
