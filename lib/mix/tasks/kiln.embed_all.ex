defmodule Mix.Tasks.Kiln.EmbedAll do
  @shortdoc "Enqueue embedding jobs for all existing content (semantic search backfill)"
  @moduledoc """
  Enqueues a `KilnCMS.Search.EmbeddingWorker` for every existing Page, Post,
  and dynamic Entry so their semantic embeddings are (re)computed in the
  background. Run once after enabling semantic search, or after changing the
  embedding model (e.g. switching to a multilingual model — see
  `docs/semantic-search-plan.md`).

      mix kiln.embed_all

  No-op (with a notice) when semantic search is disabled.
  """
  use Mix.Task

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Search.EmbeddingWorker

  @requirements ["app.start"]

  # Every embeddable content tier: the compiled Page/Post plus the shared
  # dynamic entry tier (D17), so a re-embed after a model change covers
  # admin-defined types too.
  @sources [
    {KilnCMS.CMS.Page, &CMS.list_pages!/1},
    {KilnCMS.CMS.Post, &CMS.list_posts!/1},
    {KilnCMS.CMS.Entry, &CMS.list_entries!/1}
  ]

  @impl Mix.Task
  def run(_args) do
    if Search.semantic?() do
      count = Enum.reduce(@sources, 0, &enqueue_source/2)
      Mix.shell().info("Enqueued embedding jobs for #{count} content record(s).")
    else
      Mix.shell().info(
        "Semantic search is disabled (config :kiln_cms, KilnCMS.Search, semantic: false). " <>
          "Enable it first; nothing enqueued."
      )
    end
  end

  defp enqueue_source({resource, lister}, acc) do
    # Only ids are needed — don't drag blocks/search_text/embedding along.
    records = lister.(authorize?: false, query: [select: [:id]])

    records
    |> Enum.map(fn %{id: id} ->
      EmbeddingWorker.new(%{"resource" => to_string(resource), "id" => id})
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(&Oban.insert_all/1)

    acc + length(records)
  end
end
