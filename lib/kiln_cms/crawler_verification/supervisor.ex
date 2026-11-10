defmodule KilnCMS.CrawlerVerification.Supervisor do
  @moduledoc """
  Crawler verification's processes (#2254), `:rest_for_one` in this order:

    1. the result cache: a Cachex instance of its own, bounded to
       `:max_entries` (50,000) addresses by an evented least-recently-written
       policy, like `KilnCMS.Cache`. A flood of new addresses claiming to be
       Googlebot cannot grow it without bound, and cannot evict anything
       another cache holds.
    2. `KilnCMS.CrawlerVerification.InFlight`, the single-flight table.
    3. a `Task.Supervisor` capped at `:max_concurrency` (16) lookups. A
       request whose lookup would be the 17th is not queued: it goes
       unchecked (`{:unverified, :skipped}`) and a later request retries.

  If the cache restarts, the claims and lookups after it restart with it, so a
  lookup never writes into a cache that is not the one being read.

  Both caps come from `config :kiln_cms, KilnCMS.CrawlerVerification` at
  start, or from the child's options.
  """
  use Supervisor

  import Cachex.Spec, only: [hook: 1]

  alias KilnCMS.CrawlerVerification
  alias KilnCMS.CrawlerVerification.InFlight

  @default_max_entries 50_000
  @default_max_concurrency 16

  @doc false
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:kiln_cms, CrawlerVerification, []), opts)
    max_entries = Keyword.get(config, :max_entries, @default_max_entries)
    max_concurrency = Keyword.get(config, :max_concurrency, @default_max_concurrency)

    children = [
      Supervisor.child_spec(
        {Cachex,
         name: CrawlerVerification.cache_name(),
         hooks: [hook(module: Cachex.Limit.Evented, args: {max_entries, [reclaim: 0.1]})]},
        id: CrawlerVerification.cache_name()
      ),
      {InFlight, Keyword.take(config, [:sweep_interval_ms])},
      {Task.Supervisor,
       name: CrawlerVerification.task_supervisor(), max_children: max_concurrency}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
