defmodule KilnCMS.Search.BlockEmbeddingWorker do
  @moduledoc """
  Re-indexes a document's block embeddings off the write path (Kiln v2 — D16).
  Enqueued on fire when semantic search is enabled. No-op otherwise / if the
  document is gone.
  """
  # Dedupe a fan-out of fire/refire jobs for the same document while pending.
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [
      period: 60,
      # `:org_id` in the dedup key so the same doc in two orgs re-indexes
      # separately (epic #336).
      keys: [:org_id, :type, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.{CMS, Search}
  alias KilnCMS.Search.BlockIndexer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "type" => type, "id" => id}}) do
    if Search.semantic?() do
      org_id |> load(type, id) |> reindex()
    else
      :ok
    end
  end

  # Back-compat (epic #336): default the sole org for a job enqueued before
  # multi-tenancy (no `"org_id"`) instead of crashing across the deploy boundary.
  def perform(%Oban.Job{args: %{"type" => _, "id" => _} = args} = job) do
    perform(%{job | args: Map.put(args, "org_id", KilnCMS.Accounts.default_org_id())})
  end

  defp load(org_id, "page", id), do: CMS.get_page(id, authorize?: false, tenant: org_id)
  defp load(org_id, "post", id), do: CMS.get_post(id, authorize?: false, tenant: org_id)
  defp load(_org_id, _type, _id), do: :error

  defp reindex({:ok, document}) do
    {:ok, _count} = BlockIndexer.reindex(document)
    :ok
  end

  defp reindex(_), do: :ok
end
