defmodule KilnCMS.Search.MeilisearchWorker do
  @moduledoc """
  Keeps the optional Meilisearch index in sync with published content, off the
  write path. Enqueued by `KilnCMS.CMS.Changes.FireArtifacts` on publish
  (`"op" => "upsert"`) and `KilnCMS.CMS.Changes.DeleteArtifacts` on unpublish
  (`"op" => "delete"`).

  A no-op when the backend is disabled, so the default install enqueues nothing
  of consequence. An upsert whose document has vanished (deleted before the job
  ran) degrades to a delete, keeping the index from drifting.

  ## Which instance, and holding (#1558)

  Every job asks `KilnCMS.Search.Meilisearch.SiteInstance.resolve/1` for its
  site's instance when it runs — the site's own, or the operator's — and uses
  that one target for the whole job. When the site set its own instance and it
  cannot be used (its settings can't be read, or its key can't be decrypted),
  the job **holds**: it returns an error and Oban retries it on `backoff/1`,
  for about 16 hours in all, like mail. It never writes the site's content into
  the operator's instance instead.

  A third op, `"reindex"` (`enqueue_reindex/1`), rebuilds one site into
  whichever instance it now uses. Every write to the site's settings enqueues
  one, and once it succeeds it releases the site's held jobs so they run now
  rather than at their next backoff.
  """
  # Dedupe repeated index ops for the same document+op while pending.
  use Oban.Worker,
    queue: :search,
    # ~16 hours of retries (see `backoff/1`): long enough for a site admin to
    # re-enter a key that a `SECRET_KEY_BASE` rotation made unreadable.
    max_attempts: 9,
    unique: [
      period: 60,
      # `:org_id` in the dedup key so per-org index ops don't collapse (epic #336).
      keys: [:org_id, :op, :type, :id],
      # Note what this key can and cannot protect. Since #1006 an upsert decides
      # **presence**, not just content, so a deduped duplicate can now decide
      # whether a gated body stays in the index. That is why
      # `FireWorker.enqueue_indexing/4` picks `"delete"` for a document that is
      # no longer public rather than relying on an upsert to degrade into one:
      # a different op is a different key, so a removal is never deduped against
      # an upsert that is already executing with a stale, public record.
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.CMS
  alias KilnCMS.Search.Meilisearch
  alias KilnCMS.Search.Meilisearch.SiteInstance

  require Logger

  # Seconds before retry N+1 — about 16 hours across `max_attempts: 9`.
  @backoff_seconds [30, 120, 600, 1_800, 3_600, 7_200, 14_400, 28_800]

  @worker inspect(__MODULE__)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Enum.at(@backoff_seconds, attempt - 1, List.last(@backoff_seconds))

  @doc """
  Enqueue a full reindex of the site `org_id` into the instance it resolves to
  when the job runs. See `KilnCMS.Search.Meilisearch.reindex_org/1`.

  Deduplicated only against a reindex that has not started: one already
  running may have resolved the instance the site just moved away from, so a
  change made while it runs must still get its own.
  """
  @spec enqueue_reindex(Ash.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_reindex(org_id) when is_binary(org_id) do
    %{"org_id" => org_id, "op" => "reindex"}
    |> new(unique: [period: 300, keys: [:org_id, :op], states: [:available, :scheduled]])
    |> Oban.insert()
  end

  @doc """
  How much indexing work the site `org_id` has outstanding, for its settings
  page: `queued` jobs are waiting or running, `held` ones failed and are
  waiting to retry (the instance didn't answer, or can't be used).
  """
  @spec pending(Ash.UUID.t()) :: %{queued: non_neg_integer(), held: non_neg_integer()}
  def pending(org_id) when is_binary(org_id) do
    counts =
      from(j in Oban.Job,
        where:
          j.worker == ^@worker and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'org_id' = ?", j.args, ^org_id),
        group_by: j.state,
        select: {j.state, count(j.id)}
      )
      |> KilnCMS.Repo.all()
      |> Map.new()

    %{
      queued:
        Map.get(counts, "available", 0) + Map.get(counts, "scheduled", 0) +
          Map.get(counts, "executing", 0),
      held: Map.get(counts, "retryable", 0)
    }
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "reindex", "org_id" => org_id}}) do
    case Meilisearch.reindex_org(org_id) do
      {:ok, _count} ->
        release_held(org_id)
        :ok

      :disabled ->
        :ok

      {:error, reason} ->
        held(org_id, reason)
    end
  end

  # A delete from before #1558 carries no `"org_id"`; `resolve(nil)` is the
  # operator's instance, the only one there was.
  def perform(%Oban.Job{args: %{"op" => "delete", "type" => type, "id" => id} = args}) do
    with_target(args["org_id"], &Meilisearch.delete_document(&1, type, id))
  end

  def perform(%Oban.Job{
        args: %{"op" => "upsert", "org_id" => org_id, "type" => type, "id" => id}
      }) do
    # Resolved before the document is read: a held job reads no content.
    with_target(org_id, fn target ->
      case load(org_id, type, id) do
        {:ok, record} -> Meilisearch.index_document(target, record)
        # Gone, archived, or unpublished before we ran — make sure it's not indexed.
        _ -> Meilisearch.delete_document(target, type, id)
      end
    end)
  end

  # Back-compat (epic #336): an upsert job enqueued before multi-tenancy has no
  # `"org_id"` — default it to the sole org and re-dispatch rather than crash
  # across the deploy boundary. (The `delete` clause above needs no org_id.)
  def perform(%Oban.Job{args: %{"op" => "upsert", "type" => _, "id" => _} = args} = job) do
    perform(%{job | args: Map.put(args, "org_id", KilnCMS.Accounts.default_org_id())})
  end

  # Only content that is public to an anonymous visitor belongs in the index —
  # see `published/1`.
  #
  # `"entry"` is the storage key every dynamic content type (D17) fires under,
  # not a type an editor ever names. Without this clause the fallback answered
  # `:error` for all of them, so publishing a dynamic entry issued a DELETE for
  # a document that had never been indexed and the whole type was invisible to
  # the backend — silently, which is the part that made it worth fixing (#1012).
  #
  # The fallback still exists, and still means something: a type this worker has
  # no clause for is not indexable, and answering `:error` removes whatever a
  # previous version may have put there.
  #
  # All three keep `authorize?: false` (#1402): threading the system actor
  # would mean granting it the `Content` read policy standing, over every
  # document on every site — wider than these calls, which are one id under one
  # tenant, handed here by the fire path, and passed straight to `published/1`,
  # which drops anything an anonymous visitor could not read.
  defp load(org_id, "page", id),
    do: published(CMS.get_page(id, authorize?: false, tenant: org_id))

  # (bypass: as above)
  defp load(org_id, "post", id),
    do: published(CMS.get_post(id, authorize?: false, tenant: org_id))

  # (bypass: as above)
  defp load(org_id, "entry", id),
    do: published(CMS.get_entry(id, authorize?: false, tenant: org_id))

  defp load(_org_id, _type, _id), do: :error

  # A document belongs in the index only if an anonymous visitor could read it:
  # published, `:public`, and not passphrase-locked. One shared predicate, so
  # the surfaces that make this decision in memory cannot drift apart — see
  # `KilnCMS.CMS.Audiences.public_to_anonymous?/1`.
  #
  # Anything else falls through to `:error`, and the caller turns that into a
  # DELETE — so gating or locking an already-indexed document removes it rather
  # than merely stopping future updates. Re-opening it to `:public` puts it back:
  # this reads the document's current state, not a one-way door.
  #
  # The reason is a property of this index, not a policy preference. Meilisearch
  # has **no audience, grant or password facet** — `Meilisearch.to_document/1`
  # emits none and `configure/0` declares only `org_id`/`type`/`locale` as
  # filterable — and its queries carry no actor. Anything indexed is readable by
  # everyone who can reach the index.
  #
  # Kiln itself has no caller for `Meilisearch.search/2`, so nothing in-app
  # exposes this today. But the point of the backend is that a deployment aims
  # something at it, and the common shape is a front end or edge worker querying
  # Meilisearch **directly** with a search-only key — which never passes through
  # `search/2` at all. That is why the fix has to be "don't index it" rather than
  # "filter it at query time" (#1006). `docs/meilisearch.md` says what the index
  # holds, so an operator exposing it knows what they are exposing. Webhooks
  # are the other operator-configured sink and do NOT apply this rule — see
  # #1014 for why that is a different question rather than the same one.
  #
  # Kiln's own Postgres search has no equivalent exposure **to an anonymous
  # caller**: `search`/`search_published` are policy-gated, so gated content is
  # excluded by the same read policy that keeps it out of feeds and the sitemap
  # — and, since #1013, the `_published` twins and the `/api/search` hybrid
  # endpoint hold the same line against an over-scoped API key, which the read
  # policy alone does not (an admin bypasses it).
  defp published({:ok, record}) do
    if KilnCMS.CMS.Audiences.public_to_anonymous?(record), do: {:ok, record}, else: :error
  end

  defp published(_), do: :error

  # One target for the whole job. `:disabled` (the site uses no instance) is
  # done; an unusable site instance holds — see the moduledoc.
  defp with_target(org_id, fun) do
    case SiteInstance.resolve(org_id) do
      {:ok, target} -> ok(fun.(target))
      :disabled -> :ok
      {:error, reason} -> held(org_id, reason)
    end
  end

  defp held(org_id, reason) do
    detail =
      if reason in [:unavailable, :credentials_unreadable],
        do: SiteInstance.describe_error(reason),
        else: "it failed: #{inspect(reason, limit: 10, printable_limit: 200)}"

    Logger.warning("Holding Meilisearch indexing for site #{org_id}: #{detail}")
    {:error, "held: #{detail}"}
  end

  # After a successful reindex, the site's instance works again: whatever was
  # held behind it runs now instead of at its next backoff, which can be hours.
  defp release_held(org_id) do
    from(j in Oban.Job,
      where:
        j.worker == ^@worker and j.state == "retryable" and
          fragment("?->>'org_id' = ?", j.args, ^org_id)
    )
    |> Oban.retry_all_jobs()
  end

  # Surface real transport failures so Oban retries; treat disabled/missing as done.
  defp ok({:error, reason}), do: {:error, reason}
  defp ok(_), do: :ok
end
