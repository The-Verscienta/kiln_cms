defmodule KilnCMS.Media.StagedUploadClaim do
  @moduledoc """
  The lease a direct-upload completion holds on its staged object (#2724), so
  that `KilnCMS.Media.StagedUploadCleanup` cannot delete the object while
  `KilnCMS.Media.DirectUpload.complete/4` is still reading it.

  There is no table of staged uploads. The lease is the cleanup job's own
  `oban_jobs` row, queued by `DirectUpload.begin/3`: a job runs only once
  Oban's stager finds it `scheduled` with `scheduled_at` in the past and moves
  it to `available`, and a producer only fetches `available` jobs. So holding
  the job's `scheduled_at` in the future holds off the delete.

    * `claim/1` takes the lease: one `UPDATE` of the job row that is still
      `scheduled` and carries no claim, pushing `scheduled_at` out by the
      lease and recording the claim id and the original `scheduled_at` in the
      job's `meta`. Exactly one caller wins. No row means there is nothing to
      complete: the job already ran (the token is spent or expired), another
      completion holds the claim, an earlier completion consumed the token, or
      the job was never queued.
    * `start_heartbeat/1` renews the lease every `heartbeat_ms` for as long as
      the completion runs: the copy down, the metadata strip, the variants
      and the create. A renewal that matches no row means the lease was lost
      (the job is running or ran); the completion sees that with `lost?/1`
      and gives up with `:claim_lost`. The heartbeat is linked to the
      completion, so a completion that dies stops renewing, the lease lapses,
      and the job deletes the object.
    * `settle/2` ends it. A consumed upload (the object was found and the
      completion deleted it) leaves the claim in place, so the token stays
      spent, and makes the job due now so it runs, deletes again (a no-op, or
      the retry of a delete that failed) and finishes. An upload that was not
      consumed (completed before the client's `PUT` landed, or its store
      could not be reached) drops the claim and restores the original
      `scheduled_at`, so the token can still be completed.

  Every statement is a compare-and-set on the job's state and the claim id,
  and every time is the database's clock, so no node's clock decides who
  holds the lease. It is `clock_timestamp()` rather than `now()`, which is
  the start of the enclosing transaction: the same in production, where each
  statement is its own transaction, but a lease renewed inside a transaction
  (every test runs in one) would otherwise never move. Oban's stager compares `scheduled_at` with its own node's
  clock; the margin between a renewal and the lease's end (by default four
  minutes) absorbs any skew between the two.

  `lease_ms` (default 300 000) and `heartbeat_ms` (default 60 000) are read
  from `config :kiln_cms, #{inspect(__MODULE__)}`, so tests can shorten them.
  """

  alias KilnCMS.Media.StagedUploadCleanup
  alias KilnCMS.Repo

  require Logger

  @default_lease_ms 300_000
  @default_heartbeat_ms 60_000

  @typedoc "A held claim: the staging key and the claim's own id."
  @type t :: %{key: String.t(), id: String.t()}

  @typedoc "A running heartbeat: its process and the flag it raises on a lost claim."
  @type heartbeat :: %{pid: pid(), lost: :atomics.atomics_ref()}

  # Every statement addresses the cleanup job by its worker and the staging
  # key in its args, which the `oban_jobs` GIN index on `args` serves.
  @job "worker = $1 AND args @> $2 AND state = 'scheduled'"

  @claim_sql """
  UPDATE oban_jobs
  SET scheduled_at = timezone('UTC', clock_timestamp()) + $3::integer * interval '1 millisecond',
      meta = meta || jsonb_build_object('claim', $4::text, 'claim_scheduled_at', scheduled_at)
  WHERE #{@job} AND NOT jsonb_exists(meta, 'claim')
  """

  @renew_sql """
  UPDATE oban_jobs
  SET scheduled_at = timezone('UTC', clock_timestamp()) + $4::integer * interval '1 millisecond'
  WHERE #{@job} AND meta->>'claim' = $3
  """

  @consumed_sql """
  UPDATE oban_jobs
  SET scheduled_at = timezone('UTC', clock_timestamp())
  WHERE #{@job} AND meta->>'claim' = $3
  """

  @unconsumed_sql """
  UPDATE oban_jobs
  SET scheduled_at = (meta->>'claim_scheduled_at')::timestamp,
      meta = meta - 'claim' - 'claim_scheduled_at'
  WHERE #{@job} AND meta->>'claim' = $3
  """

  @doc """
  Take the lease on `key`'s cleanup job. `{:ok, claim}`, or
  `{:error, :not_uploaded}` when no unclaimed, still-scheduled job exists.
  """
  @spec claim(String.t()) :: {:ok, t()} | {:error, :not_uploaded}
  def claim(key) when is_binary(key) do
    id = Ecto.UUID.generate()

    case Repo.query!(@claim_sql, job_params(key) ++ [lease_ms(), id]) do
      %{num_rows: 0} -> {:error, :not_uploaded}
      %{num_rows: _} -> {:ok, %{key: key, id: id}}
    end
  end

  @doc """
  Renew the lease. `:ok`, `:lost` when the claim no longer holds the job, or
  `{:error, reason}` when the database could not be asked (a missed beat,
  not a lost claim: the lease outlasts several).
  """
  @spec renew(t()) :: :ok | :lost | {:error, term()}
  def renew(claim) do
    case Repo.query(@renew_sql, claim_params(claim) ++ [lease_ms()]) do
      {:ok, %{num_rows: 0}} -> :lost
      {:ok, %{num_rows: _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Start renewing `claim` every `heartbeat_ms`, in a process linked to the
  caller. Stop it with `stop_heartbeat/1` before `settle/2`.
  """
  @spec start_heartbeat(t()) :: heartbeat()
  def start_heartbeat(claim) do
    lost = :atomics.new(1, [])
    interval = heartbeat_ms()
    {:ok, pid} = Task.start_link(fn -> beat(claim, interval, lost) end)
    %{pid: pid, lost: lost}
  end

  @doc "Whether the heartbeat found the claim lost."
  @spec lost?(heartbeat()) :: boolean()
  def lost?(%{lost: lost}), do: :atomics.get(lost, 1) == 1

  @doc """
  Stop the heartbeat and wait for it to exit, so no renewal can land after
  `settle/2`. A heartbeat that already stopped (a lost claim) is fine.
  """
  @spec stop_heartbeat(heartbeat()) :: :ok
  def stop_heartbeat(%{pid: pid}) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @doc """
  End the claim: `consumed?` true keeps it and makes the job due now; false
  drops it and restores the job's original schedule. Matches nothing, and
  does nothing, once the claim is lost.
  """
  @spec settle(t(), boolean()) :: :ok
  def settle(claim, true), do: settled(claim, Repo.query(@consumed_sql, claim_params(claim)))
  def settle(claim, false), do: settled(claim, Repo.query(@unconsumed_sql, claim_params(claim)))

  defp settled(claim, result) do
    case result do
      {:ok, _result} ->
        :ok

      # The lease lapses on its own: a consumed upload's job runs a few
      # minutes later than it would have; an unconsumed one's token is spent.
      {:error, reason} ->
        Logger.warning(
          "Direct upload #{claim.key}: the cleanup claim was not settled (#{inspect(reason)}); " <>
            "it lapses when its lease ends."
        )

        :ok
    end
  end

  defp beat(claim, interval, lost) do
    receive do
      :stop -> :ok
    after
      interval ->
        case renew(claim) do
          :lost -> :atomics.put(lost, 1, 1)
          _renewed_or_missed -> beat(claim, interval, lost)
        end
    end
  end

  defp job_params(key), do: [Oban.Worker.to_string(StagedUploadCleanup), %{"key" => key}]

  defp claim_params(%{key: key, id: id}), do: job_params(key) ++ [id]

  defp lease_ms, do: config(:lease_ms, @default_lease_ms)
  defp heartbeat_ms, do: config(:heartbeat_ms, @default_heartbeat_ms)

  defp config(key, default),
    do: :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
