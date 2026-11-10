# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
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

  ## Telling delivery consumers (`notify: true`)

  By default the sweep is silent: the artifacts change and nothing is told.
  A headless consumer revalidating by `ETag` sees the new body, but one that
  caches on a webhook does not. `run(notify: true)` (`mix kiln.refire_all
  --notify`) announces each document whose fire completes as
  `<type>.updated` with `"reason" => "refire"` in its payload (#2463) — to the
  webhook endpoints and the public change feed only. Not to automation or
  federation: a re-render is not an edit, and every published document at once
  would run every "on updated" rule and announce the whole site to its
  followers. Not to the CDN purge either, which would fire once per document
  for the length of the sweep; purge once when `pending/0` reaches `0`.

  Multi-tenancy (epic #336, strict mode #419): reads iterate
  `KilnCMS.Accounts.list_org_ids/0` and run per-tenant — the same pattern as
  the AshOban schedulers — so the sweep covers every site and works under
  strict (`global?: false`) tenancy.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Logger

  alias KilnCMS.Firing.FireWorker

  # The storage tiers with fired artifacts — the same set
  # `KilnCMS.Firing.References` resolves job type strings against.
  defp resources, do: KilnCMS.CMS.ContentTypes.blocks_resources()

  # Oban.insert_all skips unique checks, so insert in modest chunks to keep
  # any single INSERT bounded; duplicates with in-flight publish jobs are fine.
  @chunk 500

  @doc """
  Enqueue a re-fire for every published document. Returns `%{type => count}`.

  Options:

    * `:notify` (default `false`) — announce each re-fired document to the
      webhook endpoints and the change feed (see "Telling delivery consumers"
      above).
  """
  @spec run(keyword()) :: %{atom() => non_neg_integer()}
  def run(opts \\ []) do
    args = job_args(Keyword.get(opts, :notify, false))

    counts =
      Map.new(resources(), fn {type, resource} -> {type, sweep(type, resource, args)} end)

    total = counts |> Map.values() |> Enum.sum()
    Logger.info("Re-fire sweep enqueued #{total} documents: #{inspect(counts)}")
    counts
  end

  # A notifying sweep's job says who hears (`FireWorker`). Its own key, not
  # `"refire"`: `KilnCMS.Firing.refire/3` dedupes pending jobs on that flag,
  # and a refire swallowed by a pending sweep job would lose the CDN purge,
  # automation and federation its full announcement owes them.
  defp job_args(true), do: %{"announce" => "delivery"}
  defp job_args(false), do: %{}

  defp sweep(type, resource, args) do
    KilnCMS.Accounts.list_org_ids()
    |> Enum.map(&sweep_org(type, resource, &1, args))
    |> Enum.sum()
  end

  defp sweep_org(type, resource, org_id, args \\ %{}) do
    # authorize?: false — kept deliberately (#1402): converting this to the firing system
    # actor would mean admitting `Checks.SystemActor` on the `Content` read
    # policy — a standing grant over every document on every site, drafts
    # included, to every system caller. That is much wider than this one call.
    # What bounds it instead is the query: one org's tenant, `state ==
    # :published`, and a select of `[:id, :org_id]`, so nothing but ids leaves
    # here and they leave as Oban job args.
    resource
    |> Ash.Query.filter(state == :published)
    |> Ash.Query.select([:id, :org_id])
    |> Ash.stream!(authorize?: false, tenant: org_id, stream_with: :full_read)
    |> Stream.map(fn record ->
      args
      |> Map.merge(%{"org_id" => record.org_id, "type" => to_string(type), "id" => record.id})
      |> FireWorker.new()
    end)
    |> Stream.chunk_every(@chunk)
    |> Enum.reduce(0, fn jobs, count ->
      Oban.insert_all(jobs)
      count + length(jobs)
    end)
  end

  @doc """
  Enqueue a re-fire for every published document of a single type.

  Used when a type's SEO pattern changes (#1135) — only that type's
  documents need new `:json_ld` artifacts, not the whole corpus.
  Bounded via `Oban.insert_all` in `@chunk`-sized inserts, same as `run/1`.
  Silent, like `run/1` without `notify: true`.
  """
  @spec sweep_type(Ash.UUID.t(), String.t() | atom()) :: non_neg_integer()
  def sweep_type(org_id, type_name) when is_binary(type_name) or is_atom(type_name) do
    type_str = to_string(type_name)

    case Enum.find(KilnCMS.CMS.ContentTypes.all(), fn ct -> to_string(ct.type) == type_str end) do
      %{type: type, resource: resource} ->
        sweep_org(type, resource, org_id)

      nil ->
        case KilnCMS.CMS.ContentTypes.dynamic_all(org_id)
             |> Enum.find(fn d -> d.type == type_str end) do
          %{definition: %{id: def_id}} ->
            sweep_dynamic_type(org_id, def_id)

          _ ->
            0
        end
    end
  end

  defp sweep_dynamic_type(org_id, type_definition_id) do
    # authorize?: false — as in `sweep_org/3` above: a system content grant
    # would cover every draft on every site, while this is one tenant,
    # published only, ids only — and one dynamic type narrower.
    KilnCMS.CMS.Entry
    |> Ash.Query.filter(state == :published and type_definition_id == ^type_definition_id)
    |> Ash.Query.select([:id, :org_id])
    |> Ash.stream!(authorize?: false, tenant: org_id, stream_with: :full_read)
    |> Stream.map(fn record ->
      FireWorker.new(%{"org_id" => record.org_id, "type" => "entry", "id" => record.id})
    end)
    |> Stream.chunk_every(@chunk)
    |> Enum.reduce(0, fn jobs, count ->
      Oban.insert_all(jobs)
      count + length(jobs)
    end)
  end

  @doc """
  How many `:firing` jobs are still pending — poll this after `run/1` to watch
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
