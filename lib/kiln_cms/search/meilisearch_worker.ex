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

  # Only published, non-archived documents belong in the index (public view).
  defp load(org_id, "page", id),
    do: published(CMS.get_page(id, authorize?: false, tenant: org_id))

  defp load(org_id, "post", id),
    do: published(CMS.get_post(id, authorize?: false, tenant: org_id))

  defp load(_org_id, _type, _id), do: :error

  defp published({:ok, %{state: :published} = record}), do: {:ok, record}
  defp published(_), do: :error

  # Surface real transport failures so Oban retries; treat disabled/missing as done.
  defp ok({:error, reason}), do: {:error, reason}
  defp ok(_), do: :ok
end
