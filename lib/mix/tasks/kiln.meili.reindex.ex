defmodule Mix.Tasks.Kiln.Meili.Reindex do
  @shortdoc "Configure the Meilisearch index and (re)index all published content"
  @moduledoc """
  Applies the index settings (searchable/filterable/sortable attributes) and
  enqueues a `KilnCMS.Search.MeilisearchWorker` upsert for every published Page
  and Post, so the optional Meilisearch index is fully (re)built in the
  background. Run once after enabling the backend, or after changing what gets
  indexed.

      mix kiln.meili.reindex

  In a production release (no Mix) run the same thing over rpc:

      bin/kiln_cms rpc 'KilnCMS.Search.Meilisearch.reindex_all()'

  Also the **removal** path, which is why it is worth running after an upgrade
  that narrows what belongs in the index: the worker turns a document it will
  not index into a `DELETE`, so a run enqueued over every published document
  evicts the ones that should no longer be there. Audience-gated and
  passphrase-locked documents indexed under an older rule are cleaned up this
  way (#1006, #496).

  No-op (with a notice) when the Meilisearch backend is disabled.
  """
  use Mix.Task

  alias KilnCMS.Search.Meilisearch

  @requirements ["app.start"]

  # The work is `KilnCMS.Search.Meilisearch.reindex_all/0`, so a production
  # release (no Mix) can run the same thing over `bin/kiln_cms rpc`; this task
  # is the checkout-side front door and only reports.
  @impl Mix.Task
  def run(_args) do
    case Meilisearch.reindex_all() do
      {:error, reason} ->
        Mix.shell().error("Could not configure Meilisearch index: #{inspect(reason)}")

      {:ok, count} ->
        Mix.shell().info("Configured index and enqueued #{count} published document(s).")

        Mix.shell().info(
          "Anything not public to an anonymous visitor — audience-gated or " <>
            "passphrase-locked — is REMOVED from the index as those jobs run."
        )

      :disabled ->
        Mix.shell().info(
          "Meilisearch is disabled (config :kiln_cms, KilnCMS.Search.Meilisearch, enabled: false). " <>
            "Enable it first; nothing enqueued."
        )
    end
  end
end
