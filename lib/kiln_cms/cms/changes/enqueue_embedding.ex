defmodule KilnCMS.CMS.Changes.EnqueueEmbedding do
  @moduledoc """
  After a content create/update, enqueue a `KilnCMS.Search.EmbeddingWorker` to
  (re)compute the semantic embedding from the freshly-denormalized
  `search_text`. Runs after `SetSearchText`, off the write path.

  A no-op when semantic search is disabled, so the default install does no
  embedding work.
  """
  use Ash.Resource.Change

  alias KilnCMS.Search
  alias KilnCMS.Search.EmbeddingWorker

  @impl true
  def change(changeset, _opts, _context) do
    if Search.semantic?() do
      Ash.Changeset.after_action(changeset, &enqueue/2)
    else
      changeset
    end
  end

  defp enqueue(_changeset, %resource{id: id} = record) do
    %{"resource" => to_string(resource), "id" => id}
    |> EmbeddingWorker.new()
    |> Oban.insert!()

    {:ok, record}
  end
end
