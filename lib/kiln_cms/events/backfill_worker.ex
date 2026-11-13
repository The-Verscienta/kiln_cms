defmodule KilnCMS.Events.BackfillWorker do
  @moduledoc """
  Runs `KilnCMS.Events.Backfill` once after a deploy, without anyone
  remembering to (#766).

  The backfill shipped as a mix task, which meant an upgrade had a manual step —
  and a manual step nobody performs is a feature that silently does not work: the
  "what's on" index stays empty on every site that had events before upgrading.
  `KilnCMS.Application` enqueues this on boot instead.

  ## Why a job rather than work done during boot

  `bin/migrate && bin/server` is the deploy entrypoint, so a backfill run inside
  either would sit in front of HTTP coming up — on a large archive, long enough
  to matter to a container healthcheck. As a job it runs after the node is
  already serving.

  It is also why this is not a data migration: migrations run under
  `bin/kiln_cms eval`, which starts the repo but **not** the application, so the
  recurrence engine's cached type registry has no Cachex to read.

  ## Deduplicated per engine version per day, not "once ever"

  `unique` is a database-level constraint, so a rolling deploy across N replicas
  enqueues one job, not N. A day is the bound on how often a restart loop can
  re-trigger it — deliberately not "once ever", because there is no honest
  once-ever key: the app version does not move on every deploy, and Oban's
  `Pruner` deletes completed jobs after seven days, so any dedup that leaned on
  job history would quietly expire anyway.

  The job's args carry `KilnCMS.Events.Recurrence.engine_version/0`, and the
  dedup is keyed on it. `KilnCMS.Events.Index` treats a stored value as right
  by construction for one engine only, so a release that changes the expansion
  must recompute the archive on its first boot even if an earlier release's job
  completed an hour ago. A new engine always gets its own job; a job from
  before engines were recorded (`args: %{}`) does not block it.

  A redundant run is cheap and safe: `Backfill` writes only rows whose value
  actually changes, so a second pass over a finished site writes nothing at all.
  That also makes this a **repair** pass rather than purely a migration one — a
  value knocked out of sync by a direct database edit is corrected on the next
  boot instead of persisting until someone notices.

  ## Rolling deploys: its own queue, a delay, and a snooze

  A node of the previous release that ran this job would recompute with the
  old engine (writing nothing, since its values equal the stored ones) and
  mark it completed, using up the new engine's run. Three things keep that
  from happening:

    * **The `:occurrence_backfill` queue.** This release is the first to poll
      it, so a node of an older release never fetches the job. A deployment
      that builds Oban's `queues:` itself must add it, or the job waits
      forever.
    * **`schedule_in: 600`.** Old nodes still serving during the rollout
      recompute with the old engine on every editor save and sweep. Running
      the pass ten minutes after boot lets it land after they are gone.
    * **The snooze.** A job whose `"engine"` is newer than this node's engine
      snoozes for five minutes rather than running. That protects every later
      engine bump, once this release is the old one.

  What is left over: an edit saved on an old node after the pass has run keeps
  an old-engine value until a later boot more than a day on, or a manual
  `KilnCMS.Events.Backfill.run/1`.

  ## What it logs

  When the pass writes anything it logs, at `:warning`, how many rows changed
  and how many now have no upcoming date, with the ids of the latter: those
  events left the "what's on" listings, which an engine change can do
  silently.

  `max_attempts: 1`, like `KilnCMS.Events.SweepWorker`: the pass is idempotent
  and interruptible, so a failed run is better replaced by the next one against
  fresher data than replayed. Whatever it did not finish, it finishes next time.
  """
  use Oban.Worker,
    queue: :occurrence_backfill,
    max_attempts: 1,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      keys: [:engine],
      # Every incomplete state (Oban warns, and CI compiles with
      # `--warnings-as-errors`, if any is missing) plus `:completed` — without
      # that last one the dedup would end the moment the job finished, and every
      # subsequent boot would re-run it.
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  require Logger

  alias KilnCMS.Events.Backfill
  alias KilnCMS.Events.Recurrence

  # How long boot waits before the pass, and how long a job for a newer engine
  # waits between looks. See the moduledoc.
  @delay 600
  @snooze 300

  # The most ids one log line names; the count is always exact.
  @logged_ids 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    engine = args["engine"]

    # `is_integer/1` first: a legacy job (`args: %{}`) has no engine, and
    # `nil > 1` is true under Erlang term order, so without it a legacy job
    # would snooze forever instead of running.
    if is_integer(engine) and engine > Recurrence.engine_version() do
      {:snooze, @snooze}
    else
      args |> run() |> log()
      :ok
    end
  end

  defp run(args), do: Backfill.run(all_types: args["all_types"] == true)

  defp log(%{written: 0}), do: :ok

  defp log(result) do
    cleared = length(result.cleared)

    Logger.warning(
      "occurrence backfill (recurrence engine #{Recurrence.engine_version()}): " <>
        "recomputed #{result.written} record(s) of #{result.scanned} scanned; " <>
        "#{cleared} now have no upcoming date and left the what's-on listings" <>
        cleared_ids(result.cleared, cleared)
    )
  end

  defp cleared_ids([], _count), do: ""

  defp cleared_ids(ids, count) when count > @logged_ids,
    do: ": " <> Enum.join(Enum.take(ids, @logged_ids), ", ") <> " and #{count - @logged_ids} more"

  defp cleared_ids(ids, _count), do: ": " <> Enum.join(ids, ", ")

  @doc """
  Queue the post-deploy backfill for this node's recurrence engine, unless one
  is already queued or ran today.

  Called from `KilnCMS.Application` once the supervision tree is up. Never
  raises: a node must not fail to start because a background nicety could not be
  queued, and the next boot tries again.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{"engine" => Recurrence.engine_version()}
         |> new(schedule_in: @delay)
         |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} -> :ok
      {:ok, _job} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  rescue
    error -> log_failure(error)
  end

  defp log_failure(reason) do
    Logger.warning(
      "occurrence backfill not queued: #{inspect(reason)}. " <>
        "Run `mix kiln.occurrences.backfill` if the what's-on index looks empty."
    )

    :ok
  end
end
