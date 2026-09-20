defmodule KilnCMS.Media.TransformGate do
  @moduledoc """
  Bounds how many on-the-fly image transforms render at once.

  A render is a decode, a resize and an encode — hundreds of milliseconds of
  CPU for a large source, more for AVIF — and the transform endpoint is
  public. The per-IP rate limit bounds one client; this bounds the node, so a
  burst of cache misses (a new page with forty images, or someone walking the
  allowlist) queues behind a fixed number of renders instead of starving
  every other request of scheduler time.

  **Waiting, not refusing, is the normal case.** A browser does not retry a
  failed `<img>`, so turning away the ninth thumbnail of a fresh page because
  eight were rendering would leave a broken image. A caller waits up to
  `queue_timeout` (10 s) for a slot; only a caller that times out, or arrives
  to a queue already `max_queue` deep, gets `{:error, :busy}` (a 503 with
  `Retry-After`).

  Slots and queued callers are both **monitored**: a request process that dies
  mid-render — a closed connection, a crash in libvips — frees its slot, and
  one that dies while queued leaves the queue. A counter decremented in an
  `after` block would leak a slot per killed process and eventually wedge the
  endpoint shut.

      config :kiln_cms, :image_transforms,
        max_concurrency: 4,    # default: half the schedulers, at least 2
        queue_timeout: 10_000,
        max_queue: 64
  """
  use GenServer

  @default_queue_timeout 10_000
  @default_max_queue 64

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` holding a slot and returns its result, or `{:error, :busy}` when
  no slot came free in time. `:server` and `:timeout` override the defaults
  (tests start their own gate).
  """
  @spec run((-> result), keyword()) :: result | {:error, :busy} when result: term()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, config(:queue_timeout, @default_queue_timeout))

    case GenServer.call(server, :acquire) do
      {:ok, ref} ->
        holding(server, ref, fun)

      {:wait, ref} ->
        receive do
          {__MODULE__, :granted, ^ref} -> holding(server, ref, fun)
        after
          timeout -> give_up(server, ref, fun)
        end

      :full ->
        {:error, :busy}
    end
  end

  # The grant can cross the timeout: the server may have handed us the slot
  # just before our cancel arrived. It sends the grant before it replies, so
  # when it answers `:granted` the message is already in our mailbox — drain
  # it and take the slot we were given rather than leak it.
  defp give_up(server, ref, fun) do
    case GenServer.call(server, {:cancel, ref}) do
      :cancelled ->
        {:error, :busy}

      :granted ->
        receive do
          {__MODULE__, :granted, ^ref} -> :ok
        after
          0 -> :ok
        end

        holding(server, ref, fun)
    end
  end

  defp holding(server, ref, fun) do
    fun.()
  after
    GenServer.cast(server, {:release, ref})
  end

  @doc "Slots in use and callers waiting — for tests and diagnostics."
  @spec stats(GenServer.server()) :: %{busy: non_neg_integer(), waiting: non_neg_integer()}
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       slots: Keyword.get_lazy(opts, :slots, &default_slots/0),
       max_queue:
         Keyword.get_lazy(opts, :max_queue, fn -> config(:max_queue, @default_max_queue) end),
       # Keyed by the monitor ref, which doubles as the slot's identity: a
       # `:DOWN` names the ref directly, with no pid lookup.
       holders: %{},
       waiting: %{},
       queue: :queue.new()
     }}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag}, state) do
    cond do
      map_size(state.holders) < state.slots ->
        ref = Process.monitor(pid)
        {:reply, {:ok, ref}, put_in(state.holders[ref], pid)}

      map_size(state.waiting) >= state.max_queue ->
        {:reply, :full, state}

      true ->
        ref = Process.monitor(pid)

        {:reply, {:wait, ref},
         %{state | waiting: Map.put(state.waiting, ref, pid), queue: :queue.in(ref, state.queue)}}
    end
  end

  def handle_call({:cancel, ref}, _from, state) do
    cond do
      Map.has_key?(state.waiting, ref) ->
        Process.demonitor(ref, [:flush])
        # Left in `queue`; `grant_next/1` skips refs no longer waiting.
        {:reply, :cancelled, %{state | waiting: Map.delete(state.waiting, ref)}}

      Map.has_key?(state.holders, ref) ->
        {:reply, :granted, state}

      true ->
        {:reply, :cancelled, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{busy: map_size(state.holders), waiting: map_size(state.waiting)}, state}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    if Map.has_key?(state.holders, ref) do
      Process.demonitor(ref, [:flush])
      {:noreply, state |> Map.update!(:holders, &Map.delete(&1, ref)) |> grant_next()}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.holders, ref) ->
        {:noreply, state |> Map.update!(:holders, &Map.delete(&1, ref)) |> grant_next()}

      Map.has_key?(state.waiting, ref) ->
        {:noreply, %{state | waiting: Map.delete(state.waiting, ref)}}

      true ->
        {:noreply, state}
    end
  end

  defp grant_next(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, ref}, queue} ->
        case Map.pop(state.waiting, ref) do
          {nil, _waiting} ->
            grant_next(%{state | queue: queue})

          {pid, waiting} ->
            send(pid, {__MODULE__, :granted, ref})
            %{state | queue: queue, waiting: waiting, holders: Map.put(state.holders, ref, pid)}
        end
    end
  end

  # libvips parallelises a single operation across its own thread pool, so a
  # slot per scheduler would oversubscribe the CPU; half leaves the rest of the
  # app room to answer.
  defp default_slots do
    config(:max_concurrency, max(2, div(System.schedulers_online(), 2)))
  end

  defp config(key, default) do
    :kiln_cms |> Application.get_env(:image_transforms, []) |> Keyword.get(key, default)
  end
end
