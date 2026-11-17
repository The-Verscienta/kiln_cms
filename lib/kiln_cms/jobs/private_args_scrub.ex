defmodule KilnCMS.Jobs.PrivateArgsScrub do
  @moduledoc """
  Drops private job arguments from finished jobs that still hold them (#2992).

  A job of a worker `KilnCMS.Jobs.PrivateArgs` registers drops those keys
  from its own row when it finishes (`KilnCMS.Jobs.PrivateArgs.finishing/3`).
  Some rows keep them anyway:

    * jobs that finished under a release before that, which kept the
      submitted form data, the autoresponder's address, every automation
      event's document snapshot and, before #3019, a workflow or task mail's
      recipient address, title, actor name and excerpt or note, until the
      Pruner deleted the row;
    * a job killed mid-run (past the shutdown grace period, or by its
      timeout), which `Oban.Lifeline` discards hours later
      (`oban_rescue_after_minutes`) without running any of the job's code.

  For every registered worker, this pass drops the registered keys from its
  completed, cancelled and discarded rows. A job still waiting to run keeps
  its args, so it can still do its work. Rows of any other worker are never
  read or written, whatever their args are called.

  ## When it runs

  `KilnCMS.Application` enqueues it on boot, ten minutes out, and the crontab
  runs it daily (`:private_args_scrub_cron`, `KILN_PRIVATE_ARGS_SCRUB_CRON`),
  so a row Lifeline discarded keeps its args until the next run at most.
  Deduplicated for an hour, and idempotent: a scrubbed row no longer matches,
  so a second run changes nothing. `config :kiln_cms,
  :private_args_scrub_on_boot, false` turns the boot enqueue off (the test and
  e2e builds do); by hand:

      bin/kiln_cms eval 'KilnCMS.Release.scrub_job_args()'
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 3600,
      fields: [:worker],
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.Jobs.PrivateArgs

  @finished ~w(completed cancelled discarded)

  @typedoc "How many finished rows of each registered worker had keys dropped."
  @type result :: %{String.t() => non_neg_integer()}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = run()
    total = result |> Map.values() |> Enum.sum()
    if total > 0, do: Logger.info("job args scrub: #{inspect(result)}")
    :ok
  end

  @doc "Scrub every registered worker's finished jobs through `repo`; see the moduledoc."
  @spec run(Ecto.Repo.t()) :: result()
  def run(repo \\ KilnCMS.Repo) do
    Map.new(PrivateArgs.registry(), fn {worker, keys} -> {worker, scrub(repo, worker, keys)} end)
  end

  defp scrub(repo, worker, keys) do
    {count, _rows} =
      from(j in Oban.Job,
        where:
          j.worker == ^worker and j.state in ^@finished and
            fragment("jsonb_exists_any(?, ?::text[])", j.args, ^keys),
        update: [set: [args: fragment("? - ?::text[]", j.args, ^keys)]]
      )
      |> repo.update_all([])

    count
  end

  @doc """
  Queue a run ten minutes out, unless one is queued or ran within the hour.
  Never raises: a node must not fail to start because this could not be queued.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{} |> new(schedule_in: 600) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  rescue
    error -> log_failure(error)
  end

  defp log_failure(reason) do
    Logger.warning("job args scrub not queued: #{inspect(reason)}")
    :ok
  end
end
