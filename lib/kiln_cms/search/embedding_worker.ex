defmodule KilnCMS.Search.EmbeddingWorker do
  @moduledoc """
  Computes and stores a content record's semantic embedding off the write path,
  mirroring `KilnCMS.Media.VariantWorker`: load the record, embed its
  denormalized `search_text`, and persist `embedding` + `embedded_at` via the
  resource's `:set_embedding` action.

  A no-op when semantic search is disabled, the record is gone, or it has no
  text to embed yet. Enqueued by `KilnCMS.CMS.Changes.EnqueueEmbedding` after
  create/update, and by `mix kiln.embed_all` for backfill.
  """
  # Coalesce rapid autosaves: while a job for this record is still pending, a new
  # enqueue is deduped instead of stacking one embedding job per keystroke-save.
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:resource, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.Search

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"resource" => resource, "id" => id}}) do
    if Search.semantic?() do
      resource |> String.to_existing_atom() |> embed(id)
    else
      :ok
    end
  end

  defp embed(resource, id) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{search_text: text} = record} when is_binary(text) and text != "" ->
        write_embedding(record, text)

      # Record exists but has nothing to embed yet, or it's gone — nothing to do.
      {:ok, _record} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp write_embedding(record, text) do
    with {:ok, vector} <- Search.embed_document(text),
         {:ok, _record} <-
           record
           |> Ash.Changeset.for_update(:set_embedding, %{embedding: vector}, authorize?: false)
           |> Ash.update() do
      :ok
    end
  end
end
