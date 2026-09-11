defmodule KilnCMS.CMS.Changes.EnqueueTagEmbedding do
  @moduledoc """
  After a tag is created or renamed, enqueue `KilnCMS.Search.TagEmbeddingWorker`
  to (re)compute its name embedding, so the tag leg of hybrid search can rank
  it. A no-op when semantic search is disabled, so the default install does no
  embedding work — the same contract as `EnqueueEmbedding` for content.
  """
  use Ash.Resource.Change

  alias KilnCMS.Search
  alias KilnCMS.Search.TagEmbeddingWorker

  @impl true
  def change(changeset, _opts, _context) do
    if Search.semantic?() do
      Ash.Changeset.after_action(changeset, &enqueue/2)
    else
      changeset
    end
  end

  defp enqueue(_changeset, %{id: id, org_id: org_id} = tag) do
    %{"org_id" => org_id, "tag_id" => id}
    |> TagEmbeddingWorker.new()
    |> Oban.insert!()

    {:ok, tag}
  end
end
