defmodule KilnCMS.CrawlerVerification.InFlight do
  @moduledoc """
  The addresses crawler verification (#2254) is looking up right now, so a
  burst of requests from one new address starts one lookup, not one per
  request.

  A public ETS set this process owns, one row per address:
  `{ip, ref, expires_at}`. `ref` is unique to the lookup that claimed the
  row; `expires_at` (monotonic milliseconds) is when the claim lapses even if
  its lookup never released it. A claim has lapsed once `expires_at <= now`,
  the same test in `claim/2`, `in_flight?/1` and the sweep, so no moment
  exists where a claim is neither live nor replaceable.

    * `claim/2` takes the row when there is none, or replaces it when it has
      expired. Both are single ETS operations, so two requests can never both
      win.
    * `release/2` deletes the row only if it is still the caller's own: a
      lookup that outlived its claim must not delete the newer claim that
      replaced it.
    * every `:sweep_interval_ms` (a minute) this process deletes the expired
      rows nothing released.

  The same table holds the verifier's node-wide counters, warning latches,
  resolver-health values and the canary's probe latch, under keys that can
  never be an address (`{:counter, name}`, `{:warned, name}`,
  `{:health, name}`, `{:probe, name}`). Those rows have two elements and the
  sweep leaves them alone.
  """
  use GenServer

  @table __MODULE__
  @sweep_interval_ms :timer.minutes(1)

  @type claim :: {:inet.ip_address(), reference(), integer()}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The table's name."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Claims `ip` for a lookup that may run until `ttl_ms` from now. The claim
  to `release/2` later, or `:in_flight` when another live lookup holds it.
  """
  @spec claim(:inet.ip_address(), pos_integer()) :: {:ok, claim()} | :in_flight
  def claim(ip, ttl_ms) do
    now = now()
    row = {ip, make_ref(), now + ttl_ms}

    cond do
      :ets.insert_new(@table, row) -> {:ok, row}
      replace_expired(row, now) -> {:ok, row}
      true -> :in_flight
    end
  end

  @doc "Releases `claim`, if it is still the row for its address."
  @spec release(claim()) :: :ok
  def release(claim) do
    :ets.delete_object(@table, claim)
    :ok
  end

  @doc "Is a live lookup holding `ip`?"
  @spec in_flight?(:inet.ip_address()) :: boolean()
  def in_flight?(ip) do
    case :ets.lookup(@table, ip) do
      [{^ip, _ref, expires_at}] -> expires_at > now()
      _ -> false
    end
  end

  @doc "Adds 1 to the node-wide counter `name` and returns the new value."
  @spec bump(atom()) :: pos_integer()
  def bump(name), do: :ets.update_counter(@table, {:counter, name}, 1, {{:counter, name}, 0})

  @doc "Sets the node-wide counter `name` back to zero."
  @spec reset(atom()) :: :ok
  def reset(name) do
    :ets.insert(@table, {{:counter, name}, 0})
    :ok
  end

  @doc """
  `true` the first time it is called for `name` on this node, `false` after:
  the latch behind a warning that should be logged once.
  """
  @spec latch(atom()) :: boolean()
  def latch(name), do: :ets.insert_new(@table, {{:warned, name}, true})

  @doc """
  `true` when this call is the first to claim probe `name` for `window` (an
  integer that only grows): the row holds the last window claimed, and a
  later window replaces it. One row per probe, never one per window. Both
  steps are single ETS operations, so two callers never both win a window.
  """
  @spec claim_probe(atom(), integer()) :: boolean()
  def claim_probe(name, window) do
    key = {:probe, name}

    :ets.insert_new(@table, {key, window}) or
      :ets.select_replace(@table, [
        {{key, :"$1"}, [{:<, :"$1", window}], [{{{:const, key}, window}}]}
      ]) == 1
  end

  @doc "Stores the node-wide health value `name`."
  @spec put_health(atom(), term()) :: :ok
  def put_health(name, value) do
    :ets.insert(@table, {{:health, name}, value})
    :ok
  end

  @doc "The node-wide health value `name`, or `nil` when none is stored."
  @spec health(atom()) :: term()
  def health(name) do
    case :ets.lookup(@table, {:health, name}) do
      [{_key, value}] -> value
      [] -> nil
    end
  end

  @doc false
  # Test seam: open every latch again, the probe latches included.
  def reset_latches do
    :ets.match_delete(@table, {{:warned, :_}, :_})
    :ets.match_delete(@table, {{:probe, :_}, :_})
    :ok
  end

  @doc false
  # Test seam: forget every health value.
  def reset_health do
    :ets.match_delete(@table, {{:health, :_}, :_})
    :ok
  end

  @doc false
  # Test seam: sweep now instead of on the timer. Returns the rows deleted.
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, sweep_expired(), state}

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule(state.interval)
    {:noreply, state}
  end

  # Only address rows have three elements; counters, latches and health
  # values have two.
  defp sweep_expired do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
  end

  # Replace the row for this address only while its claim has lapsed. The
  # key is unchanged, which `select_replace/2` requires.
  defp replace_expired({ip, ref, expires_at}, now) do
    spec = [
      {{ip, :_, :"$1"}, [{:"=<", :"$1", now}], [{{{:const, ip}, {:const, ref}, expires_at}}]}
    ]

    :ets.select_replace(@table, spec) == 1
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  defp now, do: System.monotonic_time(:millisecond)
end
