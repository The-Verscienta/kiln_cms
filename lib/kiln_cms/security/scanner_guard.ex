defmodule KilnCMS.Security.ScannerGuard do
  @moduledoc """
  Smart 404 blocking (#2253): an address that racks up delivery 404s inside a
  window, or probes "bait" paths no site of ours serves, gets a temporary
  `KilnCMS.CMS.IpBlockRule` (#2242) and a `:ip_auto_blocked` security event
  (#2241).

  **Off by default** (`config :kiln_cms, :scanner_blocking, enabled: false`;
  `KILN_SCANNER_BLOCKING=1` turns it on). With it off, `record_miss/2` returns
  before reading anything and no counter row is written.

  ## Where it is called

  From `KilnCMSWeb.ContentController`'s `not_found/2`, after the alias table,
  the redirect table and the paywall teaser have all missed, so a redirect-
  managed path never counts. Only that funnel: API, media and static 404s are
  not counted, and neither is a non-`GET`/`HEAD` request (the `unlock` POST).

  ## What counts

  Every miss charges `threshold` per `window_ms` (default 60 per 10 minutes) for
  the address; a miss on a bait path (`bait_paths`, matched on the normalized,
  case-folded path, exactly or as a directory prefix) also charges the stricter
  `bait_threshold` (default 5). The window is a *fixed*, epoch-aligned window
  (`KilnCMS.Accounts.ThrottleStore`), not a sliding one: a burst straddling a
  boundary is split across two windows. Counters live in the shared throttle
  table, so they hold across nodes and need no memory of their own.

  IPv6 clients are counted and blocked as their `/64`: a host rotates through
  its whole prefix for free. IPv4 is `/32`.

  ## What never counts (false-positive guards)

    * the guard is off; or the request is not `GET`/`HEAD`; or the site is unknown
    * a signed-in visitor
    * a request that looks like a browser: it carries `Sec-Fetch-Mode` or
      `-Dest`, or a `Sec-Fetch-Site` other than `none`/`same-origin`. Scanners
      and scripts do not send them; a person following a stale link does. This
      is the lure guard: a hostile page cannot make a visitor's browser rack up
      misses against us. (Header absence is not proof of a scanner, and a
      scanner can send them: the threshold is the real control.)
    * loopback, private (RFC 1918), unique-local, link-local and CGNAT
      (`100.64.0.0/10`) addresses, unspecified, multicast and reserved ones
      (anything `Cidr.public_unicast?/1` refuses), and any `TRUSTED_PROXIES`
      range: those are a proxy, a health check or a whole office behind one
      NAT, never one scanner
    * a request carrying a forwarding header while no proxy is trusted
      (`Plugs.ClientIp.untrusted_forwarding?/1`): `remote_ip` is then the
      proxy's, and blocking it would block the site
    * an address the block list already matches
    * a search-engine claim (`KilnCMS.BotClass.search_engine/1`: Googlebot,
      bingbot, ...) is exempt from the miss threshold only, and only until
      `KilnCMS.CrawlerVerification` proves it false (#2254): verified, pending
      and skipped claims keep the exemption, a claim whose address fails the
      reverse-DNS check counts like any other client. A claim whose PTR query
      got no answer (a timeout, SERVFAIL) keeps it only while this node's
      resolver is itself failing (`CrawlerVerification.resolver_failing?/1`,
      #2588): while other lookups get answers, the silence is the address's
      own reverse zone, which a scanner can choose, and its misses count. A
      claim whose PTR named a host under the engine's domain and whose
      forward query for that host got no answer, with its full time budget,
      keeps it: that silence is the engine's own zone. With
      verification off (`KILN_CRAWLER_VERIFICATION=false`) the engine's name
      in the user agent is enough. Link-preview fetchers (facebookexternalhit,
      Twitterbot, LinkedInBot) and Slurp are not exempt. **Bait paths count
      for everyone**: no crawler has a reason to ask for one.

  At the moment of the trip the block is also skipped when the address has a
  successful `:sign_in` event on this site in the last 24 hours (one indexed
  read): a person behind a shared address who can sign in is not a scanner.

  ## The block

  One rule per address, `block_ms` long (default 60 minutes), with the fixed
  note "Automatic: scanner 404s", created as the `:scanner_guard`
  system actor, which the `IpBlockRule` policy admits to `:create` and nothing
  else. A false positive heals itself when the rule expires, or an admin deletes
  it in the console. The trip is claimed once per block window
  (`ThrottleStore.hit/5` with a limit of 1), so a flood from one address writes
  one rule and one event, not thousands. Automatic rules are capped per org
  (`max_auto_rules/0`); at the cap a new trip is logged and skipped rather than
  evicting a rule, because the guard may not delete (see the policy).

  ## Off the request path, failing open

  The counting and the write run in a supervised task like
  `KilnCMSWeb.MissedPathTracking`. A saturated supervisor drops the count (the
  guard fails open), a database fault is swallowed and logged without an
  address, and the 404 renders either way. Under test (`:async_analytics`
  false) the work runs inline.

  The `:ip_auto_blocked` event carries only `reason`, `count` (the threshold
  that was crossed), `window_minutes` and `block_minutes`. The path is
  attacker-controlled and is never recorded; the address is the event's `ip`.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.BotClass
  alias KilnCMS.CMS
  alias KilnCMS.CrawlerVerification
  alias KilnCMS.Security
  alias KilnCMS.Security.Cidr
  alias KilnCMS.Security.IpBlocklist
  alias KilnCMS.Security.Recorder
  alias KilnCMS.SystemActor
  alias KilnCMSWeb.Plugs.ClientIp

  @miss_bucket "scanner_404"
  @bait_bucket "scanner_bait"
  @trip_bucket "scanner_trip"

  @note "Automatic: scanner 404s"
  @note_prefix "Automatic:"

  @recent_sign_in_hours 24

  # The search engines whose name in a user agent exempts a request from the
  # miss threshold while crawler verification is off. With it on, the claim is
  # read by `BotClass.search_engine/1` and checked instead (`good_bot?/2`).
  @search_bots ~w(googlebot bingbot duckduckbot applebot yandexbot baiduspider)

  @defaults [
    enabled: false,
    threshold: 60,
    window_ms: :timer.minutes(10),
    block_ms: :timer.minutes(60),
    bait_threshold: 5,
    # Automatic rules the guard may hold at once per org. A scanner spread over
    # hundreds of addresses cannot grow the list (and the matcher's cache)
    # without bound.
    max_auto_rules: 300,
    bait_paths: ~w(
      /wp-login.php /xmlrpc.php /wp-admin /wp-includes /.env /.git /.aws /.ssh
      /phpmyadmin /pma /cgi-bin /actuator /boaform /server-status /vendor/phpunit
      /admin.php /config.php /shell.php /eval-stdin.php
    )
  ]

  @doc "The effective settings: compiled defaults, then `config :kiln_cms, :scanner_blocking`."
  @spec config() :: keyword()
  def config, do: Keyword.merge(@defaults, Application.get_env(:kiln_cms, :scanner_blocking, []))

  @doc "Is the guard on? Off unless an operator turned it on."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.fetch!(config(), :enabled) == true

  @doc "Most automatic rules one org may hold at once."
  @spec max_auto_rules() :: pos_integer()
  def max_auto_rules, do: Keyword.fetch!(config(), :max_auto_rules)

  @doc "The note every automatic rule carries."
  @spec note() :: String.t()
  def note, do: @note

  @doc """
  Count a delivery 404 for `path` (the string `Redirects.resolve/3` was asked
  for) on `conn`, blocking the address if it trips a threshold.

  Always returns `:ok` and never raises: it is called on the way to rendering a
  404.
  """
  @spec record_miss(Plug.Conn.t(), String.t()) :: :ok
  def record_miss(%Plug.Conn{} = conn, path) when is_binary(path) do
    if enabled?() do
      case context(conn, path) do
        {:ok, ctx} -> dispatch(ctx)
        :skip -> :ok
      end
    end

    :ok
  rescue
    # A real boundary: the caller is rendering a 404 and nothing here may
    # change that. The failure is logged without the address or path.
    _error ->
      Logger.warning("ScannerGuard: could not evaluate a 404; failing open")
      :ok
  catch
    :exit, _reason -> :ok
  end

  def record_miss(_conn, _path), do: :ok

  # ---- the pure, in-request part --------------------------------------------

  defp context(conn, path) do
    with true <- conn.method in ["GET", "HEAD"],
         %{id: org_id} <- conn.assigns[:current_org],
         nil <- conn.assigns[:current_user],
         ip when is_tuple(ip) <- conn.remote_ip,
         true <- Cidr.public_unicast?(ip),
         false <- trusted_proxy?(ip),
         false <- ClientIp.untrusted_forwarding?(conn.req_headers),
         false <- browser_like?(conn),
         {:ok, cidr} <- block_cidr(ip) do
      {:ok,
       %{
         org_id: org_id,
         ip: ip,
         cidr: cidr,
         key: "#{org_id}|#{cidr}",
         bait?: bait?(path),
         bot?: good_bot?(conn, ip),
         request: Recorder.request_context(conn)
       }}
    else
      _skip -> :skip
    end
  end

  defp trusted_proxy?(ip) do
    :kiln_cms
    |> Application.get_env(:trusted_proxies, [])
    |> Enum.any?(&Cidr.contains?(to_string(&1), ip))
  end

  defp browser_like?(conn) do
    present? = fn name -> Plug.Conn.get_req_header(conn, name) != [] end

    present?.("sec-fetch-mode") or present?.("sec-fetch-dest") or cross_site?(conn)
  end

  defp cross_site?(conn) do
    case Plug.Conn.get_req_header(conn, "sec-fetch-site") do
      [] -> false
      [site | _] -> String.downcase(site) not in ["none", "same-origin"]
    end
  end

  # A search-engine claim is exempt from the miss threshold unless DNS has
  # proven it false (#2254): a lookup still pending or skipped keeps the
  # exemption, so a real crawler's first misses from a new address never
  # count. An unanswered PTR query keeps it only while the resolver itself is
  # failing (#2588); otherwise the silence is the address's own reverse zone.
  # An unanswered forward query for an engine-domain name, given its full
  # budget, keeps it.
  # `context/2` has already turned away untrusted forwarding and non-public
  # addresses, so the check sees the client's own address. With verification
  # off, the name in the user agent is enough, as before.
  defp good_bot?(conn, ip) do
    ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")

    if CrawlerVerification.enabled?() do
      case BotClass.search_engine(ua) do
        nil -> false
        engine -> exempt_claim?(CrawlerVerification.check(engine, ip))
      end
    else
      lowered = String.downcase(ua)
      Enum.any?(@search_bots, &String.contains?(lowered, &1))
    end
  end

  # A forward query that got no answer for a name under the engine's own
  # domain, with its full time budget, is silence in the engine's zone, which
  # a scanner cannot cause from its own reverse zone, so it keeps the
  # exemption like a pending one. One a slow PTR answer starved is `:error`.
  defp exempt_claim?({:unverified, :failed}), do: false
  defp exempt_claim?({:unverified, :forward_error}), do: true
  defp exempt_claim?({:unverified, :error}), do: CrawlerVerification.resolver_failing?()
  defp exempt_claim?(_verified_or_unproven), do: true

  defp bait?(path) do
    normalized = path |> String.downcase() |> String.trim_trailing("/")

    Enum.any?(config()[:bait_paths], fn bait ->
      bait = String.downcase(bait)
      normalized == bait or String.starts_with?(normalized, bait <> "/")
    end)
  end

  # One normalised spelling for the counter key and the rule: IPv4 is a /32, an
  # IPv6 address (not a mapped IPv4) is its /64.
  defp block_cidr(ip) do
    text = ip |> :inet.ntoa() |> to_string()

    case Cidr.parse(text) do
      {:ok, {:inet, _, _} = cidr} ->
        {:ok, Cidr.format(cidr)}

      {:ok, {:inet6, _, _}} ->
        with {:ok, cidr} <- Cidr.parse(text <> "/64"), do: {:ok, Cidr.format(cidr)}

      _invalid ->
        :error
    end
  end

  # ---- the off-request part -------------------------------------------------

  # `:async_analytics` is off under test, where a detached task would run
  # outside the SQL sandbox connection. `start_child/2` is a call, so a
  # restarting supervisor exits the caller; this sits on the error path.
  defp dispatch(ctx) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn -> run(ctx) end)
    else
      run(ctx)
    end
  catch
    :exit, _reason -> :ok
  end

  defp run(ctx) do
    # Once blocked, stop charging: the counters would only grow.
    if not IpBlocklist.blocked?(ctx.org_id, ctx.ip) do
      case tripped(ctx, config()) do
        nil -> :ok
        {reason, limit} -> trip(ctx, reason, limit, config())
      end
    end

    :ok
  rescue
    _error ->
      Logger.warning("ScannerGuard: could not count a 404; failing open")
      :ok
  catch
    :exit, _reason -> :ok
  end

  # `{reason, crossed_limit}` for the threshold this miss crossed, else nil.
  defp tripped(ctx, config) do
    window = config[:window_ms]

    miss =
      if ctx.bot?,
        do: :allow,
        else: verdict(ThrottleStore.hit(@miss_bucket, ctx.key, window, config[:threshold]))

    bait =
      if ctx.bait?,
        do: verdict(ThrottleStore.hit(@bait_bucket, ctx.key, window, config[:bait_threshold])),
        else: :allow

    cond do
      bait == :deny -> {"bait_path", config[:bait_threshold]}
      miss == :deny -> {"miss_threshold", config[:threshold]}
      true -> nil
    end
  end

  defp verdict({:allow, _count}), do: :allow
  defp verdict({:deny, _retry_after}), do: :deny

  defp trip(ctx, reason, limit, config) do
    # Claim the trip once per block window: only the first caller writes.
    case ThrottleStore.hit(@trip_bucket, ctx.key, config[:block_ms], 1) do
      {:allow, 1} -> block(ctx, reason, limit, config)
      _already_claimed -> :ok
    end
  end

  defp block(ctx, reason, limit, config) do
    cond do
      recent_sign_in?(ctx) -> :ok
      at_cap?(ctx) -> log_skip("at the automatic rule cap")
      true -> create_rule(ctx, reason, limit, config)
    end
  end

  defp create_rule(ctx, reason, limit, config) do
    params = %{
      cidr: ctx.cidr,
      note: @note,
      expires_at: DateTime.add(DateTime.utc_now(), config[:block_ms], :millisecond),
      confirm_self_block: true
    }

    case CMS.create_ip_block_rule(params,
           actor: SystemActor.resolve(:scanner_guard),
           tenant: ctx.org_id
         ) do
      {:ok, _rule} ->
        announce(ctx, reason, limit, config)

      {:error, _error} ->
        # An active duplicate (already blocked), a refused range or a database
        # fault: nothing to report, and no address in the log.
        log_skip("could not store the rule")
    end
  end

  defp announce(ctx, reason, limit, config) do
    :telemetry.execute([:kiln_cms, :scanner_guard, :blocked], %{count: 1}, %{reason: reason})

    Recorder.record_after_commit(:ip_auto_blocked,
      tenant: ctx.org_id,
      request: ctx.request,
      metadata: %{
        "reason" => reason,
        "count" => limit,
        "window_minutes" => div(config[:window_ms], 60_000),
        "block_minutes" => div(config[:block_ms], 60_000)
      }
    )
  end

  # A person who signed in from this address recently is not a scanner. A read
  # that cannot be made leans toward not blocking.
  defp recent_sign_in?(ctx) do
    since = DateTime.add(DateTime.utc_now(), -@recent_sign_in_hours * 3_600, :second)

    case ctx.request.ip &&
           Security.sign_in_events_from_ip(ctx.request.ip, since,
             actor: SystemActor.resolve(:scanner_guard),
             tenant: ctx.org_id,
             authorize_with: :error,
             query: [limit: 1]
           ) do
      {:ok, [_ | _]} -> true
      {:ok, []} -> false
      nil -> false
      {:error, _error} -> true
    end
  end

  defp at_cap?(ctx) do
    now = DateTime.utc_now()
    prefix = @note_prefix
    cap = max_auto_rules()

    query =
      CMS.IpBlockRule
      |> Ash.Query.filter(
        not is_nil(expires_at) and expires_at > ^now and string_starts_with(note, ^prefix)
      )
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(cap)

    case CMS.list_ip_block_rules(
           actor: SystemActor.resolve(:ip_block),
           tenant: ctx.org_id,
           authorize_with: :error,
           query: query
         ) do
      {:ok, rules} -> length(rules) >= cap
      {:error, _error} -> true
    end
  end

  defp log_skip(why), do: Logger.warning("ScannerGuard: block skipped, #{why}")
end
