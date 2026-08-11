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
  to matter to a container healthcheck. As a job it runs on the `:default` queue
  after the node is already serving.

  It is also why this is not a data migration: migrations run under
  `bin/kiln_cms eval`, which starts the repo but **not** the application, so the
  recurrence engine's cached type registry has no Cachex to read.

  ## Deduplicated for a day, not "once ever"

  `unique` is a database-level constraint, so a rolling deploy across N replicas
  enqueues one job, not N. A day is the bound on how often a restart loop can
  re-trigger it — deliberately not "once ever", because there is no honest
  once-ever key: the app version does not move on every deploy, and Oban's
  `Pruner` deletes completed jobs after seven days, so any dedup that leaned on
  job history would quietly expire anyway.

  A redundant run is cheap and safe: `Backfill` writes only rows whose value
  actually changes, so a second pass over a finished site writes nothing at all.
  That also makes this a **repair** pass rather than purely a migration one — a
  value knocked out of sync by a restore or a direct database edit is corrected
  on the next boot instead of persisting until someone notices.

  `max_attempts: 1`, like `KilnCMS.Events.SweepWorker`: the pass is idempotent
  and interruptible, so a failed run is better replaced by the next one against
  fresher data than replayed. Whatever it did not finish, it finishes next time.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      period: 86_400,
      fields: [:worker],
      # Every incomplete state (Oban warns, and CI compiles with
      # `--warnings-as-errors`, if any is missing) plus `:completed` — without
      # that last one the dedup would end the moment the job finished, and every
      # subsequent boot would re-run it.
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  require Logger

  alias KilnCMS.Events.Backfill

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    result = Backfill.run(all_types: args["all_types"] == true)

    if result.written > 0 do
      Logger.info(
        "occurrence backfill: filled #{result.written} record(s) of #{result.scanned} scanned"
      )
    end

    :ok
  end

  @doc """
  Queue the post-deploy backfill, unless one is already queued or ran today.

  Called from `KilnCMS.Application` once the supervision tree is up. Never
  raises: a node must not fail to start because a background nicety could not be
  queued, and the next boot tries again.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{} |> new() |> Oban.insert() do
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
