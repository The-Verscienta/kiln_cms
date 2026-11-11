defmodule KilnCMS.Backups.Worker do
  @moduledoc """
  The single-job backup worker of releases before #2218, kept as a shim.

  A backup is now a chain of `KilnCMS.Backups.StepWorker` jobs behind a
  cluster-wide lock (`KilnCMS.Backups.Chain`); every way of starting one goes
  through `KilnCMS.Backups.request/2`. What is left here:

    * `perform/1`, so a job an older node enqueued on the `:backups` queue
      before the upgrade still starts a backup — through the lock, as a request.
    * `run/3`, the release-console entry point (deprecated): it requests a
      backup and waits for its chain to settle; it no longer runs one inline.
    * Delegates to `KilnCMS.Backups.Steps` for the functions other modules and
      tests call by this name (`split_credentials/1` from `KilnCMS.Demo.Restore`).

  The `:backups` queue and this module go in the next minor release; drain the
  queue before upgrading to it.
  """
  use Oban.Worker,
    queue: :backups,
    # `:incomplete` rather than an explicit state list: naming states by hand
    # omits `:retryable` and `:suspended`, and a "unique" job that a suspended
    # twin doesn't block is not unique.
    unique: [period: 300, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Steps

  require Logger

  @doc """
  Ceiling on a legacy job, enforced by Oban. It only makes a request now, so it
  never comes near; kept at the old value, which `Oban.Lifeline`'s rescue
  window is sized against.
  """
  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(2)

  # A refusal is final (`{:cancel, reason}`): retrying a request the lock or
  # `resumable_run/2` refused would only refuse again. Except a queue holding a
  # request of another kind (#2540): that clears, so the job waits a minute and
  # asks again (logged on the first wait only).
  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    opts = [trigger: Map.get(args, "trigger", "manual")]
    # `Map.has_key?`, not a nil check: a job whose `resume` is present but
    # mangled must be refused, never quietly become a fresh backup.
    opts = if Map.has_key?(args, "resume"), do: [{:resume, args["resume"]} | opts], else: opts

    case Backups.request(opts, Backups.system()) do
      {:ok, %{status: status}} ->
        Logger.info("Legacy backup job handed to the step chain: #{status}")
        :ok

      {:error, {:queue_busy, queued}} ->
        if is_nil((job.meta || %{})["snoozed"]),
          do: Logger.info("Legacy backup job waits: #{inspect(queued)} is queued; asking again")

        {:snooze, 60}

      {:error, reason} ->
        Logger.warning("Legacy backup job refused: #{inspect(reason)}")
        {:cancel, reason}
    end
  end

  @doc """
  Request a backup and wait for it (deprecated: use `KilnCMS.Backups.request/2`).

  Returns `:ok` when the chain succeeds, `{:error, reason}` when it fails or is
  refused (see `KilnCMS.Backups.await/2`), and `{:error, :queued}` or
  `{:error, :folded}` when another backup is running: the request waits behind
  it and this call does not; `{:error, {:queue_busy, queued}}` when a request
  of another kind is queued (nothing waits; ask again once it clears).
  `job_id` is ignored. `resume: stamp` resumes that
  failed, interrupted or canceled backup, as `Backups.request/2` does.

  `:timeout` (default 3 hours) bounds the wait, not the backup; `:interval` is
  how often it looks (`Backups.await/2`).
  """
  @spec run(String.t(), integer() | nil, keyword()) :: :ok | {:error, term()}
  def run(trigger, _job_id \\ nil, opts \\ []) do
    {wait, opts} = Keyword.split(opts, [:timeout, :interval])

    case Backups.request(Keyword.put(opts, :trigger, trigger), Backups.system()) do
      {:ok, %{status: :started, chain: chain}} -> Backups.await(chain, wait)
      {:ok, %{status: status}} -> {:error, status}
      {:error, _} = error -> error
    end
  end

  @doc false
  defdelegate offsite_step(dir, artifacts, rec), to: Steps
  @doc false
  defdelegate offsite_results(dir, artifacts), to: Steps
  @doc false
  defdelegate describe_offsite(reason, resumable?), to: Steps
  @doc "See `KilnCMS.Backups.Steps.copy_offsite/2`."
  defdelegate copy_offsite(dir, artifacts), to: Steps
  @doc false
  defdelegate sweep_work_dirs(dir), to: Steps
  @doc false
  defdelegate sweep_work_dirs(dir, now), to: Steps
  @doc "See `KilnCMS.Backups.Steps.split_credentials/1`."
  defdelegate split_credentials(url), to: Steps
end
