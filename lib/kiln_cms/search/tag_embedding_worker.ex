defmodule KilnCMS.Search.TagEmbeddingWorker do
  @moduledoc """
  Computes and stores a tag's name embedding off the write path — the
  `KilnCMS.Search.TagEmbedding` row the tag leg of `KilnCMS.Search.hybrid/3`
  ranks by. Enqueued by `KilnCMS.CMS.Changes.EnqueueTagEmbedding` on every
  tag create and rename, and by `mix kiln.embed_all` for backfill.

  Until now tag vectors were written lazily, by the tag-suggestion panel the
  first time it ranked a tag (`KilnCMS.Search.Related`); a leg that runs on
  every search cannot wait for that, so the row is written when the tag is.
  A no-op when semantic search is disabled, or the tag is gone.
  """
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:org_id, :tag_id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.Search
  alias KilnCMS.Search.VectorCache

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "tag_id" => tag_id}}) do
    if Search.semantic?() do
      # Taxonomy is world-readable (published content references it), so the
      # tag read needs no bypass at all — an actorless authorized read returns
      # exactly the same row (#1402).
      case KilnCMS.CMS.get_tag(tag_id, tenant: org_id) do
        {:ok, %{name: name} = tag} when is_binary(name) -> store(tag, org_id)
        _gone -> :ok
      end
    else
      :ok
    end
  end

  # The embedder answering nothing for this name is skipped, not retried
  # forever: the tag simply does not rank until it is renamed or backfilled.
  defp store(tag, org_id) do
    case VectorCache.embed_document(tag.name) do
      vector when is_list(vector) ->
        KilnCMS.SearchIndex.upsert_tag_embedding!(
          %{tag_id: tag.id, name: tag.name, embedding: vector, embedded_at: DateTime.utc_now()},
          # `TagEmbedding` admits the search system actor by name (#1402);
          # nothing else writes that table.
          actor: KilnCMS.SystemActor.new(:search),
          tenant: org_id
        )

        :ok

      _none ->
        :ok
    end
  end
end
