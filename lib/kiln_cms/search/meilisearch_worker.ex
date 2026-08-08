defmodule KilnCMS.Search.MeilisearchWorker do
  @moduledoc """
  Keeps the optional Meilisearch index in sync with published content, off the
  write path. Enqueued by `KilnCMS.CMS.Changes.FireArtifacts` on publish
  (`"op" => "upsert"`) and `KilnCMS.CMS.Changes.DeleteArtifacts` on unpublish
  (`"op" => "delete"`).

  A no-op when the backend is disabled, so the default install enqueues nothing
  of consequence. An upsert whose document has vanished (deleted before the job
  ran) degrades to a delete, keeping the index from drifting.
  """
  # Dedupe repeated index ops for the same document+op while pending.
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
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

  alias KilnCMS.CMS
  alias KilnCMS.Search.Meilisearch

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "delete", "type" => type, "id" => id}}) do
    if Meilisearch.enabled?(), do: ok(Meilisearch.delete_document(type, id)), else: :ok
  end

  def perform(%Oban.Job{
        args: %{"op" => "upsert", "org_id" => org_id, "type" => type, "id" => id}
      }) do
    if Meilisearch.enabled?() do
      case load(org_id, type, id) do
        {:ok, record} -> ok(Meilisearch.index_document(record))
        # Gone, archived, or unpublished before we ran — make sure it's not indexed.
        _ -> ok(Meilisearch.delete_document(type, id))
      end
    else
      :ok
    end
  end

  # Back-compat (epic #336): an upsert job enqueued before multi-tenancy has no
  # `"org_id"` — default it to the sole org and re-dispatch rather than crash
  # across the deploy boundary. (The `delete` clause above needs no org_id.)
  def perform(%Oban.Job{args: %{"op" => "upsert", "type" => _, "id" => _} = args} = job) do
    perform(%{job | args: Map.put(args, "org_id", KilnCMS.Accounts.default_org_id())})
  end

  # Only content that is public to an anonymous visitor belongs in the index —
  # see `published/1`. Note the other reason this can answer `:error`: `load/3`
  # knows page and post only, while `FireWorker.enqueue_indexing/3` enqueues an
  # upsert for every fired type, so a dynamic-type entry (D17) also lands here
  # and is DELETEd — harmlessly, since it was never indexed, but it is not the
  # gating case (#1012).
  defp load(org_id, "page", id),
    do: published(CMS.get_page(id, authorize?: false, tenant: org_id))

  defp load(org_id, "post", id),
    do: published(CMS.get_post(id, authorize?: false, tenant: org_id))

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

  # Surface real transport failures so Oban retries; treat disabled/missing as done.
  defp ok({:error, reason}), do: {:error, reason}
  defp ok(_), do: :ok
end
