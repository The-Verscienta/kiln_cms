defmodule KilnCMS.CrawlerVerification do
  @moduledoc """
  Checks a search-engine claim against DNS (#2254): is a request whose
  `User-Agent` names Googlebot really from Google?

  The check is the one every engine documents: the address's PTR name must
  fall under the engine's domain (`KilnCMS.CrawlerVerification.Engines`), and
  that name's forward lookup must contain the address again. A PTR record is
  whatever the owner of the address's reverse zone wrote, so the forward
  lookup is what proves it.

  ## Never on the request path

  `check/3` never waits on DNS. It answers from a per-node cache; on a miss it
  starts a lookup in the background and answers `{:unverified, :pending}`, so
  a crawler's first request from a new address is judged before its result is
  known and its later requests are judged by it.

    * `:verified`: the claim is proven.
    * `:disabled`: verification is off (`enabled: false`); nothing is checked.
    * `{:unverified, :failed}`: the claim is proven false (no PTR record, a PTR
      name outside the engine's domain, or a forward lookup that does not
      contain the address).
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
      domain (DuckDuckBot).
    * `{:unverified, :not_public}`: the address is loopback, private, shared,
      in `TRUSTED_PROXIES`, or the caller says it came through a forwarding
      header nothing trusts (`forwarded_untrusted?: true`). Its PTR record says
      nothing about the client, so no lookup is made.

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
    * `:max_entries` (50,000), `:max_verified_entries` (10,000),
      `:max_concurrency` (16): read once, by
      `KilnCMS.CrawlerVerification.Supervisor`

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

  Two warnings are logged once per node: the first time the concurrency limit
  turns a lookup away, and after `:error_warning_after` lookups in a row could
  not reach an answer (a node with no DNS egress), naming
  `KILN_CRAWLER_VERIFICATION=false`.
  """

  require Logger

  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.InetResolver
  alias KilnCMS.CrawlerVerification.InFlight
  alias KilnCMS.Security.Cidr
  alias KilnCMSWeb.RateLimit

  @cache :kiln_cms_crawler_verification
  @verified_cache :kiln_cms_crawler_verification_verified
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
    lookups_per_minute: 600,
    prefix_lookups_per_minute: [
      inet: [{24, 30}, {16, 120}],
      inet6: [{64, 30}, {48, 60}, {32, 120}]
    ],
    rate_window_ms: :timer.minutes(1),
    rate_scope: "crawler_verify",
    error_warning_after: 20,
    health_window_ms: :timer.minutes(1),
    canary_address: {8, 8, 8, 8}
  ]

  # Error reasons named in telemetry; anything else is `:other`, so a metric
  # tag can never take an unbounded value.
  @error_reasons [:timeout, :servfail, :refused, :formerr, :notimp, :econnrefused, :nxdomain]

  @type reason ::
          :pending | :failed | :unverifiable | :not_public | :skipped | :error | :forward_error
  @type status :: :verified | :disabled | {:unverified, reason()}
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
  """
  @spec check(atom(), :inet.ip_address() | nil, keyword()) :: status()
  def check(engine, ip, opts \\ []) do
    config = config(opts)

    cond do
      config[:enabled] != true -> :disabled
      not Engines.verifiable?(engine) -> {:unverified, :unverifiable}
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

  # ---- check/3 --------------------------------------------------------------

  defp check_address(engine, ip, config) do
    if worth_a_lookup?(ip, config) do
      case cached(ip) do
        {:ok, stored} when not is_nil(stored) -> engine |> judge(stored) |> status(engine, stored)
        _miss -> request_lookup(engine, ip, config)
      end
    else
      {:unverified, :not_public}
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
    emit_lookup(engine, judge(engine, stored), System.monotonic_time() - started)
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
