defmodule Mix.Tasks.Kiln.Cache.Flush do
  @shortdoc "Drop every delivery cache (published content + fired artifacts)"
  @moduledoc """
  Clears both in-BEAM delivery caches — `KilnCMS.Cache` (published records) and
  `KilnCMS.Firing.Cache` (fired artifact bodies) — for the node it runs on (#483).

      mix kiln.cache.flush

  ## Not for production

  **Use the release RPC on a deployed instance, not this task:**

      /app/bin/kiln_cms rpc "KilnCMS.Cache.flush_delivery()"

  Two reasons, and the second is the one that bites. The caches live in the
  serving node's memory, so a separately started `mix` task clears its own empty
  ones and reports zero. And `@requirements ["app.start"]` boots a *full second
  application node* against the same database — every Oban queue comes up and
  starts draining production `:mail`, `:billing` and `:webhooks` jobs, then the
  task exits mid-job and leaves them to retry.

  The prod image ships a release and has no `mix` at all, so this is reachable
  only from a checkout pointed at a production database — which is exactly the
  shape that does the damage. It is here for local and CI use.

  ## When you need it

  Invalidation is automatic and precise on writes (`CMS.Changes.BustContentCache`),
  so this is not part of publishing. It is for the states precise invalidation
  cannot see: a config change, a template deploy, or an external data source
  feeding a custom block. Before #483 the only way to reach it was an IEx shell
  on production.

  ## Cost

  Every subsequent request re-reads the database until the caches warm again, so
  on a busy site this is a deliberate load spike, not a free button. Prefer the
  precise busters (`KilnCMS.Cache.bust/3`, `bust_sitemap/1`, `bust_llms/1`) when
  the affected record is known.

  **Per node.** These are in-process caches with no shared tier, so on a
  multi-node deployment this clears one node and leaves the others. Run it on
  each, or restart them.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    %{published: published, artifacts: artifacts} = KilnCMS.Cache.flush_delivery()

    Mix.shell().info(
      "Flushed the delivery cache on this node: " <>
        "#{published} published entr#{plural(published)}, " <>
        "#{artifacts} fired artifact#{if artifacts == 1, do: "", else: "s"}."
    )
  end

  defp plural(1), do: "y"
  defp plural(_), do: "ies"
end
