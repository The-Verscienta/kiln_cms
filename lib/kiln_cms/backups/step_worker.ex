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
  over. `start` runs anywhere: the chain is bound to the directory its `start`
  wrote `state.json` to only when it hands over (`Chain.begin_step/1`).

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

  defp affinity(%Oban.Job{args: %{"step" => "start"}}), do: :ok

  defp affinity(%Oban.Job{args: %{"dir" => dir_id}} = job) do
    cond do
      DirId.current() == {:ok, dir_id} ->
        rebase_snoozes(job)

      snoozes_this_attempt(job) < @affinity_max_snoozes ->
        {:snooze, @affinity_snooze_s}

      true ->
        rebase_snoozes(job)
        {:error, :backup_dir_elsewhere}
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
