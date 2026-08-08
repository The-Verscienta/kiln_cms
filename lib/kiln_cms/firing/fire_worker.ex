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
      # `:cancelled` was in this list so a burst of reads against an orphan row
      # collapsed into one job rather than one per read (#664). It is out again
      # (#1025), because a cancelled job is a decision NOT to fire, and deduping
      # a fresh request against it turns "we looked and there was nothing" into
      # "we will never look again".
      #
      # That is the issue's own scenario: trash a published document, let any
      # `FireWorker` run in the window (a read miss, an oEmbed resolve, the
      # sweep, or the publish's own job arriving late) — it finds no published
      # row, purges and cancels — then restore within 60s and the restore's
      # enqueue collides with that cancelled row. The document comes back live
      # with no artifacts and nothing retries.
      #
      # The thundering herd it guarded against is bounded anyway: `purge_orphan/3`
      # deletes the artifacts, so the cache misses that drove the drip stop.
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  require Logger

  alias KilnCMS.Firing.{Engine, References}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "type" => type_str, "id" => id}}) do
    case References.type_atom(type_str) do
      nil -> {:cancel, "no content type answers to #{inspect(type_str)}"}
      type -> fire(org_id, type, id)
    end
  end

  # Back-compat (epic #336): a job enqueued by the pre-multi-tenancy release has
  # no `"org_id"` in its args. Rather than FunctionClauseError → retry → discard
  # across the deploy boundary, default it to the sole (default) org and
  # re-dispatch. Safe while the single-org rollout guard holds.
  def perform(%Oban.Job{args: %{"type" => _, "id" => _} = args} = job) do
    perform(%{job | args: Map.put(args, "org_id", KilnCMS.Accounts.default_org_id())})
  end

  # One clause per outcome of the load, because they are four different
  # situations and used to be one (#664).
  defp fire(org_id, type, id) do
    case References.load_published(org_id, type, id) do
      {:ok, document} ->
        # `fire/2` reads the tenant off `document.org_id`; the wave + indexing carry
        # `org_id` explicitly so their reads/jobs stay scoped to this org.
        Engine.fire(document)
        References.invalidate(org_id, type, id, [References.key(type, id)])
        enqueue_indexing(org_id, type, id, document)
        :ok

      :absent ->
        purge_orphan(org_id, type, id)

      :unknown_type ->
        {:cancel, "no compiled resource for #{inspect(type)}"}

      {:error, reason} ->
        # The read failed — which says nothing about whether the document is
        # there. Retrying is the point: this used to answer `:ok`, so a
        # just-published document whose load hit a blip never fired at all and
        # `max_attempts` never engaged. Nothing re-enqueues it either, because
        # the read path's stale check needs an artifact row that was never
        # written.
        {:error, reason}
    end
  rescue
    error ->
      # A render crash. Now an error rather than `:ok`, so Oban retries it and
      # then *discards* it visibly instead of recording three successes that did
      # nothing. Bounded by `max_attempts`.
      Logger.error("Firing failed for #{inspect(id)}: #{inspect(error)}")
      {:error, error}
  end

  # The document is settled-gone, so its artifacts are garbage: this is exactly
  # what `KilnCMS.CMS.Changes.DeleteArtifacts` intends on unpublish, and rows
  # survive it because that purge is best-effort inside a `try/rescue`.
  #
  # Deleting here is what makes the drip converge (#664). Before this, the row
  # stayed stale, so the next cache miss re-enqueued — forever, one job per
  # cache expiry, with no failed job and nothing marking the row as hopeless.
  # Cancelling alone would not have done it: the unique window is 60s and the
  # firing cache TTL is an hour, so the dedup never overlaps the next enqueue.
  #
  # Safe only because `:absent` now means *settled* absence. While it also
  # covered "the read blew up", purging here would have deleted live artifacts
  # for a published document during a connection blip.
  defp purge_orphan(org_id, type, id) do
    Engine.purge(org_id, type, id)
    {:cancel, "no published #{type} #{inspect(id)}; purged its orphaned artifacts"}
  end

  defp enqueue_indexing(org_id, type, id, document) do
    # Re-index per-block embeddings for the fired content (decision D16).
    if KilnCMS.Search.semantic?() do
      %{"org_id" => org_id, "type" => to_string(type), "id" => id}
      |> KilnCMS.Search.BlockEmbeddingWorker.new()
      |> Oban.insert()
    end

    # Keep the optional Meilisearch index in step (Phase 6). No-op when disabled.
    if KilnCMS.Search.Meilisearch.enabled?() do
      %{"org_id" => org_id, "op" => meili_op(document), "type" => to_string(type), "id" => id}
      |> KilnCMS.Search.MeilisearchWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  # The op is chosen HERE, from the document that was just fired, rather than
  # left for the worker to discover — and that is a correctness requirement, not
  # an optimisation.
  #
  # `MeilisearchWorker` refuses to index anything not public to an anonymous
  # visitor and turns it into a removal (#1006), so an upsert would reach the
  # right answer on its own. But the worker's uniqueness key is
  # `{org_id, op, type, id}`: an upsert enqueued because a document was just
  # gated would be deduped against an upsert already **executing** for the same
  # document — one that loaded the record while it was still public. That job
  # writes the public body and finishes, and nothing re-enqueues, because only a
  # fire does. The gated body would stay anonymously searchable until an
  # unrelated edit or a manual `mix kiln.meili.reindex`.
  #
  # A removal is a different op, so it is never deduped against a running
  # upsert. The worker's own check stays as the second line of defence, for a
  # document gated between this enqueue and that job running.
  defp meili_op(document) do
    if KilnCMS.CMS.Audiences.public_to_anonymous?(document), do: "upsert", else: "delete"
  end
end
