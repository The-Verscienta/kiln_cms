defmodule KilnCMS.CMS.Changes.DeleteChunkEmbeddings do
  @moduledoc """
  On a hard `:purge`, deletes the document's chunk embeddings (#1940,
  `KilnCMS.Search.DocumentChunkEmbedding`) — the cascade a foreign key would
  give them if one could point into every content table at once.

  Runs in `after_action`, so inside the purge's own transaction: the
  document and its chunks go together, or neither does. A soft delete does
  not run this — trash keeps its own `embedding` column too, so restoring it
  brings the vectors back with it — and the rows of an archived document are
  harmless meanwhile: the block leg reads documents through the caller's
  read, which never returns one.

  Unconditional on `chunk_long_documents`: the rows may predate the knob
  being switched off, and deleting none is one indexed `DELETE` of nothing.
  """
  use Ash.Resource.Change

  alias KilnCMS.Search.DocumentChunkIndexer

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      case DocumentChunkIndexer.clear(record, record.org_id) do
        :ok -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
