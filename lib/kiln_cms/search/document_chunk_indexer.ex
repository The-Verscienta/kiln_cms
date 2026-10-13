defmodule KilnCMS.Search.DocumentChunkIndexer do
  @moduledoc """
  Writes a document's chunk embeddings — the vectors over the part of its
  `search_text` past the embedder's window (#1940,
  `KilnCMS.Search.DocumentChunkEmbedding`).

  Runs inside `KilnCMS.Search.EmbeddingWorker`, right after the document's own
  vector is written, so chunks follow the document vector everywhere it goes:
  every content write (`EnqueueEmbedding`), `mix kiln.embed_all`, drafts
  included. Only when `KilnCMS.Search.chunk_long_documents?/0` is on — with
  it off the worker never calls `reindex/3`, so nothing here reads or writes.

  ## Replace, atomically

  A document's chunks are positional: an edit near the top shifts every
  window after it. So a re-embed does not upsert row by row; it computes the
  new set first (outside any transaction — inference is the slow part) and
  then deletes the old rows and inserts the new ones in **one** transaction.
  A reader sees the old set or the new one, never half of each, and a
  document that shrank back inside the window is left with none.

  The inference is not always paid again: a new chunk whose `content_hash`
  (of exactly the text embedded, under the configured model and prefix)
  matches a stored row reuses that row's vector — an edit to the last
  paragraph of a long record re-embeds the last window, not all of them.

  ## A failed embed changes nothing

  If any chunk fails to embed (serving down, OOM), the stored rows are left
  as they were and the error is returned for the worker to retry. Replacing
  the set with the chunks that did embed would delete the only copy of the
  others on the strength of a failed call — `BlockIndexer.prune_stale/3`
  refuses the same trade for the same reason.

  ## Cost and the embedding budget

  Each chunk is one more inference per re-embed of a long record: about 2×
  the embedding work for a corpus whose long records run to two or three
  windows (#1940), bounded per document by `chunk_max_per_document/0`.

  That inference is charged to the `"search_embedding"` budget
  (`KilnCMS.Search.embedding_budget_limits/2`), one unit per chunk that
  actually reaches the model. A chunk whose vector is reused from the stored
  set is free, and a save that changes nothing past the window charges
  nothing. The document's own head vector stays uncharged, as it always was:
  chunks are the opt-in extra cost, and the budget is what bounds it.

  The charge is **unattended** (`unattended?: true`, no user): nobody is
  waiting on a chunk, so the work stops at `embedding_unattended_share/0` of
  the org's window and leaves the rest for editors' own panels. A backfill
  after turning the knob on therefore paces itself across windows instead of
  starving the editors.

  The room is read first (`Search.embedding_remaining/3`) and the charge made
  only when the whole document fits, because a Hammer window counts a
  refused charge too. When it does not fit:

    * `{:error, {:rate_limited, ms}}` — the window is spent; nothing was
      charged and the stored rows are untouched. `EmbeddingWorker` snoozes
      the job until the window rolls over, so for at most one window a
      document's chunks may describe text it had before this save.
    * `{:error, :unattended_disabled}` — the share is `0`, or smaller than
      this one document's chunk count, so this document can never be
      chunked under the current budget. `EmbeddingWorker` clears its chunks
      (the document falls back to its head vector, the behaviour before
      #1940) and logs, rather than retrying forever or keeping chunks that
      describe text the document no longer has.
  """
  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.LLM.Budget
  alias KilnCMS.Search
  alias KilnCMS.Search.{Chunker, DocumentChunkEmbedding}
  alias KilnCMS.SearchIndex

  require Logger

  # Every read and write here is the search system's (#1402):
  # `DocumentChunkEmbedding` admits it by name and no one else writes.
  defp system_actor, do: KilnCMS.SystemActor.new(:search)

  @doc """
  The texts `reindex/3` would embed for `record` with this `search_text`, in
  order — `KilnCMS.Search.Chunker` under the configured window, overlap, cap
  and document prefix. Exposed so the chunk set is inspectable without
  writing it.
  """
  @spec inputs(struct(), String.t() | nil) :: [String.t()]
  def inputs(record, text) do
    Chunker.chunks(text, Map.get(record, :title),
      window_tokens: Search.chunk_window_tokens(),
      overlap_tokens: Search.chunk_overlap(),
      max_chunks: Search.chunk_max_per_document(),
      prefix: Search.document_prefix()
    )
  end

  @doc """
  Replace `record`'s stored chunks with the ones its `search_text` (`text`)
  has now, under tenant `org_id`. Returns `{:ok, count}` — the number of
  chunks the document now has — or `{:error, reason}` with the stored rows
  untouched, including the budget's `{:rate_limited, ms}` and
  `:unattended_disabled` (moduledoc, "Cost and the embedding budget").
  """
  @spec reindex(struct(), Ash.UUID.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reindex(%resource{id: id} = record, org_id, text) do
    case ContentTypes.type_atom(resource) do
      nil -> {:ok, 0}
      type -> do_reindex(type, id, org_id, inputs(record, text))
    end
  end

  @doc """
  Delete every stored chunk of `record`. What a passphrase lock (#496) and a
  hard `:purge` do: the document must stop being reachable through any of its
  vectors, whatever `chunk_long_documents` says now — it may have been on
  when the rows were written.
  """
  @spec clear(struct(), Ash.UUID.t()) :: :ok | {:error, term()}
  def clear(%resource{id: id}, org_id) do
    case ContentTypes.type_atom(resource) do
      nil -> :ok
      type -> type |> existing(id, org_id) |> destroy(org_id)
    end
  end

  defp do_reindex(type, id, org_id, inputs) do
    existing = existing(type, id, org_id)
    reusable = Map.new(existing, &{&1.content_hash, &1.embedding})
    units = Enum.count(inputs, &(reused(&1 |> hash(), reusable) == :error))

    with {:ok, rows} <- charged(org_id, units, fn -> embed_all(inputs, reusable, type, id) end),
         {:ok, _} <- replace(existing, rows, org_id) do
      {:ok, length(rows)}
    end
  end

  # The budget charge around `fun` — see the moduledoc, "Cost and the
  # embedding budget". Nothing to infer is free and never reads the budget.
  defp charged(_org_id, 0, fun), do: fun.()

  defp charged(org_id, units, fun) do
    case Search.embedding_remaining(org_id, nil, true) do
      room when room == :infinity or room >= units ->
        Budget.charge(
          "search_embedding",
          org_id,
          nil,
          Search.embedding_budget_limits(true, units),
          fun
        )

      _short ->
        {:error, refusal(units)}
    end
  end

  # What `Budget.check/4` would have said, without the charge it would have
  # counted. A document bigger than the whole unattended ceiling can never
  # fit, so it is reported as the standing refusal it is, not as a wait.
  defp refusal(units) do
    {_count, window_ms} = per_org = Search.embedding_per_org_limit()

    if Budget.unattended_ceiling(per_org, Search.embedding_unattended_share()) < units,
      do: :unattended_disabled,
      else: {:rate_limited, Budget.window_reset_ms(window_ms)}
  end

  # Every chunk embedded (or reused), or the first failure — see the
  # moduledoc on why a partial set is never written.
  defp embed_all(inputs, reusable, type, id) do
    now = DateTime.utc_now()

    inputs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {input, index}, {:ok, acc} ->
      hash = hash(input)

      case vector_for(input, hash, reusable) do
        {:ok, vector} ->
          row = %{
            document_type: type,
            document_id: id,
            chunk_index: index,
            content_hash: hash,
            embedding: vector,
            embedded_at: now
          }

          {:cont, {:ok, [row | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp vector_for(input, hash, reusable) do
    case reused(hash, reusable) do
      {:ok, vector} -> {:ok, vector}
      :error -> embed(input)
    end
  end

  # One answer to "is this chunk free?", shared by the charge (`units`) and
  # the embed, so the budget is charged for exactly the inferences made.
  defp reused(hash, reusable) do
    case Map.fetch(reusable, hash) do
      {:ok, vector} when is_list(vector) -> {:ok, vector}
      _miss -> :error
    end
  end

  # `embed_document/1`, not `embed/1`: a chunk is document text, so it gets
  # the document prefix an asymmetric model (e5's `passage: `) expects — the
  # same space as the document vector it is compared beside.
  defp embed(input) do
    case Search.embed_document(input) do
      {:ok, vector} -> {:ok, vector}
      {:error, reason} -> {:error, reason}
    end
  end

  # Delete-then-insert in one transaction (moduledoc, "Replace,
  # atomically"). The existing ids come from a read already scoped to this
  # tenant and document, so the delete cannot reach another's rows.
  #
  # Skipped when the stored set already is the new one — the common case,
  # since every save re-embeds and most saves do not touch the text past the
  # window. Rewriting identical rows would churn the HNSW index for nothing.
  defp replace(existing, rows, org_id) do
    if same_set?(existing, rows), do: {:ok, :unchanged}, else: rewrite(existing, rows, org_id)
  end

  defp same_set?(existing, rows) do
    stored = existing |> Enum.sort_by(& &1.chunk_index) |> Enum.map(& &1.content_hash)
    stored == Enum.map(rows, & &1.content_hash)
  end

  defp rewrite(existing, rows, org_id) do
    KilnCMS.Repo.transaction(fn ->
      with :ok <- destroy(existing, org_id),
           :ok <- insert(rows, org_id) do
        :replaced
      else
        {:error, reason} -> KilnCMS.Repo.rollback(reason)
      end
    end)
  end

  defp insert([], _org_id), do: :ok

  defp insert(rows, org_id) do
    case SearchIndex.create_document_chunk_embedding(rows,
           actor: system_actor(),
           tenant: org_id,
           bulk_options: [return_errors?: true, stop_on_error?: true]
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp destroy([], _org_id), do: :ok

  defp destroy(existing, org_id) do
    ids = Enum.map(existing, & &1.id)

    DocumentChunkEmbedding
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_destroy(:destroy, %{},
      actor: system_actor(),
      tenant: org_id,
      strategy: [:atomic, :stream],
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("document chunk delete failed: #{inspect(errors)}")
        {:error, errors}
    end
  end

  defp existing(type, id, org_id) do
    SearchIndex.document_chunk_embeddings_for!(type, id,
      actor: system_actor(),
      tenant: org_id,
      query: [select: [:id, :chunk_index, :content_hash, :embedding]]
    )
  end

  # Over exactly what is embedded, and what it is embedded *with*: a vector
  # from another model or another prefix is not reusable, so a model swap
  # (`docs/semantic-search-plan.md`) misses every hash rather than keeping
  # the old space's vectors under new text.
  defp hash(input) do
    :crypto.hash(:sha256, [Search.model(), 0, Search.document_prefix(), 0, input])
    |> Base.encode16(case: :lower)
  end
end
