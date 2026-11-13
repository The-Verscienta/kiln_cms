defmodule KilnCMS.Backups.Scheduler do
  @moduledoc """
  Runs the in-app backup schedules (part of #2219,
  `KilnCMS.Backups.Schedule`).

  One static Oban cron entry (`KILN_BACKUP_SCHEDULER_CRON`, every minute by
  default, `false` turns it off) runs `tick/1`: it reads the enabled
  schedules, keeps those whose window is due (`KilnCMS.Backups.Schedule.Window`)
  and asks for one backup covering all of them
  (`KilnCMS.Backups.request_scheduled/3`), which claims each window in the
  lock transaction. The claim is the guarantee that a window fires once,
  across nodes and deploys; the job's `unique` is only a damper.

  ## What it does not do

    * **No backfill.** Only a schedule's latest window fires; windows skipped
      while nothing ticked (downtime) are logged as missed.
    * **No retry within a window.** A backup that fails after its window was
      claimed is not asked for again; the next window fires.
    * **No marker sync.** `KilnCMS.Backups.MarkerSyncWorker` has its own
      entry.

  ## What it logs

  Every outcome is a telemetry event,
  `[:kiln_cms, :backups, :schedule, event]` with `%{count: n}`, where `event`
  is `:fired`, `:deferred`, `:refused`, `:narrowed`, `:missed`, `:invalid` or
  `:unreadable`. A fired backup is logged at info. A window that waits behind
  a queued Resume (#2540) is logged once per window (the schedule row records
  that it was), though it is asked for again every minute, and so is one this
  node can't run (no `pg_dump`, `pg_restore` or database URL here: another
  node may take it); a refused window once (it is claimed as refused). An invalid schedule is logged at most once
  an hour per schedule on this node, an unreadable schedule list at most once
  every 15 minutes.

  ## Rolling deploys

  A node from before this module fetching the job fails it as an unknown
  worker, and the job is discarded. A window stays due until the next one, so
  a newer node's tick fires it.
  """
  use Oban.Worker,
    queue: :scheduling,
    max_attempts: 1,
    unique: [period: 50, states: [:available, :scheduled, :executing]]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Schedule.Window

  require Ash.Query
  require Logger

  @unreadable_warned {__MODULE__, :unreadable_warned_at}
  @unreadable_warn_every_ms :timer.minutes(15)
  @invalid_warn_every_ms :timer.hours(1)

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: tick(DateTime.utc_now())

  @doc """
  Whether the scheduler runs on this deployment: `KILN_BACKUP_SCHEDULER_CRON`
  resolves to a cron expression (not `false`, blank or unparseable). Silent;
  the boot warns about an unparseable value.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: KilnCMS.Application.cron_expression(:backup_scheduler_cron) != nil

  @doc """
  One tick at `now` (the node clock): what the cron job runs, public for a
  release console and for tests. Always `:ok`; what happened is logged and
  reported as telemetry.
  """
  @spec tick(DateTime.t()) :: :ok
  def tick(%DateTime{} = now) do
    with {:ok, schedules} <- read_enabled(),
         {[_ | _] = due, _invalid} <- due(schedules, now) do
      case Backups.request_scheduled(due, now, Backups.system()) do
        {:ok, result} ->
          report(result)

        {:error, reason} ->
          Logger.warning("Scheduled backups were not asked for: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp read_enabled do
    query = Backups.Schedule |> Ash.Query.filter(enabled == true) |> Ash.Query.sort(id: :asc)

    case Backups.list_backup_schedules(
           query: query,
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, schedules} ->
        {:ok, schedules}

      {:error, error} ->
        unreadable(error)
        :unreadable
    end
  end

  # The ids due now, in id order, and the invalid ones (reported here; the
  # request never sees them).
  defp due(schedules, now) do
    {due, invalid} =
      Enum.reduce(schedules, {[], []}, fn s, {due, invalid} ->
        case safe_due(s, now) do
          {:ok, %DateTime{}} -> {[s.id | due], invalid}
          {:ok, nil} -> {due, invalid}
          {:error, :invalid} -> {due, [s.id | invalid]}
        end
      end)

    Enum.each(invalid, &invalid/1)
    {Enum.reverse(due), invalid}
  end

  defp safe_due(s, now) do
    Window.due(s, now)
  rescue
    _error -> {:error, :invalid}
  end

  defp report(%{status: status} = result) when status in [:started, :queued, :folded] do
    ids = Enum.map(result.claimed, &elem(&1, 0))

    Logger.info(
      "Scheduled backup #{status} (#{length(ids)} schedule(s)#{chain_text(result.chain)})"
    )

    event(:fired, length(ids), %{status: status, schedule_ids: ids, chain: result.chain})

    for id <- result.narrowed do
      Logger.warning(
        "Scheduled backup #{id} covers the media, but this node has no media directory " <>
          "configured (MEDIA_DIR): only the database is backed up"
      )
    end

    event(:narrowed, length(result.narrowed), %{schedule_ids: result.narrowed})

    for id <- result.missed do
      Logger.warning(
        "Scheduled backup #{id} missed earlier windows (nothing ran the scheduler): " <>
          "only the latest one runs"
      )
    end

    event(:missed, length(result.missed), %{schedule_ids: result.missed})
    report_refused(result.refused)
  end

  defp report(%{status: :deferred} = result) do
    for {id, _w, reason, true} <- result.deferred do
      Logger.warning("Scheduled backup #{id} waits: #{waits(reason)}")
    end

    event(:deferred, length(result.deferred), %{
      schedule_ids: Enum.map(result.deferred, &elem(&1, 0))
    })

    report_refused(result.refused)
  end

  defp report(result), do: report_refused(result.refused)

  defp report_refused(refused) do
    for {id, _w, reason, true} <- refused do
      Logger.warning("Scheduled backup #{id} can't run here: #{refused_text(reason)}")
    end

    event(:refused, length(refused), %{schedule_ids: Enum.map(refused, &elem(&1, 0))})
  end

  defp waits({:queue_busy, {:resume, stamp}}) do
    "a resume of #{stamp} is queued; it is asked for again each minute until the queue clears"
  end

  defp waits(reason) when reason in [:no_database_url, :no_pg_dump, :no_pg_restore] do
    "#{inspect(reason)} on this node; it is asked for again each minute, and a node " <>
      "that can run backups takes it"
  end

  defp waits(reason),
    do: "#{inspect(reason)}; it is asked for again each minute until it can start"

  defp refused_text(:no_media_dir),
    do: ":no_media_dir (this node has no media directory configured, MEDIA_DIR)"

  defp refused_text(reason), do: inspect(reason)

  defp chain_text(nil), do: ""
  defp chain_text(chain), do: ", chain #{chain}"

  defp event(_name, 0, _metadata), do: :ok

  defp event(name, count, metadata) do
    :telemetry.execute([:kiln_cms, :backups, :schedule, name], %{count: count}, metadata)
  end

  defp invalid(id) do
    event(:invalid, 1, %{schedule_ids: [id]})

    if warn_due?({__MODULE__, :invalid_warned_at, id}, @invalid_warn_every_ms) do
      Logger.warning(
        "Backup schedule #{id} is skipped: its window can't be computed (an interval, " <>
          "time zone or component this release doesn't know)"
      )
    end
  end

  defp unreadable(error) do
    event(:unreadable, 1, %{error: error.__struct__})

    if warn_due?(@unreadable_warned, @unreadable_warn_every_ms) do
      Logger.warning(
        "Backup schedules were not checked: they could not be read " <>
          "(#{inspect(error.__struct__)})"
      )
    end
  end

  # At most one warning per `every_ms` per key on this node.
  defp warn_due?(key, every_ms) do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(key, nil)

    if is_nil(last) or now - last >= every_ms do
      :persistent_term.put(key, now)
      true
    else
      false
    end
  end
end
