defmodule KilnCMS.CrawlerVerification do
  @moduledoc """
  Checks a search-engine claim against the engine's published IP ranges
  (#2586) and DNS (#2254): is a request whose `User-Agent` names Googlebot
  really from Google?

  An address inside the claimed engine's fresh published list
  (`KilnCMS.CrawlerVerification.Ranges`: Google, Bing, Apple, DuckDuckGo) is
  verified at once, with no DNS lookup, no rate-cap charge and no cache
  write. One outside it is still checked by DNS, so a list that lags behind
  the vendor never turns a real Googlebot into a failure. DuckDuckBot, which
  publishes no reverse-DNS domain, has only its list: an address outside it
  is `{:unverified, :not_listed}`, never a proof, since a list can lag a
  vendor's new addresses (#2852). A missing or stale list decides nothing.

  The DNS check is the one every engine documents: the address's PTR name must
  fall under the engine's domain (`KilnCMS.CrawlerVerification.Engines`), and
  that name's forward lookup must contain the address again. A PTR record is
  whatever the owner of the address's reverse zone wrote, so the forward
  lookup is what proves it.

  ## Never on the request path

  `check/3` never waits on DNS. It answers from a per-node cache; on a miss it
  starts a lookup in the background and answers `{:unverified, :pending}`, so
  a crawler's first request from a new address is judged before its result is
  known and its later requests are judged by it.

    * `:verified`: the claim is proven, by the engine's fresh published list
      or by DNS.
    * `:disabled`: verification is off (`enabled: false`); nothing is checked.
    * `{:unverified, :failed}`: DNS proved the claim false (no PTR record, a
      PTR name outside the engine's domain, or a forward lookup that does not
      contain the address).
    * `{:unverified, :not_listed}`: the engine publishes no reverse-DNS
      domain, and the address is outside its fresh published list
      (DuckDuckBot, #2852). Evidence against the claim, not a proof: a list
      lags the vendor's newest addresses. No lookup is made, nothing is
      cached and nothing is marked. `listing_overdue?/3` says when the list
      has had long enough to catch up.
    * `{:unverified, :pending}`: a lookup is running, or was just started.
    * `{:unverified, :error}`: the last lookup's PTR query could not get an
      answer (a timeout, SERVFAIL, a refused query). Cached for a short while
      and never read as a failure. The silence may be the address's own
      reverse zone, which its owner controls.
    * `{:unverified, :forward_error}`: the PTR record named a host under the
      engine's domain, and that host's forward query could not get an answer
      (#2588), though it was given at least `:query_timeout_ms` before the
      deadline. Cached and read like `:error`, but the silence is in the
      engine's own zone, which the address's owner does not control. A
      forward query left less time by a slow PTR answer is plain `:error`.
    * `{:unverified, :skipped}`: no lookup was started, because the node is
      at its concurrent-lookup limit or the address's network has used its
      lookup budget.
    * `{:unverified, :unverifiable}`: the engine publishes no reverse-DNS
      domain and has no fresh published list that could answer (DuckDuckBot
      while its list is missing or stale, or over IPv6, which its list does
      not cover), or is not an engine at all.
    * `{:unverified, :not_public}`: the address is loopback, private, shared,
      in `TRUSTED_PROXIES`, or the caller says it came through a forwarding
      header nothing trusts (`forwarded_untrusted?: true`). Its PTR record says
      nothing about the client, so no lookup is made, and no range list is
      read: an address inside a list proves nothing when it is a proxy's.

  What a caller does with each answer is the caller's policy; this module
  only answers.

  ## Cost bounds

  One lookup is at most three queries: one PTR query, then a forward query
  (A for an IPv4 client, AAAA for IPv6) for at most two of the first three
  PTR names that fall under any engine's domain. The whole lookup has a
  deadline (`:deadline_ms`, 3 s); at the deadline it is killed and recorded as
  a timeout.

  Lookups are single-flight per address (`KilnCMS.CrawlerVerification.InFlight`),
  run at most `:max_concurrency` (16) at a time per node, and are rate limited
  per network (IPv4 `/24` and `/16`, IPv6 `/64`, `/48` and `/32`) and per node
  (`:lookups_per_minute`, 600). The per-network caps are what stop one
  attacker from rotating through the addresses of a `/48` to buy a lookup
  each. The caps are charged before the lookup starts; one that then cannot
  start because every slot is busy gives back what it charged in that window
  (#2588), so a flood of turned-away starts cannot spend a network's or the
  node's budget.

  ## The cache

  Results are cached **per address**, not per engine: the PTR names that
  were confirmed (or the reason none could be), with the claimed engine's
  domain matched when the cache is read. An address proven to be Google's
  that next claims to be bingbot is a proven failure for bingbot without a
  second lookup. A confirmed name is kept for `:verified_ttl_ms` (6 h), a
  proven failure for `:rejected_ttl_ms` (1 h), a resolver error for
  `:error_ttl_ms` (5 min). Per node, never shared.

  Confirmed names live in a cache of their own (`:max_verified_entries`),
  apart from rejections and errors (`:max_entries`), and a read asks it
  first (#2588). Both are bounded least-recently-written, but an attacker can
  only write the second, so rotating through new addresses cannot evict a
  verified crawler.

  ## Network marks

  A scanner that rotates through the addresses of its IPv6 `/64` never meets
  its own failures: each new address is `{:unverified, :pending}` until its
  lookup finishes, and `KilnCMS.Security.ScannerGuard` counts per `/64`
  (#2838). So a finished lookup that produced claimant-controlled negative
  evidence also marks the address's `/64`, and `network_flagged?/2` answers
  whether it is marked:

    * `:failed`: the lookup proved the claim false (`{:unverified, :failed}`).
    * `:silent`: the address's PTR query got no answer (`{:unverified, :error}`).
      Written only while `resolver_failing?/1` is false, and read only while
      it is false: while this node's resolver is itself failing, the silence
      says nothing about the network.

  Nothing else marks: not a lookup turned away by a cap or a busy slot (an
  attacker can spend those from other networks), not a forward error in the
  engine's own zone, not a verified result, not an answer from a range list.
  A lookup that verifies an address clears a `:silent` mark on its `/64`, so
  one timed-out PTR query for a real crawler does not outlive the crawler's
  next verified address; only the engine's own DNS produces that result.
  It never clears a `:failed` mark; what a mark means for a verified claim is
  the caller's policy (the guard: nothing). A `:silent` mark never replaces
  a `:failed` one; every mark written refreshes the entry's
  `:network_mark_ttl_ms` (1 h).

  Marks are IPv6 only, keyed by the `/64` alone (never the engine, the user
  agent or the org), per node, and written only while the 404 guard is on
  (`config :kiln_cms, :scanner_blocking, enabled: true`), since nothing else
  reads them. IPv4 is counted per address, so an address's own verdict
  already lines up with what is counted; an IPv4-mapped IPv6 address is the
  IPv4 client it carries. They live in a cache of their own
  (`:max_network_marks`), never the verified cache an attacker cannot write.

  ## List-only evidence (#2852)

  An address outside DuckDuckGo's list may be a spoofer or a crawler the
  list does not name yet. `listing_overdue?/3` tells them apart for
  `KilnCMS.Security.ScannerGuard`: it is `true` once the counted client
  (an IPv4 address, or an IPv6 address's `/64`) is still outside a list this
  node fetched at least `:listing_grace_ms` (24 h) after the instance first
  asked about that client. A vendor that adds a crawler's address publishes
  it within a day; a spoofer's address never appears.

  The first sighting is the instance's, not a node's: a row of
  `KilnCMS.Security.CrawlerSighting` per client and engine, keyed by a hash
  of the client, dated by the database's clock and written by
  `KilnCMS.Security.CrawlerSightingStore` in one upsert that keeps the
  earliest live sighting and returns it. So a deploy, a restart or a new
  node does not start the grace again, and every node counts the same
  client from the same moment. The clock starts at the guard's first
  question, which is a counted 404 miss, not the client's first request.
  Each question moves the row's expiry to `:listing_ttl_ms` (48 h) on; a
  client idle longer starts again, as does one the prune has removed.

  Each node keeps a read-through copy in a cache of its own
  (`:max_listing_entries`, 100,000 clients, least-recently-written first),
  so a busy client costs one database statement per `:listing_refresh_ms`
  (5 min), not one per 404, and a flood of marks or rejections cannot evict
  it. An entry evicted at the cap, or lost with a restart of the verifier's
  processes, is read back from the database: it costs a statement, never
  the grace. The statement is never run inside a transaction.

  **When the database cannot answer**, the node's copy is used if it has
  one, however old; with none, the claim is not overdue. That errs toward
  not counting, as every failure here does: a database outage leaves new
  spoofers exempt for its length, and a real crawler is never counted on a
  sighting nobody recorded. The client's database question then waits
  `:listing_retry_ms` (30 s): its copy is kept with a retry time in place of
  its refresh time, or, with no copy, a marker answering "no sighting" is
  cached until then, so an outage costs a client one statement timeout per
  retry window rather than one per 404. Every unanswered statement emits
  `[:kiln_cms, :crawler_verification, :sighting_unavailable]`, and the node
  logs an error at most once a minute, with the database error's message
  alone: a missing table or a missing grant would otherwise leave list-only
  spoofers exempt with no sign of it. A question asked inside a transaction
  is none of these: the store is not asked, nothing is cached, logged or
  emitted, and the next question outside one asks the database.

  The sighting is wall-clock milliseconds by the database's clock; the
  list's fetch time is this node's wall clock less the list's age
  (`KilnCMS.CrawlerVerification.Ranges.age_ms/2`, which dates a list a peer
  sent by the age it carried and moves on every refetch, unchanged or not).
  The two clocks differ only by the skew between a node and its database,
  seconds against a day's grace.

  ## Is the resolver failing?

  A lookup that gets no answer means one of two things: this node's resolver
  is down, so no claim can be checked, or the address's own reverse zone is
  silent, which its owner chooses. `resolver_failing?/1` tells them apart for
  `KilnCMS.Security.ScannerGuard` (#2588). It is `false` while some lookup got
  an answer within `:health_window_ms` (1 min). Otherwise it starts one
  *canary* per window, a PTR query for `:canary_address` (`8.8.8.8`), whose
  reverse zone always answers; and answers what the last canary found,
  `false` until one has. The canary runs on a one-slot supervisor of its own,
  so it runs even while every lookup slot is busy, and charges no rate cap.

  ## Configuration

  `config :kiln_cms, KilnCMS.CrawlerVerification`, each overridable per call:

    * `:enabled` (`true`)
    * `:resolver` (`KilnCMS.CrawlerVerification.InetResolver`)
    * `:query_timeout_ms` (1,000): the wait for one nameserver's reply to one
      attempt; the resolver may try more than one nameserver, always within
      the deadline
    * `:deadline_ms` (3,000): the whole lookup
    * `:verified_ttl_ms`, `:rejected_ttl_ms`, `:error_ttl_ms`
    * `:lookups_per_minute` (600): new lookups per node
    * `:prefix_lookups_per_minute`: new lookups per network, as
      `[inet: [{prefix, limit}], inet6: [{prefix, limit}]]`
    * `:error_warning_after` (20): consecutive failed lookups before a warning
    * `:health_window_ms` (60,000): how recent an answered lookup must be for
      `resolver_failing?/1` to trust the resolver without a canary
    * `:canary_address` (`{8, 8, 8, 8}`): the address the canary's PTR query
      asks about; never a visitor's
    * `:network_mark_ttl_ms` (1 h): how long a network mark is kept after
      its last write
    * `:listing_grace_ms` (24 h): how long after a client's first sighting a
      list must have been fetched before `listing_overdue?/3` believes it
    * `:listing_ttl_ms` (48 h): how long a first sighting is kept after the
      last call that asked about it
    * `:listing_refresh_ms` (5 min): how long a node trusts its cached copy
      of a sighting before asking the database again, which also moves the
      sighting's expiry on
    * `:listing_retry_ms` (30 s): how long a node waits before asking the
      database about a client again after it could not answer
    * `:max_entries` (50,000), `:max_verified_entries` (10,000),
      `:max_network_marks` (10,000), `:max_listing_entries` (100,000),
      `:max_concurrency` (16): read once, by
      `KilnCMS.CrawlerVerification.Supervisor`

  The range lists have their own (`KilnCMS.CrawlerVerification.Ranges`).

  ## Telemetry

  No event carries an address, a hostname, a user agent or an org.

    * `[:kiln_cms, :crawler_verification, :lookup]`, `%{duration}` (native
      units), `%{engine, result, reason}`: one per finished lookup, judged for
      the engine that started it. `result` is `:verified`, `:rejected`,
      `:timeout` or `:error`; `reason` is `nil`, the rejection
      (`:no_ptr`, `:wrong_domain`, `:forward_mismatch`) or the error
      (`:timeout`, `:servfail`, `:refused`, … or `:other`).
    * `[:kiln_cms, :crawler_verification, :skipped]`, `%{count: 1}`,
      `%{engine, reason}`: a lookup not started, `reason` `:busy` or
      `:rate_limited`.
    * `[:kiln_cms, :crawler_verification, :sighting_unavailable]`,
      `%{count: 1}`, `%{engine, reason}`: the database could not answer a
      first-sighting question (#2852), `reason` `:connection`, `:ownership`,
      `:postgres` (Postgres refused the statement: a missing table or grant
      among them) or `:other`.

  Two warnings are logged once per node: the first time the concurrency limit
  turns a lookup away, and after `:error_warning_after` lookups in a row could
  not reach an answer (a node with no DNS egress), naming
  `KILN_CRAWLER_VERIFICATION=false`. An unanswered first-sighting question is
  logged at `:error` at most once a minute per node (see "List-only
  evidence").
  """

  require Logger

  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.InetResolver
  alias KilnCMS.CrawlerVerification.InFlight
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.Security.Cidr
  alias KilnCMS.Security.CrawlerSightingStore
  alias KilnCMSWeb.RateLimit

  @cache :kiln_cms_crawler_verification
  @verified_cache :kiln_cms_crawler_verification_verified
  @network_cache :kiln_cms_crawler_verification_networks
  @listing_cache :kiln_cms_crawler_verification_listing
  @task_supervisor KilnCMS.CrawlerVerification.TaskSupervisor
  @canary_supervisor KilnCMS.CrawlerVerification.CanarySupervisor

  # The first this-many PTR names are read; of those, at most @max_forward are
  # confirmed by a forward query. Together they bound a lookup at 3 queries.
  @max_names 3
  @max_forward 2

  # How long a claim outlives its lookup's deadline before another request may
  # take it over. The lookup always ends at the deadline; this only covers a
  # lookup process that died before releasing.
  @claim_grace_ms 1_000

  @defaults [
    enabled: true,
    resolver: InetResolver,
    resolver_opts: [],
    query_timeout_ms: 1_000,
    deadline_ms: 3_000,
    verified_ttl_ms: :timer.hours(6),
    rejected_ttl_ms: :timer.hours(1),
    error_ttl_ms: :timer.minutes(5),
    network_mark_ttl_ms: :timer.hours(1),
    lookups_per_minute: 600,
    prefix_lookups_per_minute: [
      inet: [{24, 30}, {16, 120}],
      inet6: [{64, 30}, {48, 60}, {32, 120}]
    ],
    rate_window_ms: :timer.minutes(1),
    rate_scope: "crawler_verify",
    error_warning_after: 20,
    health_window_ms: :timer.minutes(1),
    canary_address: {8, 8, 8, 8},
    listing_grace_ms: :timer.hours(24),
    listing_ttl_ms: :timer.hours(48),
    listing_refresh_ms: :timer.minutes(5),
    listing_retry_ms: :timer.seconds(30)
  ]

  # Error reasons named in telemetry; anything else is `:other`, so a metric
  # tag can never take an unbounded value.
  @error_reasons [:timeout, :servfail, :refused, :formerr, :notimp, :econnrefused, :nxdomain]

  @type reason ::
          :pending
          | :failed
          | :not_listed
          | :unverifiable
          | :not_public
          | :skipped
          | :error
          | :forward_error
  @type status :: :verified | :disabled | {:unverified, reason()}
  @type mark :: :failed | :silent
  @type verdict ::
          {:verified, String.t()}
          | {:rejected, :no_ptr | :wrong_domain | :forward_mismatch}
          | {:error, term()}

  @doc "The result cache's name: rejections and resolver errors."
  @spec cache_name() :: atom()
  def cache_name, do: @cache

  @doc "The verified-result cache's name: confirmed crawler names only."
  @spec verified_cache_name() :: atom()
  def verified_cache_name, do: @verified_cache

  @doc "The network-mark cache's name: IPv6 `/64`s that produced negative evidence (#2838)."
  @spec network_cache_name() :: atom()
  def network_cache_name, do: @network_cache

  @doc "The first-sighting cache's name: this node's copy of `KilnCMS.Security.CrawlerSighting` (#2852)."
  @spec listing_cache_name() :: atom()
  def listing_cache_name, do: @listing_cache

  @doc "The lookup task supervisor's name."
  @spec task_supervisor() :: atom()
  def task_supervisor, do: @task_supervisor

  @doc "The resolver-health canary's one-slot task supervisor's name."
  @spec canary_supervisor() :: atom()
  def canary_supervisor, do: @canary_supervisor

  @doc "Is verification on? On unless `config :kiln_cms, #{inspect(__MODULE__)}, enabled: false`."
  @spec enabled?() :: boolean()
  def enabled?, do: config([])[:enabled] == true

  @doc """
  The status of `ip`'s claim to be `engine` (`KilnCMS.BotClass.search_engine/1`).
  Never blocks on DNS; see the moduledoc for each answer.

  Options, beyond the configuration keys:

    * `:forwarded_untrusted?`: the request carried a forwarding header that
      no trusted proxy vouches for (`KilnCMSWeb.Plugs.ClientIp.untrusted_forwarding?/1`),
      so `ip` may be a proxy's. Answers `{:unverified, :not_public}`.
    * `:task_supervisor`: where lookups run (a test seam).
    * `:ranges`: options for `KilnCMS.CrawlerVerification.Ranges.lookup/3`
      (a test seam).
  """
  @spec check(atom(), :inet.ip_address() | nil, keyword()) :: status()
  def check(engine, ip, opts \\ []) do
    config = config(opts)

    cond do
      config[:enabled] != true -> :disabled
      not Engines.known?(engine) -> {:unverified, :unverifiable}
      true -> guarded_check(engine, normalize_ip(ip), config)
    end
  end

  # `check/3` runs inside the delivery rate limiter on every search-engine
  # request. While the verifier's own processes restart (`:rest_for_one`: the
  # cache, then the in-flight table, then the task supervisor), the cache
  # answers `{:error, :no_cache}` and the in-flight table does not exist, so
  # `:ets` raises. That must not turn a crawler's request into a 500: an
  # unchecked claim is `:skipped`, which keeps the search budget held to the
  # browser ceiling — exactly what a busy verifier answers.
  defp guarded_check(engine, ip, config) do
    check_address(engine, ip, config)
  rescue
    _exception -> {:unverified, :skipped}
  catch
    :exit, _reason -> {:unverified, :skipped}
  end

  @doc """
  Looks `ip` up now and judges it as `engine`, waiting for DNS (up to
  `:deadline_ms`). Uses no cache, no single-flight and no rate limit: this is
  the lookup itself, for diagnostics and tests, never for a request.

  `{:error, :unverifiable}` for an engine with no reverse-DNS domain,
  `{:error, :invalid_address}` for anything that is not an address.
  """
  @spec verify(atom(), :inet.ip_address(), keyword()) :: verdict()
  def verify(engine, ip, opts \\ []) do
    config = config(opts)

    cond do
      not Engines.verifiable?(engine) -> {:error, :unverifiable}
      is_nil(normalize_ip(ip)) -> {:error, :invalid_address}
      true -> judge(engine, lookup(normalize_ip(ip), config))
    end
  end

  @doc false
  # Test seam: plant a result for `ip` as if a lookup for `engine` had produced
  # it, with that result's TTL. `:verified` plants a name under the engine's
  # first domain.
  @spec put_result(atom(), :inet.ip_address(), :verified | verdict(), keyword()) :: :ok
  def put_result(engine, ip, result, opts \\ []) do
    stored = planted(engine, result)
    put_stored(normalize_ip(ip), stored, config(opts))
  end

  @doc false
  # Test seam: drop whatever is cached for `ip`, in both caches.
  @spec forget(:inet.ip_address(), keyword()) :: :ok
  def forget(ip, _opts \\ []) do
    ip = normalize_ip(ip)
    Cachex.del(@verified_cache, ip)
    Cachex.del(@cache, ip)
    :ok
  end

  @doc false
  # Test seam: mark `ip`'s network as a finished lookup would, whether or not
  # the 404 guard is on. A no-op for an IPv4 address.
  @spec put_network_mark(:inet.ip_address(), mark(), keyword()) :: :ok
  def put_network_mark(ip, kind, opts \\ []) when kind in [:failed, :silent] do
    put_mark(network_key(normalize_ip(ip)), kind, config(opts))
  end

  @doc false
  # Test seam: drop the mark on `ip`'s network.
  @spec forget_network(:inet.ip_address()) :: :ok
  def forget_network(ip) do
    case network_key(normalize_ip(ip)) do
      nil -> :ok
      key -> Cachex.del(@network_cache, key)
    end

    :ok
  end

  @doc false
  # Test seam: date `engine`'s first sighting of `ip`'s client
  # (`listing_overdue?/3`) at `at_ms`, wall-clock milliseconds, in the
  # database, lapsing the configured TTL from now, and drop this node's copy
  # so the next question reads it.
  @spec put_first_seen(atom(), :inet.ip_address(), integer(), keyword()) :: :ok
  def put_first_seen(engine, ip, at_ms, opts \\ []) when is_integer(at_ms) do
    config = config(opts)

    case listing_key(normalize_ip(ip)) do
      nil ->
        :ok

      key ->
        CrawlerSightingStore.put(store_key(key), engine, at_ms, config[:listing_ttl_ms])
        Cachex.del(listing_cache(config), {engine, key})
    end

    :ok
  end

  @doc false
  # Test seam: `{first_seen_ms, ms_until_it_lapses}` for `engine`'s sighting
  # of `ip`'s client in the database, or nil.
  @spec first_seen(atom(), :inet.ip_address()) :: {integer(), integer()} | nil
  def first_seen(engine, ip) do
    case listing_key(normalize_ip(ip)) do
      nil -> nil
      key -> CrawlerSightingStore.fetch(store_key(key), engine)
    end
  end

  @doc false
  # Test seam: this node's copy of `engine`'s sighting of `ip`'s client, as
  # `{first_seen_ms, refresh_at}` (`refresh_at` in monotonic milliseconds), or
  # nil.
  @spec cached_first_seen(atom(), :inet.ip_address(), keyword()) ::
          {integer(), integer()} | nil
  def cached_first_seen(engine, ip, opts \\ []) do
    with key when not is_nil(key) <- listing_key(normalize_ip(ip)),
         {:ok, {at, _refresh_at} = cached} when is_integer(at) <-
           Cachex.get(listing_cache(config(opts)), {engine, key}) do
      cached
    else
      _none -> nil
    end
  end

  @doc false
  # Test seam: forget every engine's sighting of `ip`'s client, in the
  # database (when the caller can reach it) and in this node's copy.
  @spec forget_listing(:inet.ip_address(), keyword()) :: :ok
  def forget_listing(ip, opts \\ []) do
    case listing_key(normalize_ip(ip)) do
      nil ->
        :ok

      key ->
        CrawlerSightingStore.forget(store_key(key))
        cache = listing_cache(config(opts))
        Enum.each(Engines.engines(), &Cachex.del(cache, {&1, key}))
    end

    :ok
  end

  @doc false
  # Test seam: let the once-per-node warnings fire again.
  def reset_warnings do
    InFlight.reset_latches()
    InFlight.reset(:consecutive_errors)
  end

  @doc false
  # Test seam: forget every answer and canary verdict, and let a canary start
  # in the current window again.
  def reset_health do
    InFlight.reset_health()
    InFlight.reset_latches()
  end

  @doc """
  Is this node's resolver itself failing, rather than one address's reverse
  zone staying silent? See "Is the resolver failing?" in the moduledoc.

  Never waits on DNS: it may start the window's canary, and answers what the
  last canary found. `false` with verification off, and when the verifier's
  processes are restarting.
  """
  @spec resolver_failing?(keyword()) :: boolean()
  def resolver_failing?(opts \\ []) do
    config = config(opts)
    window_ms = config[:health_window_ms]
    now = now()

    cond do
      config[:enabled] != true -> false
      answered_within?(now, window_ms) -> false
      true -> canary_verdict(now, window_ms, config) == :failing
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  @doc """
  Has `ip`'s IPv6 `/64` produced negative evidence recently? See "Network
  marks" in the moduledoc.

  `true` for a `:failed` mark, and for a `:silent` one while
  `resolver_failing?/1` is false. Never waits on DNS. `false` for an IPv4
  address (an IPv4-mapped one included), with verification off, and when the
  verifier's processes are restarting.
  """
  @spec network_flagged?(:inet.ip_address() | nil, keyword()) :: boolean()
  def network_flagged?(ip, opts \\ []) do
    with true <- config(opts)[:enabled] == true,
         key when not is_nil(key) <- network_key(normalize_ip(ip)),
         {:ok, kind} when kind in [:failed, :silent] <- Cachex.get(@network_cache, key) do
      kind == :failed or not resolver_failing?(opts)
    else
      _unmarked -> false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  @doc """
  Has `engine`'s published list had long enough to name `ip`, and still does
  not? See "List-only evidence" in the moduledoc.

  `true` only while `ip` is outside `engine`'s fresh list
  (`KilnCMS.CrawlerVerification.Ranges.lookup/3` answers `:out`) and that
  list was fetched, by this node's wall clock, at least `:listing_grace_ms`
  after the instance first asked about `ip`'s client. The first call for a
  client records the sighting and answers `false`. Only a client outside the
  list is recorded.

  Never waits on DNS. A cache hit is one cache read; a miss, or a copy older
  than `:listing_refresh_ms`, adds one database statement
  (`KilnCMS.Security.CrawlerSightingStore.record/3`) and a cache write. When
  the database cannot answer, the cached copy decides if there is one, else
  `false`, and the database is not asked about the client again for
  `:listing_retry_ms`. `false` with verification off, for anything that is
  not an address, and when the verifier's processes are restarting.

  Options, beyond the configuration keys (all test seams): `:now`
  (monotonic milliseconds: when the cached copy is due, and the list's age),
  `:system_now` (wall-clock milliseconds, from which the list's age is
  taken), `:ranges` (options for `Ranges.lookup/3`) and `:listing_cache`.
  """
  @spec listing_overdue?(atom(), :inet.ip_address() | nil, keyword()) :: boolean()
  def listing_overdue?(engine, ip, opts \\ []) do
    config = config(opts)
    ip = normalize_ip(ip)
    ranges = Keyword.get(config, :ranges, [])

    now = Keyword.get(config, :now, now())

    with true <- config[:enabled] == true,
         key when not is_nil(key) <- listing_key(ip),
         :out <- Ranges.lookup(engine, ip, ranges),
         {:ok, first_seen} <- sighting(engine, key, now, config),
         age when is_integer(age) <- Ranges.age_ms(engine, now: now) do
      system_now = Keyword.get(config, :system_now, System.system_time(:millisecond))
      system_now - age >= first_seen + config[:listing_grace_ms]
    else
      _not_overdue -> false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  # The client's first sighting, as wall-clock milliseconds by the
  # database's clock: this node's copy while it is due no refresh, else the
  # database's answer (recorded now if there is none), copied here. A read
  # then a write rather than a Cachex transaction, which would queue every
  # 404 of every listed claim through one process: two misses racing each
  # other both ask the database, whose upsert gives both the same answer. A
  # cache that cannot answer is no sighting at all.
  defp sighting(engine, key, now, config) do
    cache = listing_cache(config)
    cache_key = {engine, key}

    case Cachex.get(cache, cache_key) do
      {:ok, {:unknown, retry_at}} when now < retry_at -> :error
      {:ok, {first_seen, refresh_at}} when now < refresh_at -> {:ok, first_seen}
      {:ok, cached} -> refresh_sighting(cache, cache_key, cached, now, config)
      {:error, _reason} -> :error
    end
  end

  defp refresh_sighting(cache, {engine, key} = cache_key, cached, now, config) do
    case CrawlerSightingStore.record(store_key(key), engine, config[:listing_ttl_ms]) do
      {:ok, first_seen} ->
        Cachex.put(cache, cache_key, {first_seen, now + config[:listing_refresh_ms]},
          expire: config[:listing_ttl_ms]
        )

        {:ok, first_seen}

      # Inside a transaction the store was never asked, and nothing is wrong
      # with it: no copy is written, so the next question outside one asks.
      {:unavailable, :in_transaction} ->
        cached_answer(cached)

      # The database cannot answer: the last copy it gave, however old, or
      # no sighting (not overdue), and no question to it again for
      # `:listing_retry_ms`, so an outage does not hold every 404 for the
      # statement's timeout.
      {:unavailable, reason} ->
        retry_later(cache, cache_key, cached, now + config[:listing_retry_ms], config)
        sighting_unavailable(engine, reason, now)
        cached_answer(cached)
    end
  end

  defp cached_answer({first_seen, _refresh_at}) when is_integer(first_seen), do: {:ok, first_seen}
  defp cached_answer(_none), do: :error

  # A copy keeps its first sighting and its expiry; with none, a marker that
  # answers "no sighting" until the retry, and lapses soon after it.
  defp retry_later(cache, cache_key, {first_seen, _refresh_at}, retry_at, _config)
       when is_integer(first_seen),
       do: Cachex.update(cache, cache_key, {first_seen, retry_at})

  defp retry_later(cache, cache_key, _none, retry_at, config),
    do: Cachex.put(cache, cache_key, {:unknown, retry_at}, expire: config[:listing_retry_ms])

  # Logged at most once a minute per node, with the exception's message
  # alone: no address, no key, no engine. The event is one per unanswered
  # statement, which the retry bounds at one per client per retry window.
  defp sighting_unavailable(engine, reason, now) do
    if InFlight.claim_interval(:sighting_unavailable, now, :timer.minutes(1)) do
      Logger.error(
        "Crawler sighting store unavailable (#{unavailable_message(reason)}); " <>
          "list-only search-engine claims (#2852) are not counted as overdue on " <>
          "this node, except from a sighting it already holds, until the database answers."
      )
    end

    :telemetry.execute(
      [:kiln_cms, :crawler_verification, :sighting_unavailable],
      %{count: 1},
      %{engine: engine, reason: unavailable_reason(reason)}
    )
  end

  defp unavailable_message(%{__exception__: true} = error), do: Exception.message(error)
  defp unavailable_message(_reason), do: "unknown reason"

  defp unavailable_reason(%DBConnection.ConnectionError{}), do: :connection
  defp unavailable_reason(%DBConnection.OwnershipError{}), do: :ownership
  defp unavailable_reason(%Postgrex.Error{}), do: :postgres
  defp unavailable_reason(_reason), do: :other

  defp listing_cache(config), do: Keyword.get(config, :listing_cache, @listing_cache)

  # The client the 404 guard counts, as a tuple: an IPv4 address (an
  # IPv4-mapped one is already its IPv4 address here), or an IPv6 address's
  # `/64`. Never a string, never joined with anything a client sends.
  defp listing_key({a, b, c, d}), do: {:inet, a, b, c, d}
  defp listing_key(ip), do: network_key(ip)

  # The string `CrawlerSightingStore` hashes for a client: the address, or
  # the `/64` in CIDR form. Never stored as is.
  defp store_key({:inet, a, b, c, d}), do: "inet:#{a}.#{b}.#{c}.#{d}"

  defp store_key({:inet6, a, b, c, d}),
    do: "inet6:#{:inet.ntoa({a, b, c, d, 0, 0, 0, 0})}/64"

  # ---- check/3 --------------------------------------------------------------

  # The address first: a range list says nothing about a proxy's address.
  # Then the engine's published list (#2586), where only `:in` decides for an
  # engine DNS can check; then DNS. For an engine DNS cannot check, `:out` is
  # evidence, never a proof (#2852): lists lag.
  defp check_address(engine, ip, config) do
    if worth_a_lookup?(ip, config) do
      ranges = Ranges.lookup(engine, ip, Keyword.get(config, :ranges, []))

      cond do
        ranges == :in -> :verified
        Engines.verifiable?(engine) -> check_dns(engine, ip, config)
        ranges == :out -> {:unverified, :not_listed}
        true -> {:unverified, :unverifiable}
      end
    else
      {:unverified, :not_public}
    end
  end

  defp check_dns(engine, ip, config) do
    case cached(ip) do
      {:ok, stored} when not is_nil(stored) -> engine |> judge(stored) |> status(engine, stored)
      _miss -> request_lookup(engine, ip, config)
    end
  end

  # A verified result first: it is never in the other cache too, except for
  # the moment between a write and its delete.
  defp cached(ip) do
    with {:ok, nil} <- Cachex.get(@verified_cache, ip) do
      Cachex.get(@cache, ip)
    end
  end

  defp worth_a_lookup?(ip, config) do
    config[:forwarded_untrusted?] != true and Cidr.public_unicast?(ip) and
      not trusted_proxy?(ip)
  end

  defp trusted_proxy?(ip) do
    :kiln_cms
    |> Application.get_env(:trusted_proxies, [])
    |> Enum.any?(&Cidr.contains?(to_string(&1), ip))
  end

  # `judge/2` only answers an error for a `{:ptr, _}` result when a forward
  # query for a name under the claimed engine's domain got no answer. That
  # silence is the engine's zone, not the address's (#2588), but only if the
  # query had its full budget: a PTR answer slow enough to starve it is the
  # address's own zone at work, so that reads as plain `:error`.
  defp status({:verified, _host}, _engine, _stored), do: :verified
  defp status({:rejected, _reason}, _engine, _stored), do: {:unverified, :failed}

  defp status({:error, _reason}, engine, {:ptr, result}) do
    if engine_silent?(engine, result),
      do: {:unverified, :forward_error},
      else: {:unverified, :error}
  end

  defp status({:error, _reason}, _engine, _stored), do: {:unverified, :error}

  # The error `judge/2` reports for `engine`, given its full budget. A result
  # cached before `:budgeted` existed has none, so it reads as plain `:error`:
  # an unknown budget counts toward the client, never toward the exemption.
  defp engine_silent?(engine, result) do
    budgeted = Map.get(result, :budgeted, [])

    case Enum.find(result.errors, fn {host, _reason} -> Engines.matches?(engine, host) end) do
      {host, _reason} -> host in budgeted
      nil -> false
    end
  end

  defp request_lookup(engine, ip, config) do
    case InFlight.claim(ip, claim_ttl(config)) do
      :in_flight ->
        {:unverified, :pending}

      {:ok, claim} ->
        case within_caps(ip, config) do
          {:ok, charged} -> start_or_refund(engine, ip, claim, charged, config)
          {:skipped, reason} -> turn_away(engine, claim, reason)
        end
    end
  end

  # A lookup that could not start gives back what it charged (#2588), or a
  # flood of turned-away starts would spend every network's budget, and the
  # node's, without a lookup. The claim is released first, so nothing the
  # refund does can leave it held.
  defp start_or_refund(engine, ip, claim, charged, config) do
    case start(engine, ip, claim, config) do
      :ok ->
        {:unverified, :pending}

      {:skipped, :busy} ->
        skipped = turn_away(engine, claim, :busy)
        refund(charged, config)
        skipped
    end
  end

  defp turn_away(engine, claim, reason) do
    InFlight.release(claim)
    skipped(engine, reason)
    {:unverified, :skipped}
  end

  defp claim_ttl(config),
    do: Keyword.get(config, :in_flight_ttl_ms, config[:deadline_ms] + @claim_grace_ms)

  # Narrowest network first, then the node: a network over its budget is
  # turned away before it spends the node's. Answers the keys it charged and
  # the window they were charged in, for `refund/2`: none when the charges
  # straddled a window boundary, since the index then names only some of
  # them. A refusal keeps its charges, as it always has: Hammer counts a
  # denied hit too.
  defp within_caps(ip, config) do
    window = config[:rate_window_ms]
    scope = config[:rate_scope]
    keys = for {key, limit} <- caps(ip, config), do: {"#{scope}:#{key}", limit}
    index = RateLimit.window_index(window)

    result =
      Enum.reduce_while(keys, {:ok, []}, fn {key, limit}, {:ok, charged} ->
        case RateLimit.hit(key, window, limit) do
          {:allow, _count} -> {:cont, {:ok, [key | charged]}}
          {:deny, _retry_after} -> {:halt, {:skipped, :rate_limited}}
        end
      end)

    case result do
      {:ok, charged} ->
        if RateLimit.window_index(window) == index,
          do: {:ok, {index, charged}},
          else: {:ok, {index, []}}

      refused ->
        refused
    end
  end

  # Gives back each charge in the window it was charged in; `RateLimit.refund/3`
  # leaves a window that has since closed alone. Never raises into `check/3`:
  # a row Hammer stores in a shape the refund does not expect costs the
  # refund, logged once per node, never the request.
  defp refund({index, charged}, config) do
    window = config[:rate_window_ms]
    Enum.each(charged, &RateLimit.refund(&1, window, index))
  rescue
    # The message is not logged: it can carry the key, which names a network.
    ArgumentError ->
      if InFlight.latch(:refund_failed) do
        Logger.warning(
          "Crawler verification could not refund a rate-limit charge (the rate " <>
            "limiter's counter row is not in the shape it expects); a lookup " <>
            "turned away as busy keeps its charge"
        )
      end

      :ok
  end

  defp caps(ip, config) do
    family = if tuple_size(ip) == 4, do: :inet, else: :inet6
    text = ip |> :inet.ntoa() |> to_string()

    prefixes =
      for {bits, limit} <- Keyword.get(config[:prefix_lookups_per_minute], family, []) do
        {:ok, cidr} = Cidr.parse("#{text}/#{bits}")
        {Cidr.format(cidr), limit}
      end

    prefixes ++ [{"node", config[:lookups_per_minute]}]
  end

  # `start_child/2` is a call: a supervisor that is down or restarting exits
  # the caller, which here is a request. That is a lookup not started.
  defp start(engine, ip, claim, config) do
    supervisor = Keyword.get(config, :task_supervisor, @task_supervisor)

    case Task.Supervisor.start_child(supervisor, fn -> run(engine, ip, claim, config) end) do
      {:ok, _pid} -> :ok
      {:error, _max_children} -> {:skipped, :busy}
    end
  catch
    :exit, _reason -> {:skipped, :busy}
  end

  defp skipped(engine, reason) do
    if reason == :busy and InFlight.latch(:busy) do
      Logger.warning(
        "Crawler verification is at its concurrent-lookup limit; new search-engine " <>
          "claims go unchecked until a lookup finishes"
      )
    end

    :telemetry.execute(
      [:kiln_cms, :crawler_verification, :skipped],
      %{count: 1},
      %{engine: engine, reason: reason}
    )
  end

  # ---- the lookup -----------------------------------------------------------

  defp run(engine, ip, claim, config) do
    started = System.monotonic_time()
    stored = lookup(ip, config)
    put_stored(ip, stored, config)
    note_outcome(stored, config)
    verdict = judge(engine, stored)
    mark_network(ip, status(verdict, engine, stored), config)
    emit_lookup(engine, verdict, System.monotonic_time() - started)
  after
    InFlight.release(claim)
  end

  # The lookup in a process of its own, killed at the deadline. The resolver
  # is handed the time left and should return on its own; the kill is the
  # backstop for one that does not. Monitored, not linked: a resolver that
  # crashes is an error result, not a crash of the caller.
  defp lookup(ip, config) do
    deadline_ms = config[:deadline_ms]
    deadline_at = now() + deadline_ms
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent | Process.get(:"$callers", [])])
        send(parent, {ref, resolve(ip, config, deadline_at)})
      end)

    receive do
      {^ref, stored} ->
        Process.demonitor(monitor, [:flush])
        stored

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :resolver_crashed}
    after
      deadline_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  # What is cached for an address: `:no_ptr`, `{:error, reason}`, or
  # `{:ptr, %{names, confirmed, errors, budgeted}}` — the readable PTR names,
  # the ones a forward query confirmed, `{name, reason}` for each forward
  # query that got no answer, and the names among those whose query was given
  # at least `:query_timeout_ms` before the deadline (#2588). `judge/2` reads it for one engine.
  defp resolve(ip, config, deadline_at) do
    case call(config, deadline_at, &config[:resolver].ptr(ip, &1)) do
      {:ok, []} -> :no_ptr
      {:ok, names} -> confirm(ip, names, config, deadline_at)
      {:error, :nxdomain} -> :no_ptr
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm(ip, raw_names, config, deadline_at) do
    names =
      raw_names
      |> Enum.take(@max_names)
      |> Enum.map(&Engines.normalize_host/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    initial = %{names: names, confirmed: [], errors: [], budgeted: []}

    {result, _forwarded} =
      names
      |> Enum.filter(&(Engines.engines_for(&1) != []))
      |> Enum.reduce({initial, 0}, fn host, {acc, forwarded} ->
        if forwarded >= @max_forward or covered?(host, acc.confirmed) do
          {acc, forwarded}
        else
          {forward(acc, host, ip, config, deadline_at), forwarded + 1}
        end
      end)

    {:ptr, result}
  end

  # Every engine this name could prove is already proven by another name.
  defp covered?(host, confirmed) do
    Enum.all?(Engines.engines_for(host), fn engine ->
      Enum.any?(confirmed, &Engines.matches?(engine, &1))
    end)
  end

  # A forward query that errors is `budgeted` only when it was given at least
  # `:query_timeout_ms`: one the PTR answer left less time (or none, so
  # `call/3` never asked) may have failed for want of time, which the
  # address's own reverse zone can arrange by answering late.
  defp forward(acc, host, ip, config, deadline_at) do
    family = if tuple_size(ip) == 4, do: :inet, else: :inet6
    full_budget? = deadline_at - now() >= config[:query_timeout_ms]

    case call(config, deadline_at, &config[:resolver].addresses(host, family, &1)) do
      {:ok, addresses} ->
        if Enum.any?(addresses, &(normalize_ip(&1) == ip)),
          do: %{acc | confirmed: acc.confirmed ++ [host]},
          else: acc

      {:error, :nxdomain} ->
        acc

      {:error, reason} when full_budget? ->
        %{acc | errors: acc.errors ++ [{host, reason}], budgeted: acc.budgeted ++ [host]}

      {:error, reason} ->
        %{acc | errors: acc.errors ++ [{host, reason}]}
    end
  end

  # One resolver call with the time left, or a timeout without calling when
  # none is left.
  defp call(config, deadline_at, fun) do
    case deadline_at - now() do
      left when left > 0 ->
        fun.(
          [timeout: left, query_timeout_ms: config[:query_timeout_ms]] ++ config[:resolver_opts]
        )

      _none_left ->
        {:error, :timeout}
    end
  end

  defp judge(_engine, :no_ptr), do: {:rejected, :no_ptr}
  defp judge(_engine, {:error, reason}), do: {:error, reason}

  defp judge(engine, {:ptr, %{names: names, confirmed: confirmed, errors: errors}}) do
    matches? = &Engines.matches?(engine, &1)

    cond do
      host = Enum.find(confirmed, matches?) ->
        {:verified, host}

      error = Enum.find(errors, fn {host, _reason} -> matches?.(host) end) ->
        {:error, elem(error, 1)}

      Enum.any?(names, matches?) ->
        {:rejected, :forward_mismatch}

      true ->
        {:rejected, :wrong_domain}
    end
  end

  defp put_stored(nil, _stored, _config), do: :ok

  # A confirmed name goes to the verified cache and anything else to the
  # other; the write drops whatever the other cache held for the address, so
  # the newest result is the one read.
  defp put_stored(ip, stored, config) do
    {into, other} =
      if verified?(stored), do: {@verified_cache, @cache}, else: {@cache, @verified_cache}

    Cachex.put(into, ip, stored, expire: ttl(stored, config))
    Cachex.del(other, ip)
    :ok
  end

  # The results `ttl/2` keeps for `:verified_ttl_ms`.
  defp verified?({:ptr, %{confirmed: [_ | _], errors: []}}), do: true
  defp verified?(_stored), do: false

  defp ttl(:no_ptr, config), do: config[:rejected_ttl_ms]
  defp ttl({:error, _reason}, config), do: config[:error_ttl_ms]
  defp ttl({:ptr, %{errors: [_ | _]}}, config), do: config[:error_ttl_ms]
  defp ttl({:ptr, %{confirmed: [_ | _]}}, config), do: config[:verified_ttl_ms]
  defp ttl({:ptr, _rejected}, config), do: config[:rejected_ttl_ms]

  # Count lookups in a row that got no answer at all; any answer resets it
  # and is the resolver-health signal `resolver_failing?/1` reads.
  defp note_outcome(stored, config) do
    if unanswered?(stored) do
      count = InFlight.bump(:consecutive_errors)

      if count >= config[:error_warning_after] and InFlight.latch(:resolver_failing) do
        Logger.warning(
          "Crawler verification: #{count} DNS lookups in a row timed out or failed; " <>
            "check that this node can reach its DNS resolver, or set " <>
            "KILN_CRAWLER_VERIFICATION=false to turn verification off"
        )
      end
    else
      InFlight.reset(:consecutive_errors)
      InFlight.put_health(:last_answer_at, now())
    end
  end

  # ---- network marks (#2838) ------------------------------------------------

  # Only a finished lookup's own evidence marks, and only while the 404 guard,
  # the one reader, is on. A `:forward_error` is the engine's zone, not the
  # address's (#2588), and marks nothing. Silence while this node's resolver
  # is failing says nothing about the network, so it marks nothing either:
  # otherwise an outage would leave every crawler `/64` it touched marked for
  # the hour after recovery. A verified result is the engine's own DNS
  # vouching for the address, which no claimant can forge, so it clears a
  # `:silent` mark on its `/64` (a transient timeout), never a `:failed` one.
  defp mark_network(ip, {:unverified, :failed}, config), do: mark_if_guarded(ip, :failed, config)

  # The guard and the address are checked before `resolver_failing?/1`, which
  # may start a canary query: the canary runs only while the 404 guard asks
  # (ADR 0054), and an IPv4 address has no mark to write.
  defp mark_network(ip, {:unverified, :error}, config) do
    cond do
      not scanner_guard_on?() -> :ok
      network_key(ip) == nil -> :ok
      resolver_failing?(config) -> :ok
      true -> put_mark(network_key(ip), :silent, config)
    end
  end

  defp mark_network(ip, :verified, _config) do
    if scanner_guard_on?(), do: clear_silent(network_key(ip)), else: :ok
  end

  defp mark_network(_ip, _status, _config), do: :ok

  defp mark_if_guarded(ip, kind, config) do
    if scanner_guard_on?(), do: put_mark(network_key(ip), kind, config), else: :ok
  end

  # Read like `KilnCMS.Security.ScannerGuard.enabled?/0` reads it, off unless
  # an operator turned it on, without depending on the guard.
  defp scanner_guard_on? do
    :kiln_cms |> Application.get_env(:scanner_blocking, []) |> Keyword.get(:enabled) == true
  end

  # Atomic, so a `:silent` mark never overwrites a `:failed` one written at
  # the same moment; then every write refreshes the TTL. Never raises into
  # the lookup: a mark that cannot be written is a mark not written.
  defp put_mark(nil, _kind, _config), do: :ok

  defp put_mark(key, kind, config) do
    Cachex.get_and_update(@network_cache, key, &merge_mark(&1, kind))
    Cachex.expire(@network_cache, key, config[:network_mark_ttl_ms])
    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp merge_mark(:failed, :silent), do: {:ignore, :failed}
  defp merge_mark(_current, kind), do: {:commit, kind}

  # Atomic like `put_mark/3`, so a `:failed` mark written at the same moment
  # is never the one deleted. Never raises into the lookup either.
  defp clear_silent(nil), do: :ok

  defp clear_silent(key) do
    Cachex.transaction(@network_cache, [key], fn worker ->
      with {:ok, :silent} <- Cachex.get(worker, key), do: Cachex.del(worker, key)
    end)

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  # The `/64` of an IPv6 address, as a tuple: never a string, never joined
  # with anything a client sends. IPv4 has no network mark.
  defp network_key({a, b, c, d, _e, _f, _g, _h}), do: {:inet6, a, b, c, d}
  defp network_key(_ipv4_or_nil), do: nil

  # ---- resolver health ------------------------------------------------------

  defp answered_within?(now, window_ms) do
    case InFlight.health(:last_answer_at) do
      at when is_integer(at) -> now - at < window_ms
      nil -> false
    end
  end

  # Starts this window's canary if no caller has, then answers the last
  # canary's verdict: `:healthy` until one has found otherwise, including
  # while this one runs or when it could not start.
  defp canary_verdict(now, window_ms, config) do
    if InFlight.claim_probe(:canary, Integer.floor_div(now, window_ms)) do
      start_canary(config)
    end

    InFlight.health(:canary) || :healthy
  end

  defp start_canary(config) do
    supervisor = Keyword.get(config, :canary_supervisor, @canary_supervisor)
    Task.Supervisor.start_child(supervisor, fn -> run_canary(config) end)
  catch
    :exit, _reason -> :ok
  end

  # The same bounded lookup as a claim's, for a fixed address whose reverse
  # zone always answers. Charges no rate cap and caches nothing.
  defp run_canary(config) do
    if unanswered?(lookup(normalize_ip(config[:canary_address]), config)) do
      InFlight.put_health(:canary, :failing)
    else
      InFlight.put_health(:canary, :healthy)
      InFlight.put_health(:last_answer_at, now())
    end
  end

  defp unanswered?({:error, _reason}), do: true
  defp unanswered?({:ptr, %{confirmed: [], errors: [_ | _]}}), do: true
  defp unanswered?(_answered), do: false

  defp emit_lookup(engine, verdict, duration) do
    {result, reason} =
      case verdict do
        {:verified, _host} -> {:verified, nil}
        {:rejected, reason} -> {:rejected, reason}
        {:error, :timeout} -> {:timeout, :timeout}
        {:error, reason} -> {:error, error_reason(reason)}
      end

    :telemetry.execute(
      [:kiln_cms, :crawler_verification, :lookup],
      %{duration: duration},
      %{engine: engine, result: result, reason: reason}
    )
  end

  defp error_reason(reason) when reason in @error_reasons, do: reason
  defp error_reason(_reason), do: :other

  # ---- helpers --------------------------------------------------------------

  defp planted(engine, :verified) do
    [suffix | _] = Engines.suffixes(engine)
    planted(engine, {:verified, "planted." <> suffix})
  end

  defp planted(_engine, {:verified, host}) do
    host = Engines.normalize_host(host)
    {:ptr, %{names: [host], confirmed: [host], errors: []}}
  end

  defp planted(_engine, {:rejected, :no_ptr}), do: :no_ptr

  defp planted(_engine, {:rejected, :wrong_domain}),
    do: {:ptr, %{names: ["planted.invalid"], confirmed: [], errors: []}}

  defp planted(engine, {:rejected, :forward_mismatch}) do
    [suffix | _] = Engines.suffixes(engine)
    {:ptr, %{names: ["planted." <> suffix], confirmed: [], errors: []}}
  end

  defp planted(_engine, {:error, reason}), do: {:error, reason}

  # An IPv4-mapped IPv6 address is the IPv4 client it carries: one cache row,
  # one PTR zone and one A query for it either way.
  defp normalize_ip({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}

  defp normalize_ip(ip) when tuple_size(ip) in [4, 8], do: ip
  defp normalize_ip(_not_an_address), do: nil

  defp config(opts) do
    @defaults
    |> Keyword.merge(Application.get_env(:kiln_cms, __MODULE__, []))
    |> Keyword.merge(opts)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
