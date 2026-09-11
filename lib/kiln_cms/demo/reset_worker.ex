defmodule KilnCMS.Demo.ResetWorker do
  @moduledoc """
  The scheduled demo reset — `KILN_DEMO_RESET_CRON` enqueues this. See
  `KilnCMS.Demo` and `docs/demo-mode.md`.

  ## Its own queue

  `:demo`, one worker, started only when demo mode is on
  (`KilnCMS.Application`). The reset pauses every queue before it restores, and
  a job cannot usefully wait behind the thing that paused it.

  ## A refusal is a cancel, a failure is an error

  A reset that refused — demo mode off, no golden snapshot yet, a database that
  doesn't look like a demo — is `{:cancel, reason}`: retrying changes nothing,
  and the next scheduled run re-checks anyway. A reset that *tried* and failed
  is `{:error, reason}`, which is what an operator should be alerted on.
  `max_attempts: 1` either way: the schedule is the retry.

  The job's own row does not survive a successful reset — `oban_jobs` is one of
  the tables the restore empties — so Oban's completion update touches nothing.
  The log line and the returned summary are the record.
  """
  use Oban.Worker,
    queue: :demo,
    max_attempts: 1,
    unique: [period: 300, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) do
    case KilnCMS.Demo.reset(job_id: id) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        message = KilnCMS.Demo.explain(reason)

        if KilnCMS.Demo.refusal?(reason) do
          Logger.warning("Demo reset refused: #{message}")
          {:cancel, message}
        else
          Logger.error("Demo reset FAILED: #{message}")
          {:error, message}
        end
    end
  end
end
