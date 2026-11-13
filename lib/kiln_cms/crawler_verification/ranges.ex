defmodule KilnCMS.CrawlerVerification.Ranges do
  @moduledoc """
  Search engines' published crawler IP range lists (#2586), held per node,
  so `KilnCMS.CrawlerVerification.check/3` can verify an address inside the
  claimed engine's list without a DNS lookup, and can prove a DuckDuckBot
  claim false, which DNS cannot.

  Google, Bing, Apple and DuckDuckGo publish lists
  (`KilnCMS.CrawlerVerification.Engines`); Yandex and Baidu do not.
  `KilnCMS.CrawlerVerification.RangesWorker` fetches them on a schedule and
  `KilnCMS.CrawlerVerification.RangesSync` shares them across the cluster.

  ## What a lookup answers

  `lookup/3` answers `:in`, `:out` or `:unknown`, and only a **fresh** list
  answers anything but `:unknown`:

    * `:in`: the address is inside the engine's list.
    * `:out`: it is not, and the list holds at least one range of the
      address's family. DuckDuckGo publishes IPv4 addresses only, so a
      DuckDuckBot claim over IPv6 is `:unknown`, never `:out`.
    * `:unknown`: no list, a stale one, ranges turned off, or no range of the
      address's family.

  A list is fresh for `:max_age_ms` (24 h, four missed 6-hourly fetches)
  after this node fetched it, or after the fetching node did, for a list a
  peer sent. A fetch that fails keeps the old list with its old age, so it
  goes stale and stops answering: **a stale list never verifies anything and
  never proves anything false.**

  A range match is only as good as the vendor's list. Bing's, for one,
  includes `/28`s in Microsoft Azure space; a list that names an address
  verifies whoever holds it.

  ## Storage

  Per engine, a `:persistent_term` holding the list as an index: for each
  prefix length, the set of networks. A lookup masks the address once per
  distinct length (a handful) and checks a set, with no process and no copy.
  The term is rewritten only when a list's content changes, since replacing
  a `:persistent_term` costs a global GC pass; refetching an unchanged list
  only moves its fetch time. Fetch times live in an `:atomics` array
  (monotonic milliseconds on this node), made once by `setup/0`.

  ## Outbound requests

  This is the first scheduled outbound call a default install makes: a GET
  of each vendor's list every 6 hours from one node, plus at most one at
  boot when no node has a fresh list. Nothing about the instance or its
  visitors is sent. `KILN_CRAWLER_RANGES=false` turns it off, as does
  `KILN_CRAWLER_VERIFICATION=false`; with it off no request is made and every
  claim falls back to DNS (DuckDuckBot to `:unverifiable`).

  ## Configuration

  `config :kiln_cms, KilnCMS.CrawlerVerification.Ranges`:

    * `:enabled` (`true`): ranges are read and fetched only when this and
      `KilnCMS.CrawlerVerification`'s `:enabled` are both on
    * `:sources`: `%{engine => url | false}`, per-engine overrides of the
      default lists; an engine left out keeps its default
    * `:max_age_ms` (24 h): how long a list stays fresh
    * `:max_bytes` (524,288): the largest body a fetch reads
    * `:max_prefixes` (5,000): the most entries a list may hold
    * `:bootstrap?` (`true`) and `:bootstrap_after_ms` (20,000): whether a
      node that has no fresh list shortly after boot, or at a 10-minute
      check, queues a fetch of its own
    * `:req_options`: merged into the fetch (a test seam)
  """

  import Bitwise

  alias KilnCMS.CrawlerVerification
  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.Ranges.Parser
  alias KilnCMS.Security.Cidr

  @topic "kiln:crawler_ranges"
  @version 1
  @clock {__MODULE__, :clock}

  @defaults [
    enabled: true,
    sources: %{},
    max_age_ms: :timer.hours(24),
    max_bytes: 512 * 1024,
    max_prefixes: 5_000,
    bootstrap?: true,
    bootstrap_after_ms: 20_000,
    req_options: []
  ]

  @bits %{inet: 32, inet6: 128}

  @type answer :: :in | :out | :unknown
  @type payload ::
          {:crawler_ranges, pos_integer(), atom(), [String.t()], non_neg_integer()}

  @doc "The PubSub topic lists and sync requests travel on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The payload version this release sends and installs."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "This module's configuration, merged over its defaults, then `opts`."
  @spec config(keyword()) :: keyword()
  def config(opts \\ []) do
    @defaults
    |> Keyword.merge(Application.get_env(:kiln_cms, __MODULE__, []))
    |> Keyword.merge(opts)
  end

  @doc """
  Are range lists read and fetched? Only when crawler verification and
  ranges are both on.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []), do: CrawlerVerification.enabled?() and config(opts)[:enabled] == true

  @doc """
  Makes the fetch-time array, once per VM. Called from
  `KilnCMS.CrawlerVerification.Supervisor` before anything can fetch or
  install a list; a later call keeps the array that is there.
  """
  @spec setup() :: :ok
  def setup do
    if :persistent_term.get(@clock, nil) == nil do
      :persistent_term.put(@clock, :atomics.new(2 * length(Engines.engines()), signed: true))
    end

    :ok
  end

  @doc """
  Is `ip` inside `engine`'s fresh list? See the moduledoc. Options: any
  configuration key, and `:now` (monotonic milliseconds, a test seam).
  """
  @spec lookup(atom(), :inet.ip_address() | nil, keyword()) :: answer()
  def lookup(engine, ip, opts \\ []) do
    config = config(opts)

    with true <- config[:enabled] == true,
         %{} = index <- index(engine),
         true <- fresh?(engine, config),
         {family, int} <- address(ip),
         [_ | _] = networks <- Map.fetch!(index, family) do
      if Enum.any?(networks, &member?(&1, family, int)), do: :in, else: :out
    else
      _unknown -> :unknown
    end
  end

  @doc """
  Is `engine`'s list fresh: fetched, by this node or the peer that sent it,
  no more than `:max_age_ms` ago?
  """
  @spec fresh?(atom(), keyword()) :: boolean()
  def fresh?(engine, opts \\ []) do
    config = config(opts)

    case age_ms(engine, config) do
      age when is_integer(age) -> age >= 0 and age <= config[:max_age_ms]
      nil -> false
    end
  end

  @doc """
  Installs `cidrs` as `engine`'s list, fetched `:age_ms` ago (0: just now),
  unless the list installed already is as new or newer. Answers
  `:installed`, or `:ignored` for an older list.

  The index is rewritten only when the content differs from what is
  installed; an unchanged list only moves the fetch time.
  """
  @spec put(atom(), [Cidr.t()], keyword()) :: :installed | :ignored
  def put(engine, cidrs, opts \\ []) when is_list(cidrs) do
    now = Keyword.get(opts, :now, now())
    fetched_at = now - Keyword.get(opts, :age_ms, 0)

    case {slot(engine), fetched_at(engine)} do
      {nil, _installed} ->
        :ignored

      {_slot, installed} when is_integer(installed) and installed >= fetched_at ->
        :ignored

      {_slot, _older_or_none} ->
        install_index(engine, cidrs)
        set_fetched_at(engine, fetched_at)
        :installed
    end
  end

  @doc """
  What this node would send for `engine`'s list: `nil` unless it is fresh.
  The age is measured now, so a receiver dates the list from its own clock
  (`RangesSync`), never from this node's.
  """
  @spec payload(atom(), keyword()) :: payload() | nil
  def payload(engine, opts \\ []) do
    config = config(opts)

    with %{} = index <- index(engine),
         true <- fresh?(engine, config) do
      {:crawler_ranges, @version, engine, strings(index), age_ms(engine, config)}
    else
      _none -> nil
    end
  end

  @doc "Sends `engine`'s fresh list to every node, this one included."
  @spec broadcast(atom()) :: :ok
  def broadcast(engine) do
    case payload(engine) do
      nil -> :ok
      payload -> Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, payload)
    end
  end

  @doc """
  Per engine with a source: its URL, the ranges held, how long ago it was
  fetched (milliseconds, `nil` if never) and whether it is fresh. For an
  operator's `rpc`.
  """
  @spec status() :: %{atom() => map()}
  def status do
    config = config()

    Map.new(Engines.range_engines(), fn engine ->
      {engine,
       %{
         source: Engines.range_source(engine),
         count: (index(engine) || %{count: 0}).count,
         age_ms: age_ms(engine, config),
         fresh?: fresh?(engine, config)
       }}
    end)
  end

  @doc false
  # Test seam: forget every list.
  @spec clear() :: :ok
  def clear do
    for engine <- Engines.engines() do
      :persistent_term.erase(index_key(engine))
      if clock = clock(), do: :atomics.put(clock, slot(engine) + 2, 0)
    end

    :ok
  end

  @doc false
  # Test seam: install `strings` as `engine`'s list through the parser's
  # rules, fetched `:age_ms` ago.
  @spec put_fixture(atom(), [String.t()], keyword()) :: :installed | :ignored
  def put_fixture(engine, strings, opts \\ []) do
    {:ok, cidrs} = Parser.parse_strings(strings)
    put(engine, cidrs, opts)
  end

  # ---- the index ------------------------------------------------------------

  defp index(engine), do: :persistent_term.get(index_key(engine), nil)

  defp index_key(engine), do: {__MODULE__, :index, engine}

  defp install_index(engine, cidrs) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(cidrs)))

    case index(engine) do
      %{hash: ^hash} -> :ok
      _other -> :persistent_term.put(index_key(engine), build(cidrs, hash))
    end
  end

  defp build(cidrs, hash) do
    by_family =
      Map.new([:inet, :inet6], fn family ->
        networks =
          cidrs
          |> Enum.filter(&(elem(&1, 0) == family))
          |> Enum.group_by(&elem(&1, 2), &elem(&1, 1))
          |> Enum.map(fn {prefix, nets} -> {prefix, MapSet.new(nets)} end)
          |> Enum.sort()

        {family, networks}
      end)

    Map.merge(by_family, %{v: @version, hash: hash, count: length(cidrs)})
  end

  defp strings(index) do
    for family <- [:inet, :inet6],
        {prefix, set} <- index[family],
        net <- Enum.sort(set),
        do: Cidr.format({family, net, prefix})
  end

  defp member?({prefix, set}, family, int), do: MapSet.member?(set, mask(family, int, prefix))

  defp mask(family, int, prefix) do
    shift = @bits[family] - prefix
    (int >>> shift) <<< shift
  end

  # An IPv4-mapped IPv6 address is the IPv4 client it carries.
  defp address({a, b, c, d}) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do: {:inet, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

  defp address({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {:inet, hi <<< 16 ||| lo}

  defp address(ip) when tuple_size(ip) == 8 do
    {:inet6, ip |> Tuple.to_list() |> Enum.reduce(0, fn word, acc -> acc <<< 16 ||| word end)}
  end

  defp address(_not_an_address), do: nil

  # ---- fetch times ----------------------------------------------------------

  defp clock, do: :persistent_term.get(@clock, nil)

  # Slots `i + 1` (the fetch time) and `i + 2` (1 once one is set) of the
  # array, for the engine at `i / 2` in `Engines.engines/0`.
  defp slot(engine) do
    case Enum.find_index(Engines.engines(), &(&1 == engine)) do
      nil -> nil
      index -> 2 * index
    end
  end

  defp fetched_at(engine) do
    with clock when clock != nil <- clock(),
         slot when slot != nil <- slot(engine),
         1 <- :atomics.get(clock, slot + 2) do
      :atomics.get(clock, slot + 1)
    else
      _never -> nil
    end
  end

  # The time first, then the flag: a reader that sees the flag sees a time.
  defp set_fetched_at(engine, fetched_at) do
    setup()
    clock = clock()
    slot = slot(engine)
    :atomics.put(clock, slot + 1, fetched_at)
    :atomics.put(clock, slot + 2, 1)
  end

  defp age_ms(engine, config) do
    case fetched_at(engine) do
      nil -> nil
      at -> Keyword.get(config, :now, now()) - at
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
