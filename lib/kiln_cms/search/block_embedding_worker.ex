defmodule KilnCMS.Search.BlockEmbeddingWorker do
  @moduledoc """
  Re-indexes a document's block embeddings off the write path (Kiln v2 — D16).
  Enqueued on fire when semantic search is enabled. No-op otherwise / if the
  document is gone.
  """
  # Dedupe a fan-out of fire/refire jobs for the same document while pending.
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:type, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.{CMS, Search}
  alias KilnCMS.Search.BlockIndexer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => type, "id" => id}}) do
    if Search.semantic?() do
      type |> load(id) |> reindex()
    else
      :ok
    end
  end

  defp load("page", id), do: CMS.get_page(id, authorize?: false)
  defp load("post", id), do: CMS.get_post(id, authorize?: false)
  defp load(_type, _id), do: :error

  defp reindex({:ok, document}) do
    {:ok, _count} = BlockIndexer.reindex(document)
    :ok
  end

  defp reindex(_), do: :ok
end
