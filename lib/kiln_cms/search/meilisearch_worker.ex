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
  use Oban.Worker, queue: :default, max_attempts: 3

  alias KilnCMS.CMS
  alias KilnCMS.Search.Meilisearch

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "delete", "type" => type, "id" => id}}) do
    if Meilisearch.enabled?(), do: ok(Meilisearch.delete_document(type, id)), else: :ok
  end

  def perform(%Oban.Job{args: %{"op" => "upsert", "type" => type, "id" => id}}) do
    if Meilisearch.enabled?() do
      case load(type, id) do
        {:ok, record} -> ok(Meilisearch.index_document(record))
        # Gone, archived, or unpublished before we ran — make sure it's not indexed.
        _ -> ok(Meilisearch.delete_document(type, id))
      end
    else
      :ok
    end
  end

  # Only published, non-archived documents belong in the index (public view).
  defp load("page", id), do: published(CMS.get_page(id, authorize?: false))
  defp load("post", id), do: published(CMS.get_post(id, authorize?: false))
  defp load(_type, _id), do: :error

  defp published({:ok, %{state: :published} = record}), do: {:ok, record}
  defp published(_), do: :error

  # Surface real transport failures so Oban retries; treat disabled/missing as done.
  defp ok({:error, reason}), do: {:error, reason}
  defp ok(_), do: :ok
end
