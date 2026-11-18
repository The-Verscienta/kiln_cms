defmodule KilnCMS.Backups.StepWorker do
  @moduledoc """
  One step of a backup's chain (#2218): `start`, `dump`, `plan`, `archive`
  (one job per media part), `checksum`, `prune`, `offsite`, `finish`. The
  bodies are `KilnCMS.Backups.Steps`; the lock and the order between steps are
  `KilnCMS.Backups.Chain`.

  ## Its own queue

  `:backup_steps`, not the `:backups` queue the single-job `Worker` used: an
  older node mid-deploy does not know this module, and a job of it on a queue
  that node runs would fail there with Oban's default backoff. Concurrency one
  per node; the lock makes it one per cluster.

  ## Attempts

  Four, with a fixed 1/5/15-minute backoff between them (D3). A step that was
  reclaimed from a stopped node is requeued with the attempts it had left
  (`max_attempts` lowered), and its backoff continues from where the old job's
  stopped rather than starting over. The last attempt's failure fails the
  backup (`Steps`).

  ## Which node

  Every step after `start` must run where the chain's files are: a node whose
  `<BACKUP_DIR>/.kiln-dir-id` (`KilnCMS.Backups.DirId`) is not the chain's
  snoozes (30 s, which costs no attempt) up to 20 times per attempt, about ten
  minutes, then fails the attempt so the backoff and the attempt budget take
  over. A fresh backup's `start` runs anywhere: the chain is bound to the
  directory its `start` wrote `state.json` to only when it hands over
  (`Chain.begin_step/1`).

  A resume's `start` runs where the run's files are (#2539, #2817), in this
  order:

  1. On the node whose directory id is the one the run records
     (`KilnCMS.Backups.Run`'s `dir_id`), files or not: the start step there
     refuses visibly when `.work/<stamp>/state.json` is gone (`:no_state`).
  2. On a node with a readable `.work/<stamp>/state.json` of its own, only
     when no live node reports the recorded id: none has beaten within
     `Chain.stale_after_s/0` (180 s, the lock's own stale threshold) with that
     id. A copied or rebuilt backup directory (a new `.kiln-dir-id`) resumes
     once the source host has stopped, not while it runs. A `state.json` that
     can't be parsed is no match, and heartbeats that can't be read count as
     a live source: the start waits, with a warning in the log.
  3. Anywhere else it snoozes with the same budget as the other steps.

  When the last attempt has used its budget too, the resume is given up
  (`Chain.abandon_start/2`): the lock is released, the waiting request
  promoted, and the run's row says why. A run with no directory id
  (imported, from before #2539) runs anywhere. A start whose run can't be
  read runs on a node without the files (the start step there refuses
  visibly) and waits, with the same budget, on one with them. The 180 s
  window is the lock's, not the last-good marker sync's 600 s routing window
  (`KilnCMS.Backups.MarkerSyncWorker`).

  Oban counts a job's snoozes in `meta["snoozed"]` across all its attempts. The
  per-attempt count is the snoozes since `meta["affinity_base"]`, which is
  moved up to `snoozed` when an attempt gets past the check after snoozing, and
  when it gives up (Oban's error ack leaves `meta` alone, its snooze ack
  rewrites it from the fetched job, so nothing is written on a snooze).

  Args hold ids only: `chain`, `step`, `part`, `stamp`, `dir`, `trigger`,
  `resume` (and on a promoted start, `folded` and `requested_at`). Everything
  else is in `.work/<stamp>/state.json`.

  ## Uniqueness

  One job per chain, step and part in any live or completed state; a canceled
  or discarded one does not count, so a reclaimed step's replacement can be
  inserted.
  """
  use Oban.Worker,
    queue: :backup_steps,
    max_attempts: 4,
    unique: [
      keys: [:chain, :step, :part],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :completed, :suspended]
    ]

  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId, Steps}

  require Logger

  @max_attempts 4
  @backoff_s [60, 300, 900]
  @affinity_snooze_s 30
  @affinity_max_snoozes 20

  @doc "Each step's ceiling, enforced by Oban: the longest a dump or a part may take."
  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(2)

  @doc """
  1, 5, then 15 minutes. Indexed by how many of the chain's four attempts this
  step has used, so a reclaimed step's replacement (fewer `max_attempts`)
  carries on with the schedule.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt, max_attempts: max}) do
    index = @max_attempts - max + attempt - 1
    Enum.at(@backoff_s, index |> max(0) |> min(length(@backoff_s) - 1))
  end

  @doc "The fixed attempt budget of a step."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with :ok <- affinity(job) do
      # `:duplicate` keys: a test drains every step in one process. The
      # heartbeat kills what is registered here: every step on its self-fence,
      # and a step whose job is canceled or otherwise over, by the job id
      # (#2538). Unregistered on the way out, so a step that returned is never
      # seen with its job already acked.
      value = {args["step"], job.id}
      {:ok, _} = Registry.register(KilnCMS.Backups.StepRegistry, args["chain"], value)

      try do
        case Chain.begin_step(job) do
          {:ok, lease} -> run(lease, job)
          {:error, :superseded} -> {:cancel, :superseded}
          {:error, reason} -> {:error, reason}
        end
      after
        Registry.unregister_match(KilnCMS.Backups.StepRegistry, args["chain"], value)
      end
    end
  end

  # A raise is a failure like any other: retried, and terminal on the last
  # attempt (the boundary is the step, so the lock is released and the run
  # closed rather than left for the reaper).
  defp run(lease, job) do
    Steps.perform(lease, job)
  rescue
    error ->
      Logger.error(
        "Backup step #{lease.step} crashed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      Steps.crashed(lease, job, {:crashed, Exception.message(error)})
  end

  # A resume's start (#2539, #2817): the node whose directory the run records,
  # then local files that no live node's directory id claims. A run with no
  # id isn't pinned. A legacy `Worker` job's
  # snoozes (`Steps`) also count in `meta["snoozed"]`, so they can spend this
  # budget: that needs a node from before #2218 still running next to a run
  # pinned by #2539, and the outcome is a visible refusal.
  defp affinity(%Oban.Job{args: %{"step" => "start", "resume" => stamp}} = job)
       when is_binary(stamp) do
    case Backups.resume_dir_id(stamp) do
      {:ok, nil} ->
        :ok

      {:ok, dir_id} ->
        resume_dir(job, stamp, dir_id)

      {:error, error} ->
        run_unreadable(job, stamp, error)
    end
  end

  defp affinity(%Oban.Job{args: %{"step" => "start"}}), do: :ok

  defp affinity(%Oban.Job{args: %{"dir" => dir_id}} = job),
    do: pinned(job, dir_id, fn -> {:error, :backup_dir_elsewhere} end)

  # The heartbeats are read only when there are files here to win with.
  defp resume_dir(job, stamp, dir_id) do
    cond do
      DirId.current() == {:ok, dir_id} ->
        rebase_snoozes(job)

      Backups.local_resume_state?(stamp) and not source_live?(stamp, dir_id) ->
        rebase_snoozes(job)

      true ->
        pinned(job, dir_id, fn -> Chain.abandon_start(job, {:backup_dir_elsewhere, dir_id}) end)
    end
  end

  # Whether a node that beat within the lock's stale threshold reports the
  # run's directory. Fails closed: heartbeats that can't be read count as a
  # live source, so the start waits (and the budget bounds the wait).
  defp source_live?(stamp, dir_id) do
    case Backups.dir_id_live?(dir_id, Chain.stale_after_s()) do
      {:ok, live?} ->
        live?

      {:error, error} ->
        Logger.warning(
          "Backup resume of #{stamp}: couldn't read the node heartbeats " <>
            "(#{describe(error)}); waiting for the server with its backup directory " <>
            "(id #{dir_id}) rather than resuming from the files here"
        )

        true
    end
  end

  # The run can't be read, so neither can the directory it records. With
  # files here the start waits, like a live source (a copy must not win on a
  # database blip). With none it starts here: the start step reads the files
  # first and refuses visibly (`:no_state`) when they are missing.
  defp run_unreadable(job, stamp, error) do
    if Backups.local_resume_state?(stamp) do
      Logger.warning(
        "Backup resume of #{stamp}: couldn't read where its files are " <>
          "(#{inspect(error, limit: 5)}); waiting rather than resuming from the files here"
      )

      wait(job, :run_unreadable, fn -> {:error, :run_unreadable} end)
    else
      Logger.warning(
        "Backup resume of #{stamp}: couldn't read where its files are " <>
          "(#{inspect(error, limit: 5)}); starting it here"
      )

      :ok
    end
  end

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error, limit: 5)

  # Runs here, snoozes, or (budget spent) fails the attempt. A resume's start
  # gives up on its last attempt (`give_up`); every other step's last attempt
  # fails like any other, and the reaper closes the chain.
  defp pinned(job, dir_id, give_up) do
    if DirId.current() == {:ok, dir_id},
      do: rebase_snoozes(job),
      else: wait(job, :backup_dir_elsewhere, give_up)
  end

  # Snoozes, or (budget spent) fails the attempt with `reason`, or on the
  # last attempt gives up.
  defp wait(job, reason, give_up) do
    cond do
      snoozes_this_attempt(job) < @affinity_max_snoozes ->
        {:snooze, @affinity_snooze_s}

      job.attempt < job.max_attempts ->
        rebase_snoozes(job)
        {:error, reason}

      true ->
        rebase_snoozes(job)
        give_up.()
    end
  end

  defp snoozes_this_attempt(%Oban.Job{meta: meta}),
    do: (meta["snoozed"] || 0) - (meta["affinity_base"] || 0)

  # The next attempt counts its snoozes from here. Only when this attempt
  # snoozed (no write on the common path) and only for a stored job.
  defp rebase_snoozes(%Oban.Job{id: id, meta: meta} = job) do
    if is_integer(id) and snoozes_this_attempt(job) > 0 do
      base = %{"affinity_base" => meta["snoozed"]}

      KilnCMS.Repo.update_all(
        from(j in Oban.Job,
          where: j.id == ^id,
          update: [set: [meta: fragment("? || ?", j.meta, type(^base, :map))]]
        ),
        []
      )
    end

    :ok
  end
end
