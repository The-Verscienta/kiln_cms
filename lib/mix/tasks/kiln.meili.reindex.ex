defmodule Mix.Tasks.Kiln.Meili.Reindex do
  @shortdoc "Configure the Meilisearch index and (re)index all published content"
  @moduledoc """
  Applies the index settings (searchable/filterable/sortable attributes) and
  enqueues a `KilnCMS.Search.MeilisearchWorker` upsert for every published Page
  and Post, so the optional Meilisearch index is fully (re)built in the
  background. Run once after enabling the backend, or after changing what gets
  indexed.

      mix kiln.meili.reindex

  Also the **removal** path, which is why it is worth running after an upgrade
  that narrows what belongs in the index: the worker turns a document it will
  not index into a `DELETE`, so a run enqueued over every published document
  evicts the ones that should no longer be there. Audience-gated and
  passphrase-locked documents indexed under an older rule are cleaned up this
  way (#1006, #496).

  No-op (with a notice) when the Meilisearch backend is disabled.
  """
  use Mix.Task

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Search.Meilisearch
  alias KilnCMS.Search.MeilisearchWorker

  @requirements ["app.start"]

  # Page, Post and every dynamic-type entry (D17). Entries are one source, not
  # one per type: they all live in the `:entry` tier and fire under the `entry`
  # storage key, which is the key `MeilisearchWorker.load/3` dispatches on
  # (#1012).
  @sources [
    {KilnCMS.CMS.Page, &CMS.list_pages!/1},
    {KilnCMS.CMS.Post, &CMS.list_posts!/1},
    {KilnCMS.CMS.Entry, &CMS.list_entries!/1}
  ]

  @impl Mix.Task
  def run(_args) do
    if Meilisearch.enabled?() do
      case Meilisearch.configure() do
        {:error, reason} ->
          Mix.shell().error("Could not configure Meilisearch index: #{inspect(reason)}")

        _ ->
          count = Enum.reduce(@sources, 0, &enqueue_source/2)
          Mix.shell().info("Configured index and enqueued #{count} published document(s).")

          Mix.shell().info(
            "Anything not public to an anonymous visitor — audience-gated or " <>
              "passphrase-locked — is REMOVED from the index as those jobs run."
          )
      end
    else
      Mix.shell().info(
        "Meilisearch is disabled (config :kiln_cms, KilnCMS.Search.Meilisearch, enabled: false). " <>
          "Enable it first; nothing enqueued."
      )
    end
  end

  defp enqueue_source({_resource, lister}, acc) do
    # Strict tenancy (#419): list published docs per org (reads need a tenant).
    published =
      Enum.flat_map(KilnCMS.Accounts.list_org_ids(), fn org_id ->
        lister.(
          authorize?: false,
          tenant: org_id,
          query: [filter: [state: :published], select: [:id, :state, :org_id]]
        )
      end)

    published
    |> Enum.map(fn record ->
      type = Engine.document_type(record)

      MeilisearchWorker.new(%{
        "org_id" => record.org_id,
        "op" => "upsert",
        "type" => to_string(type),
        "id" => record.id
      })
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(&Oban.insert_all/1)

    acc + length(published)
  end
end
