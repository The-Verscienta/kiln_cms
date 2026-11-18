defmodule KilnCMS.Test.BackupChain do
  @moduledoc """
  Run a backup's step chain (#2218) to the end inside a test.

  `run/2` requests a backup as `KilnCMS.Backups.system/0` and drains the
  `:backup_steps` queue and every backup directory's queue (#2845) in the
  calling process (`testing: :manual`), with
  recursion (each step inserts the next) and scheduled jobs (a retry's backoff
  and a snooze are run at once, so four attempts take no wall time). It returns
  what the chain settled on, from the `[:kiln_cms, :backups, :chain, :settled]`
  event: `:ok` or `{:error, reason}` with the step's own reason term, so a test
  can match the same terms the inline `Worker.run/3` used to return. A request
  that did not start a chain returns the request's own result.
  """
  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Repo

  @event [:kiln_cms, :backups, :chain, :settled]

  @doc "Request a backup (`opts` as `Backups.request/2`) and drain its chain."
  @spec run(String.t(), keyword()) :: :ok | {:error, term()} | {:ok, map()}
  def run(trigger \\ "manual", opts \\ []) do
    listen(fn ->
      case Backups.request(Keyword.put(opts, :trigger, trigger), Backups.system()) do
        {:ok, %{status: :started, chain: chain}} ->
          drain()
          settled(chain)

        other ->
          other
      end
    end)
  end

  @doc "Resume `stamp`, as `run/2`."
  @spec resume(String.t(), keyword()) :: :ok | {:error, term()} | {:ok, map()}
  def resume(stamp, opts \\ []), do: run("manual", Keyword.put(opts, :resume, stamp))

  @doc """
  Drain the step queues (every chain in them), as `run/2` does: `backup_steps`
  and each `backup_dir_<id>` queue holding a job, again until a pass runs
  nothing (a step may move a job to its directory's queue). With
  `with_recursion: false`, one pass. `queue:` drains that queue alone.
  Returns the summed results.
  """
  @spec drain(keyword()) :: map()
  def drain(opts \\ []) do
    opts = Keyword.merge([with_recursion: true, with_scheduled: true], opts)

    if Keyword.has_key?(opts, :queue),
      do: Oban.drain_queue(opts),
      else: drain_all(opts, %{})
  end

  defp drain_all(opts, acc) do
    pass =
      Enum.reduce(["backup_steps" | dir_queues()], %{}, fn queue, totals ->
        opts |> Keyword.put(:queue, queue) |> Oban.drain_queue() |> sum(totals)
      end)

    acc = sum(pass, acc)

    if opts[:with_recursion] and pass |> Map.values() |> Enum.sum() > 0,
      do: drain_all(opts, acc),
      else: acc
  end

  defp sum(one, other), do: Map.merge(one, other, fn _key, a, b -> a + b end)

  @doc "The `backup_dir_<id>` queues that hold a job waiting to run."
  @spec dir_queues() :: [String.t()]
  def dir_queues do
    Repo.all(
      from(j in Oban.Job,
        where:
          like(j.queue, "backup\\_dir\\_%") and j.state in ["available", "scheduled", "retryable"],
        distinct: true,
        select: j.queue
      )
    )
  end

  @doc """
  The backup step jobs, oldest first, in whichever queue (#2845): what tests
  query instead of `queue == "backup_steps"`. Filters: `chain:`, `step:`
  (a string), `state:` (a string or a list).
  """
  @spec step_jobs(keyword()) :: [Oban.Job.t()]
  def step_jobs(filters \\ []) do
    query = from(j in Oban.Job, where: j.worker == "KilnCMS.Backups.StepWorker", order_by: j.id)

    filters
    |> Enum.reduce(query, fn
      {:chain, chain}, q -> where(q, [j], fragment("?->>'chain' = ?", j.args, ^chain))
      {:step, step}, q -> where(q, [j], fragment("?->>'step' = ?", j.args, ^step))
      {:state, states}, q when is_list(states) -> where(q, [j], j.state in ^states)
      {:state, state}, q -> where(q, [j], j.state == ^state)
    end)
    |> Repo.all()
  end

  @doc """
  Run `fun` with the settled events of every chain delivered to this process
  as `{:chain_settled, chain, outcome}`.
  """
  @spec listen((-> result)) :: result when result: term()
  def listen(fun) do
    id = {__MODULE__, make_ref()}
    pid = self()

    :telemetry.attach(
      id,
      @event,
      fn _event, _measurements, %{chain: chain, outcome: outcome}, _config ->
        send(pid, {:chain_settled, chain, outcome})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end
  end

  @doc "The outcome `chain` settled on, already delivered; `{:error, :unsettled}` if none."
  @spec settled(String.t()) :: :ok | {:error, term()}
  def settled(chain) do
    receive do
      {:chain_settled, ^chain, outcome} -> outcome
    after
      0 -> {:error, :unsettled}
    end
  end
end
