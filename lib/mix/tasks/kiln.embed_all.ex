defmodule Mix.Tasks.Kiln.EmbedAll do
  @shortdoc "Enqueue embedding jobs for all existing content (semantic search backfill)"
  @moduledoc """
  Enqueues a `KilnCMS.Search.EmbeddingWorker` for every existing Page and Post so
  their semantic embeddings are (re)computed in the background. Run once after
  enabling semantic search, or after changing the embedding model.

      mix kiln.embed_all

  No-op (with a notice) when semantic search is disabled.
  """
  use Mix.Task

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Search.EmbeddingWorker

  @requirements ["app.start"]

  @sources [
    {KilnCMS.CMS.Page, &CMS.list_pages!/1},
    {KilnCMS.CMS.Post, &CMS.list_posts!/1}
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
    records = lister.(authorize?: false)

    Enum.each(records, fn %{id: id} ->
      %{"resource" => to_string(resource), "id" => id}
      |> EmbeddingWorker.new()
      |> Oban.insert!()
    end)

    acc + length(records)
  end
end
