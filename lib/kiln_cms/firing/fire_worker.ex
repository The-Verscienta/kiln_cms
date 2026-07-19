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
      # `:org_id` in the dedup key so the same `{type, id}` in two orgs isn't
      # collapsed into one job (epic #336).
      keys: [:org_id, :type, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  require Logger

  alias KilnCMS.Firing.{Engine, References}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "type" => type_str, "id" => id}}) do
    type = References.type_atom(type_str)

    with false <- is_nil(type),
         {:ok, document} <- References.load_published(org_id, type, id) do
      # `fire/2` reads the tenant off `document.org_id`; the wave + indexing carry
      # `org_id` explicitly so their reads/jobs stay scoped to this org.
      Engine.fire(document)
      References.invalidate(org_id, type, id, [References.key(type, id)])
      enqueue_indexing(org_id, type, id)
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

  # Back-compat (epic #336): a job enqueued by the pre-multi-tenancy release has
  # no `"org_id"` in its args. Rather than FunctionClauseError → retry → discard
  # across the deploy boundary, default it to the sole (default) org and
  # re-dispatch. Safe while the single-org rollout guard holds.
  def perform(%Oban.Job{args: %{"type" => _, "id" => _} = args} = job) do
    perform(%{job | args: Map.put(args, "org_id", KilnCMS.Accounts.default_org_id())})
  end

  defp enqueue_indexing(org_id, type, id) do
    # Re-index per-block embeddings for the fired content (decision D16).
    if KilnCMS.Search.semantic?() do
      %{"org_id" => org_id, "type" => to_string(type), "id" => id}
      |> KilnCMS.Search.BlockEmbeddingWorker.new()
      |> Oban.insert()
    end

    # Upsert into the optional Meilisearch index (Phase 6). No-op when disabled.
    if KilnCMS.Search.Meilisearch.enabled?() do
      %{"org_id" => org_id, "op" => "upsert", "type" => to_string(type), "id" => id}
      |> KilnCMS.Search.MeilisearchWorker.new()
      |> Oban.insert()
    end

    :ok
  end
end
