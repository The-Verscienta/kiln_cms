defmodule Mix.Tasks.Kiln.Meili.Reindex do
  @shortdoc "Configure the Meilisearch index and (re)index all published content"
  @moduledoc """
  Applies the index settings (searchable/filterable/sortable attributes) and
  enqueues a `KilnCMS.Search.MeilisearchWorker` upsert for every published Page
  and Post, so the optional Meilisearch index is fully (re)built in the
  background. Run once after enabling the backend, or after changing what gets
  indexed.

      mix kiln.meili.reindex

  No-op (with a notice) when the Meilisearch backend is disabled.
  """
  use Mix.Task

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Search.Meilisearch
  alias KilnCMS.Search.MeilisearchWorker

  @requirements ["app.start"]

  @sources [
    {KilnCMS.CMS.Page, &CMS.list_pages!/1},
    {KilnCMS.CMS.Post, &CMS.list_posts!/1}
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
      end
    else
      Mix.shell().info(
        "Meilisearch is disabled (config :kiln_cms, KilnCMS.Search.Meilisearch, enabled: false). " <>
          "Enable it first; nothing enqueued."
      )
    end
  end

  defp enqueue_source({_resource, lister}, acc) do
    # Filter in the DB and select only what the job args need.
    published =
      lister.(authorize?: false, query: [filter: [state: :published], select: [:id, :state]])

    published
    |> Enum.map(fn record ->
      type = Engine.document_type(record)
      MeilisearchWorker.new(%{"op" => "upsert", "type" => to_string(type), "id" => record.id})
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(&Oban.insert_all/1)

    acc + length(published)
  end
end
