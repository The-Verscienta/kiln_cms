defmodule KilnCMS.Search.EmbeddingWorker do
  @moduledoc """
  Computes and stores a content record's semantic embedding off the write path,
  mirroring `KilnCMS.Media.VariantWorker`: load the record, embed its
  denormalized `search_text`, and persist `embedding` + `embedded_at` via the
  resource's `:set_embedding` action.

  A no-op when semantic search is disabled, the record is gone, or it has no
  text to embed yet. Enqueued by `KilnCMS.CMS.Changes.EnqueueEmbedding` after
  create/update, and by `mix kiln.embed_all` for backfill.

  With `KilnCMS.Search.chunk_long_documents?/0` on, the same job then writes
  the record's chunk embeddings — the text past the embedder's window
  (#1940, `KilnCMS.Search.DocumentChunkIndexer`) — so chunks follow the
  document vector through every path that writes it. Off, the job does
  exactly what it did before #1940.
  """
  # Coalesce rapid autosaves: while a job for this record is still pending, a new
  # enqueue is deduped instead of stacking one embedding job per keystroke-save.
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [
      period: 60,
      # `:org_id` in the dedup key so the same record in two orgs embeds
      # separately (epic #336).
      keys: [:org_id, :resource, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.Search
  alias KilnCMS.Search.DocumentChunkIndexer

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "resource" => resource, "id" => id}}) do
    if Search.semantic?() do
      resource |> String.to_existing_atom() |> embed(org_id, id)
    else
      :ok
    end
  end

  # Back-compat (epic #336): default the sole org for a job enqueued before
  # multi-tenancy (no `"org_id"`) instead of crashing across the deploy boundary.
  def perform(%Oban.Job{args: %{"resource" => _, "id" => _} = args} = job) do
    perform(%{job | args: Map.put(args, "org_id", KilnCMS.Accounts.default_org_id())})
  end

  defp embed(resource, org_id, id) do
    # authorize?: false — kept (#1402). Threading the system actor here would mean a
    # `Checks.SystemActor` clause on the `Content` READ policy — a standing
    # grant over every document on every site, drafts included, to every system
    # caller. That is wider than this one call, which is bounded to a single id
    # under one tenant, an id this worker was handed by the fire path. The
    # WRITE below does carry the actor: `:set_embedding` is system-only, so it
    # can be named in the policy block.
    case Ash.get(resource, id, authorize?: false, tenant: org_id) do
      # A passphrase-locked document (#496) is not embedded, and any vector it
      # already had is cleared — locking content that was previously indexed has
      # to *remove* it, not just stop refreshing it. Checked before the
      # `search_text` clause so a locked document with text can't fall into it.
      #
      # Its chunks go too (#1940), whatever `chunk_long_documents` says now:
      # it may have been on when they were written.
      {:ok, %{access_password_hash: hash} = record} when not is_nil(hash) ->
        with :ok <- write_embedding(record, org_id, nil) do
          clear_chunks(record, org_id)
        end

      {:ok, %{search_text: text} = record} when is_binary(text) and text != "" ->
        with :ok <- write_embedding(record, org_id, text) do
          write_chunks(record, org_id, text)
        end

      # Record exists but has nothing to embed yet — its document vector is
      # left as it is, as it always was. With chunking on, a record whose
      # text was emptied has no text past any window, so its chunks are
      # replaced by none: a stale chunk would vouch for words the record no
      # longer has.
      {:ok, record} ->
        write_chunks(record, org_id, "")

      {:error, _reason} ->
        :ok
    end
  end

  # `:set_embedding` is a system-only content action; the content macro admits
  # this actor for it by name (#1402).
  defp system_actor, do: KilnCMS.SystemActor.new(:search)

  defp write_embedding(record, _org_id, nil), do: clear_embedding(record)

  defp write_embedding(record, org_id, text) do
    with {:ok, vector} <- Search.embed_document(text),
         {:ok, _record} <-
           record
           |> Ash.Changeset.for_update(:set_embedding, %{embedding: vector},
             # A system-only content action, admitted by name inside the
             # content macro's own create/update policy (#1402) — see the
             # policy block there.
             actor: system_actor(),
             tenant: org_id
           )
           |> Ash.update() do
      :ok
    end
  end

  # Off (the default), nothing is read or written — the knob's contract is
  # that turning it off changes no stored vector. An embed failure is
  # returned so Oban retries the job; the stored chunks stay as they were
  # (`DocumentChunkIndexer`, "A failed embed changes nothing").
  defp write_chunks(record, org_id, text) do
    if Search.chunk_long_documents?() do
      case DocumentChunkIndexer.reindex(record, org_id, text) do
        {:ok, _count} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp clear_chunks(record, org_id) do
    case DocumentChunkIndexer.clear(record, org_id) do
      :ok ->
        :ok

      # Logged and retried, never swallowed: chunks that fail to clear leave
      # locked content reachable through the block leg.
      {:error, reason} ->
        Logger.warning(
          "chunk embedding clear failed for #{inspect(record.__struct__)} #{record.id}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  defp clear_embedding(%{embedding: nil}), do: :ok

  defp clear_embedding(record) do
    record
    |> Ash.Changeset.for_update(:set_embedding, %{embedding: nil},
      # Same system-only action as `write_embedding/3` above. Clearing the
      # vector is what locking a previously indexed document must do.
      actor: system_actor(),
      tenant: record.org_id
    )
    |> Ash.update()
    |> case do
      {:ok, _record} ->
        :ok

      # Still `:ok` — a retry would hit the same refusal — but never silently:
      # a vector that fails to clear leaves locked content in semantic search.
      {:error, error} ->
        Logger.warning(
          "embedding clear failed for #{inspect(record.__struct__)} #{record.id}: " <>
            Exception.message(error)
        )

        :ok
    end
  end
end
