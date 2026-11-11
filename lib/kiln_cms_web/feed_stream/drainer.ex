defmodule KilnCMSWeb.FeedStream.Drainer do
  @moduledoc """
  Ends this node's `GET /api/feed` streams cleanly when the node shuts down
  (#2275).

  Started after `KilnCMSWeb.Endpoint` in `KilnCMS.Application`, so it stops
  before it. Its `terminate/2` (it traps exits) marks the node as draining —
  a new stream is then refused with `event: busy`, reason `shutting_down` —
  and sends every open stream `KilnCMSWeb.FeedStream.shutdown_message/0`. Each
  writes a jittered `retry:` and `event: shutdown` and ends its response,
  so its client reconnects, spread out, to another node with its last id.
  It waits up to `drain_timeout_ms` (2 s) for the streams to finish; whatever
  has not by then is closed when the Endpoint stops.

  Without it, a deploy would cut every stream at once and the clients would
  reconnect together, after their own default retry.
  """
  use GenServer

  require Logger

  alias KilnCMSWeb.FeedStream

  @table __MODULE__
  @drain_timeout_ms 2_000
  @poll_ms 20

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Above the drain's own bound, so the supervisor lets it finish.
      shutdown: @drain_timeout_ms + 3_000
    }
  end

  @doc """
  Whether this node is shutting down. True once the drain has begun, and
  when the drainer is not running at all (it has already stopped, so the
  Endpoint is about to).
  """
  @spec draining?() :: boolean()
  def draining? do
    case :ets.lookup(@table, :draining) do
      [{:draining, draining?}] -> draining?
      [] -> false
    end
  rescue
    ArgumentError -> true
  end

  @doc """
  Drain now: refuse new streams and end every open one, waiting up to
  `timeout` ms for them. What `terminate/2` runs; public for tests.
  """
  @spec drain(timeout()) :: :ok
  def drain(timeout \\ @drain_timeout_ms),
    do: GenServer.call(__MODULE__, {:drain, timeout}, timeout + 1_000)

  @doc false
  # Test seam: accept streams again after `drain/1`.
  def undrain, do: GenServer.call(__MODULE__, :undrain)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(@table, {:draining, false})
    {:ok, nil}
  end

  @impl true
  def handle_call({:drain, timeout}, _from, state) do
    do_drain(timeout)
    {:reply, :ok, state}
  end

  def handle_call(:undrain, _from, state) do
    :ets.insert(@table, {:draining, false})
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    do_drain(@drain_timeout_ms)
  end

  defp do_drain(timeout) do
    :ets.insert(@table, {:draining, true})
    streams = FeedStream.streams()
    Enum.each(streams, &send(&1, FeedStream.shutdown_message()))

    deadline = System.monotonic_time(:millisecond) + timeout

    case await_empty(deadline) do
      :ok ->
        :ok

      {:timeout, left} ->
        Logger.warning("feed drain: #{left} of #{length(streams)} stream(s) still open")
    end
  end

  # A stream unregisters when its response ends; its process may live on
  # (keep-alive), so it is the registry that is watched, not the pids.
  defp await_empty(deadline) do
    case Registry.count(FeedStream.streams_registry()) do
      0 ->
        :ok

      left ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, left}
        else
          Process.sleep(@poll_ms)
          await_empty(deadline)
        end
    end
  end
end
