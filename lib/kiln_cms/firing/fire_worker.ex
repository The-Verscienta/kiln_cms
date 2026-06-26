defmodule KilnCMS.Firing.FireWorker do
  @moduledoc """
  Fires a just-published document into per-surface artifacts **off the publish
  request path** (decision D9, perf #201).

  Enqueued by `KilnCMS.CMS.Changes.FireArtifacts` after the publish transition
  commits, so the publish action returns immediately instead of blocking on a
  3-surface render + artifact upserts + reference rebuild. Delivery and the
  artifact API fall back to a live render on a cache/artifact miss, so content
  is still served in the brief window before the artifact lands.

  Mirrors the firing the change used to do synchronously: fire, invalidate
  referrers (which fans out `RefireWorker`), and enqueue per-block embedding +
  Meilisearch indexing.
  """
  use Oban.Worker,
    queue: :firing,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:type, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  require Logger

  alias KilnCMS.Firing.{Engine, References}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => type_str, "id" => id}}) do
    type = References.type_atom(type_str)

    with false <- is_nil(type),
         {:ok, document} <- References.load_published(type, id) do
      Engine.fire(document)
      References.invalidate(type, id, [References.key(type, id)])
      enqueue_indexing(type, id)
      :ok
    else
      # Unknown type, or the record was unpublished/deleted before firing ran —
      # nothing to fire. (A later publish re-enqueues.)
      _ -> :ok
    end
  rescue
    error ->
      Logger.error("Firing failed for #{inspect(id)}: #{inspect(error)}")
      :ok
  end

  defp enqueue_indexing(type, id) do
    # Re-index per-block embeddings for the fired content (decision D16).
    if KilnCMS.Search.semantic?() do
      %{"type" => to_string(type), "id" => id}
      |> KilnCMS.Search.BlockEmbeddingWorker.new()
      |> Oban.insert()
    end

    # Upsert into the optional Meilisearch index (Phase 6). No-op when disabled.
    if KilnCMS.Search.Meilisearch.enabled?() do
      %{"op" => "upsert", "type" => to_string(type), "id" => id}
      |> KilnCMS.Search.MeilisearchWorker.new()
      |> Oban.insert()
    end

    :ok
  end
end
