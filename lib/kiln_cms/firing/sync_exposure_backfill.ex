defmodule KilnCMS.Firing.SyncExposureBackfill do
  @moduledoc """
  Records a `KilnCMS.Firing.SyncExposure` for every document that is public
  right now, in every site (#2275).

  The change feed's publisher records an exposure for each public document it
  shows an anonymous `GET /api/feed` stream, so a later withdrawal may name
  it. A document published before the feed started doing so, and never served
  by `GET /api/sync`, has none: its unpublish or move to a members audience
  would be hidden from the feed (a withdrawal may name only a disclosed id),
  and an anonymous mirror fed by the stream would keep it. Recording the ids
  that are public now closes that gap, and is safe for the reason any
  exposure is: each one is a document an anonymous reader can fetch at this
  moment.

  The walk is the sync API's own initial snapshot (`KilnCMS.Firing.Sync.page/4`
  with `bodies: false`), which records what it serves exactly as a real
  `initial=true` sync does — same visibility rule, same skip of ids already
  recorded — and reads no artifact.

  ## When it runs

  `KilnCMS.Application` enqueues it on boot, as `KilnCMS.Events.BackfillWorker`
  does for the occurrence index (the same reasons: no manual upgrade step, and
  no work in front of HTTP coming up). Deduplicated for a day at the database
  level, so replicas queue one job between them; a redundant run writes nothing
  new. `config :kiln_cms, :sync_exposure_backfill_on_boot, false` turns the boot
  enqueue off (the test and e2e builds do); `run/0` runs it by hand, e.g.
  `bin/kiln_cms rpc "KilnCMS.Firing.SyncExposureBackfill.run()"`.

  `max_attempts: 1`: the pass is idempotent, so a failed run is better replaced
  by the next one than replayed.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      period: 86_400,
      fields: [:worker],
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  require Logger

  alias KilnCMS.Firing.Sync

  @page 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    run()
    :ok
  end

  @doc """
  Walk every site's public documents and record each one's exposure. Returns
  how many documents were walked, per site.
  """
  @spec run() :: %{Ash.UUID.t() => non_neg_integer() | :unavailable}
  def run do
    Map.new(KilnCMS.Accounts.list_org_ids(), &{&1, run_org(&1)})
  end

  @doc "Walk one site's public documents (see `run/0`)."
  @spec run_org(Ash.UUID.t()) :: non_neg_integer() | :unavailable
  def run_org(org_id), do: walk(org_id, Sync.start(), 0)

  defp walk(org_id, position, seen) do
    case Sync.page(org_id, nil, position, limit: @page, bodies: false, commit_lag: 0) do
      {:ok, items, next, true} ->
        walk(org_id, next, seen + length(items))

      {:ok, items, _next, false} ->
        seen + length(items)

      :unavailable ->
        Logger.warning("sync exposure backfill: site #{org_id} unavailable, left for next boot")
        :unavailable
    end
  end

  @doc """
  Queue the backfill, unless one is already queued or ran today. Never raises:
  a node must not fail to start because this could not be queued.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{} |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  rescue
    error -> log_failure(error)
  end

  defp log_failure(reason) do
    Logger.warning("sync exposure backfill not queued: #{inspect(reason)}")
    :ok
  end
end
