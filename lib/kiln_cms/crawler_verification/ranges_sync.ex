defmodule KilnCMS.CrawlerVerification.RangesSync do
  @moduledoc """
  Shares search engines' published crawler range lists across the cluster
  (#2586). One node fetches them (`KilnCMS.CrawlerVerification.RangesWorker`,
  an Oban cron job, which runs once per cluster) and sends each list on
  `KilnCMS.CrawlerVerification.Ranges.topic/0`; this process, on every node,
  installs what arrives.

  ## Messages

    * `{:crawler_ranges, 1, engine, cidrs, age_ms}`: a list, as CIDR strings,
      and how long ago it was fetched, measured by the sender as it sent. The
      receiver dates it from its own clock (receipt time minus `age_ms`), so
      nodes whose clocks disagree still agree on how fresh a list is. Every
      range goes through the parser's checks again
      (`KilnCMS.CrawlerVerification.Ranges.Parser.parse_strings/2`), so a
      peer on another release, or a bad payload, cannot install what this
      node's own fetch would refuse. A list older than the one installed is
      ignored, as is any other version, an engine this node has no source
      for, and anything malformed.
    * `{:crawler_ranges_sync, node}`: a node asking for every fresh list.
      Each peer that holds one answers it directly. Sent at boot, on every
      `:nodeup` (a booting node usually asks before DNSCluster has connected
      it to anyone), and at each 10-minute check while a list is not fresh.

  ## A node with no fresh list

  `:bootstrap_after_ms` (20 s) after boot, a node that still has no fresh
  list for some engine queues one fetch job, unique for 10 minutes so nodes
  booting together queue one. Every 10 minutes it checks again: while a list
  is not fresh it asks the cluster again, queues a fetch again, and logs a
  warning once per engine until the list is fresh. (`:tick_ms` in the
  `Ranges` config overrides the 10 minutes, for the test env.) With `:bootstrap?` off
  (dev, e2e, test) it never queues a fetch itself, leaving the cron.

  Distribution peers are trusted already; PubSub delivery is best effort,
  and a node that misses a list falls back to DNS (or `:unverifiable` for
  DuckDuckBot) once its own goes stale, like `KilnCMS.Cache.ClusterBust`.
  """
  use GenServer

  require Logger

  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.CrawlerVerification.Ranges.Parser
  alias KilnCMS.CrawlerVerification.RangesWorker

  @tick_ms :timer.minutes(10)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, Ranges.topic())
    :net_kernel.monitor_nodes(true)
    {:ok, %{warned: MapSet.new(), opts: opts}, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    config = Ranges.config(state.opts)
    request_sync()

    if config[:bootstrap?] == true,
      do: Process.send_after(self(), :bootstrap, config[:bootstrap_after_ms])

    Process.send_after(self(), :tick, Keyword.get(config, :tick_ms, @tick_ms))
    {:noreply, state}
  end

  @impl true
  def handle_info({:crawler_ranges, _version, _engine, _cidrs, _age_ms} = payload, state) do
    install(payload, state.opts)
    {:noreply, state}
  end

  def handle_info({:crawler_ranges_sync, requester}, state) do
    for {to, payload} <- replies_for(requester, state.opts) do
      Phoenix.PubSub.direct_broadcast(to, KilnCMS.PubSub, Ranges.topic(), payload)
    end

    {:noreply, state}
  end

  def handle_info(:bootstrap, state) do
    if Ranges.enabled?(state.opts) and stale_engines(state.opts) != [], do: insert_job()
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    config = Ranges.config(state.opts)
    Process.send_after(self(), :tick, Keyword.get(config, :tick_ms, @tick_ms))
    {:noreply, tick(state)}
  end

  def handle_info({:nodeup, _node}, state) do
    request_sync()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Installs a list another node sent, under the rules in the moduledoc.
  Answers `:installed` or `:ignored`.
  """
  @spec install(term(), keyword()) :: :installed | :ignored
  def install(payload, opts \\ [])

  def install({:crawler_ranges, version, engine, strings, age_ms}, opts)
      when is_atom(engine) and is_list(strings) and is_integer(age_ms) and age_ms >= 0 do
    config = Ranges.config(opts)

    with true <- version == Ranges.version(),
         true <- Ranges.enabled?(opts),
         true <- Engines.range_source(engine) != nil,
         true <- age_ms <= config[:max_age_ms],
         {:ok, cidrs} <- Parser.parse_strings(strings, max_prefixes: config[:max_prefixes]) do
      Ranges.put(engine, cidrs, Keyword.take(opts, [:now]) ++ [age_ms: age_ms])
    else
      _refused -> :ignored
    end
  end

  def install(_malformed, _opts), do: :ignored

  @doc """
  The answers to `requester`'s sync request: one `{requester, payload}` per
  fresh list this node holds, none to itself.
  """
  @spec replies_for(node(), keyword()) :: [{node(), Ranges.payload()}]
  def replies_for(requester, opts \\ [])
  def replies_for(requester, _opts) when requester == node(), do: []

  def replies_for(requester, opts) do
    if Ranges.enabled?(opts) do
      for engine <- Engines.range_engines(),
          payload <- [Ranges.payload(engine, opts)],
          payload != nil,
          do: {requester, payload}
    else
      []
    end
  end

  @doc false
  # The 10-minute check, callable directly from a test.
  def tick(state) do
    stale = if Ranges.enabled?(state.opts), do: stale_engines(state.opts), else: []

    if stale != [] do
      request_sync()
      if Ranges.config(state.opts)[:bootstrap?] == true, do: insert_job()
    end

    for engine <- stale, not MapSet.member?(state.warned, engine) do
      Logger.warning(
        "Crawler verification: #{engine}'s published crawler IP ranges are missing or " <>
          "stale, so its claims fall back to DNS (DuckDuckBot's go unverified). Check " <>
          "that this node can reach the vendor over HTTPS, or set " <>
          "KILN_CRAWLER_RANGES=false to stop fetching them"
      )
    end

    %{state | warned: MapSet.new(stale)}
  end

  @doc false
  # Engines with a source whose list on this node is not fresh.
  def stale_engines(opts \\ []) do
    Enum.reject(Engines.range_engines(), &Ranges.fresh?(&1, opts))
  end

  defp request_sync do
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, Ranges.topic(), {:crawler_ranges_sync, node()})
  end

  # Oban or the repo may be down or not started yet; a missed bootstrap is
  # covered by the next check and the cron, so a failed insert is not a crash.
  defp insert_job do
    RangesWorker.new(%{}) |> Oban.insert()
  rescue
    error ->
      Logger.warning("Crawler verification: could not queue a range fetch: #{inspect(error)}")
      :error
  catch
    :exit, _reason -> :error
  end
end
