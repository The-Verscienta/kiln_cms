defmodule KilnCMS.Firing.Sweep do
  @moduledoc """
  Re-fires **every published document** by enqueueing one `FireWorker` job per
  record (#357, GEO deploy note).

  For deploys that change what firing produces — a new surface (`:llm`), an
  expanded `:json_ld` composition — content published *before* the deploy keeps
  its old artifacts until re-fired. This sweep brings the whole corpus current
  without touching editorial state: no version rows, no `updated_at` churn,
  just fresh artifacts.

  Runs through the normal `:firing` Oban queue, so a large corpus re-fires with
  bounded concurrency and per-document retries, and each job also re-runs the
  reference invalidation + search indexing a real publish would. Firing is
  idempotent (artifacts upsert), so overlapping with in-flight publish jobs is
  harmless.

  Invocation:

      mix kiln.refire_all                                # dev / checkout
      /app/bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()" # prod release (running node)

  Multi-tenancy (epic #336, strict mode #419): reads iterate
  `KilnCMS.Accounts.list_org_ids/0` and run per-tenant — the same pattern as
  the AshOban schedulers — so the sweep covers every site and works under
  strict (`global?: false`) tenancy.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Logger

  alias KilnCMS.Firing.FireWorker

  # The storage tiers with fired artifacts — the same fixed set
  # `KilnCMS.Firing.References` resolves job type strings against.
  @resources [page: KilnCMS.CMS.Page, post: KilnCMS.CMS.Post, entry: KilnCMS.CMS.Entry]

  # Oban.insert_all skips unique checks, so insert in modest chunks to keep
  # any single INSERT bounded; duplicates with in-flight publish jobs are fine.
  @chunk 500

  @doc """
  Enqueue a re-fire for every published document. Returns `%{type => count}`.
  """
  @spec run() :: %{atom() => non_neg_integer()}
  def run do
    counts = Map.new(@resources, fn {type, resource} -> {type, sweep(type, resource)} end)
    total = counts |> Map.values() |> Enum.sum()
    Logger.info("Re-fire sweep enqueued #{total} documents: #{inspect(counts)}")
    counts
  end

  defp sweep(type, resource) do
    KilnCMS.Accounts.list_org_ids()
    |> Enum.map(&sweep_org(type, resource, &1))
    |> Enum.sum()
  end

  defp sweep_org(type, resource, org_id) do
    resource
    |> Ash.Query.filter(state == :published)
    |> Ash.Query.select([:id, :org_id])
    |> Ash.stream!(authorize?: false, tenant: org_id, stream_with: :full_read)
    |> Stream.map(fn record ->
      FireWorker.new(%{"org_id" => record.org_id, "type" => to_string(type), "id" => record.id})
    end)
    |> Stream.chunk_every(@chunk)
    |> Enum.reduce(0, fn jobs, count ->
      Oban.insert_all(jobs)
      count + length(jobs)
    end)
  end

  @doc """
  How many `:firing` jobs are still pending — poll this after `run/0` to watch
  the sweep drain (`0` = done).
  """
  @spec pending() :: non_neg_integer()
  def pending do
    KilnCMS.Repo.aggregate(
      from(j in Oban.Job,
        where: j.queue == "firing" and j.state in ~w(scheduled available executing retryable)
      ),
      :count
    )
  end
end
