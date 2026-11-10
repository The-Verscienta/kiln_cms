defmodule KilnCMS.Test.BackupChain do
  @moduledoc """
  Run a backup's step chain (#2218) to the end inside a test.

  `run/2` requests a backup as `KilnCMS.Backups.system/0` and drains the
  `:backup_steps` queue in the calling process (`testing: :manual`), with
  recursion (each step inserts the next) and scheduled jobs (a retry's backoff
  and a snooze are run at once, so four attempts take no wall time). It returns
  what the chain settled on, from the `[:kiln_cms, :backups, :chain, :settled]`
  event: `:ok` or `{:error, reason}` with the step's own reason term, so a test
  can match the same terms the inline `Worker.run/3` used to return. A request
  that did not start a chain returns the request's own result.
  """
  alias KilnCMS.Backups

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

  @doc "Drain the step queue (every chain in it), as `run/2` does."
  @spec drain(keyword()) :: map()
  def drain(opts \\ []) do
    Oban.drain_queue(
      Keyword.merge([queue: :backup_steps, with_recursion: true, with_scheduled: true], opts)
    )
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
