defmodule KilnCMS.CrawlerVerification.Supervisor do
  @moduledoc """
  Crawler verification's processes (#2254), `:rest_for_one` in this order:

    1. the verified-result cache: proven crawler names only, bounded to
       `:max_verified_entries` (10,000) addresses (#2588). Nothing an attacker
       can make the verifier write lands here, since a result only does when
       a forward lookup confirms a name under an engine's domain, so a flood of
       rejected or failed lookups cannot evict a real crawler's result.
    2. the result cache for everything else (rejections and resolver errors):
       bounded to `:max_entries` (50,000) addresses. Both caches are Cachex
       instances of their own with an evented least-recently-written policy,
       like `KilnCMS.Cache`: a flood of new addresses claiming to be Googlebot
       cannot grow either without bound, and cannot evict anything another
       cache holds.
    3. the network-mark cache (#2838): IPv6 `/64`s whose finished lookups
       produced negative evidence, bounded to `:max_network_marks` (10,000)
       networks the same way, so a flood of marks cannot evict a result.
    4. `KilnCMS.CrawlerVerification.InFlight`, the single-flight table.
    5. a `Task.Supervisor` capped at `:max_concurrency` (16) lookups. A
       request whose lookup would be the 17th is not queued: it goes
       unchecked (`{:unverified, :skipped}`) and a later request retries.
    6. a one-slot `Task.Supervisor` for the resolver-health canary
       (`KilnCMS.CrawlerVerification.resolver_failing?/1`), apart from the
       lookups so a node whose lookup slots are all busy can still tell a
       failing resolver from a silent reverse zone.
    7. the first-sighting cache (#2852): when this node first asked
       `KilnCMS.CrawlerVerification.listing_overdue?/3` about a client
       outside a published list, bounded to `:max_listing_entries` (100,000)
       clients the same way. Last, so a restart of anything above it wipes
       it too, and it restarts alone.

  If a cache restarts, the claims and lookups after it restart with it, so a
  lookup never writes into a cache that is not the one being read. A restart
  of either result cache also restarts the network-mark cache, so it wipes
  every mark: the networks it named are exempt again until their next
  finished lookup. A restart that reaches the first-sighting cache starts
  every client's grace again, which errs toward not counting.

  The caps come from `config :kiln_cms, KilnCMS.CrawlerVerification` at
  start, or from the child's options.
  """
  use Supervisor

  import Cachex.Spec, only: [hook: 1]

  alias KilnCMS.CrawlerVerification
  alias KilnCMS.CrawlerVerification.InFlight

  @default_max_entries 50_000
  @default_max_verified_entries 10_000
  @default_max_network_marks 10_000
  @default_max_listing_entries 100_000
  @default_max_concurrency 16

  @doc false
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # The range lists' fetch-time array, made once per VM before anything can
    # fetch or read a list; a restart keeps the one there (#2586).
    KilnCMS.CrawlerVerification.Ranges.setup()

    config = Keyword.merge(Application.get_env(:kiln_cms, CrawlerVerification, []), opts)
    max_entries = Keyword.get(config, :max_entries, @default_max_entries)

    max_verified_entries =
      Keyword.get(config, :max_verified_entries, @default_max_verified_entries)

    max_network_marks = Keyword.get(config, :max_network_marks, @default_max_network_marks)
    max_concurrency = Keyword.get(config, :max_concurrency, @default_max_concurrency)

    max_listing_entries =
      Keyword.get(config, :max_listing_entries, @default_max_listing_entries)

    children = [
      cache(CrawlerVerification.verified_cache_name(), max_verified_entries),
      cache(CrawlerVerification.cache_name(), max_entries),
      cache(CrawlerVerification.network_cache_name(), max_network_marks),
      {InFlight, Keyword.take(config, [:sweep_interval_ms])},
      {Task.Supervisor,
       name: CrawlerVerification.task_supervisor(), max_children: max_concurrency},
      Supervisor.child_spec(
        {Task.Supervisor, name: CrawlerVerification.canary_supervisor(), max_children: 1},
        id: CrawlerVerification.canary_supervisor()
      ),
      cache(CrawlerVerification.listing_cache_name(), max_listing_entries)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp cache(name, max_entries) do
    Supervisor.child_spec(
      {Cachex,
       name: name,
       hooks: [hook(module: Cachex.Limit.Evented, args: {max_entries, [reclaim: 0.1]})]},
      id: name
    )
  end
end
