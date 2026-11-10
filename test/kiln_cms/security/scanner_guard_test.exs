defmodule KilnCMS.Security.ScannerGuardTest do
  @moduledoc """
  Smart 404 blocking (#2253): thresholds, bait paths, expiry and the
  false-positive guards.

  `async: false`: the guard reads its settings from application env, the rule
  cache is one named Cachex instance, and `:trusted_proxies` is global.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CrawlerVerification
  alias KilnCMS.Security
  alias KilnCMS.Security.IpBlocklist
  alias KilnCMS.Security.ScannerGuard
  alias KilnCMS.SystemActor
  alias KilnCMS.Test.StubCrawlerResolver

  @moduletag :capture_log

  @ip {203, 0, 113, 9}
  @ua "curl/8.4"

  setup do
    previous_proxies = Application.get_env(:kiln_cms, :trusted_proxies)

    Application.put_env(:kiln_cms, :scanner_blocking,
      enabled: true,
      threshold: 3,
      bait_threshold: 2
    )

    IpBlocklist.clear()

    on_exit(fn ->
      Application.delete_env(:kiln_cms, :scanner_blocking)

      if previous_proxies,
        do: Application.put_env(:kiln_cms, :trusted_proxies, previous_proxies),
        else: Application.delete_env(:kiln_cms, :trusted_proxies)

      IpBlocklist.clear()
    end)

    :ok
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sg-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp conn(opts \\ []) do
    org = Keyword.get(opts, :org_id, org_id())

    conn =
      "GET"
      |> Plug.Test.conn(Keyword.get(opts, :path, "/nope"))
      |> Map.put(:remote_ip, Keyword.get(opts, :ip, @ip))
      |> Plug.Conn.put_req_header("user-agent", Keyword.get(opts, :ua, @ua))

    conn = if org, do: Plug.Conn.assign(conn, :current_org, %{id: org}), else: conn
    conn = if user = opts[:user], do: Plug.Conn.assign(conn, :current_user, user), else: conn
    conn = if m = opts[:method], do: %{conn | method: m}, else: conn

    Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
      Plug.Conn.put_req_header(c, k, v)
    end)
  end

  defp miss(times, path \\ "/nope", opts \\ []) do
    for _ <- 1..times do
      assert :ok = ScannerGuard.record_miss(conn(opts), path)
    end

    :ok
  end

  defp rules(tenant \\ org_id()), do: CMS.list_ip_block_rules!(actor: admin(), tenant: tenant)

  defp events(tenant \\ org_id()) do
    Security.list_events!(%{type: :ip_auto_blocked}, actor: admin(), tenant: tenant)
  end

  defp counter_rows do
    %{rows: [[n]]} =
      KilnCMS.Repo.query!("SELECT count(*) FROM throttle_counters WHERE bucket LIKE 'scanner_%'")

    n
  end

  describe "thresholds" do
    test "the miss after the threshold blocks the address for the block window" do
      miss(3)
      assert rules() == []
      assert events() == []

      miss(1)
      assert [rule] = rules()
      assert rule.cidr == "203.0.113.9/32"
      assert rule.note == ScannerGuard.note()

      seconds = DateTime.diff(rule.expires_at, DateTime.utc_now())
      assert seconds in 3_500..3_601
      assert IpBlocklist.blocked?(org_id(), @ip)
    end

    test "a window rollover forgets earlier misses" do
      miss(3)
      KilnCMS.Repo.query!("UPDATE throttle_counters SET window_index = window_index - 1")
      miss(1)

      assert rules() == []
    end

    test "a path is not needed to be distinct and a trailing slash does not hide a bait path" do
      miss(2, "/wp-login.php/")
      assert rules() == []
      miss(1, "/WP-LOGIN.PHP")
      assert [_] = rules()
    end
  end

  describe "bait paths" do
    test "trip at the bait threshold, well below the miss threshold" do
      miss(2, "/wp-login.php")
      assert rules() == []
      miss(1, "/wp-login.php")

      assert [_] = rules()
      assert [event] = events()
      assert event.metadata["reason"] == "bait_path"
    end

    test "a directory under a bait path counts, a lookalike does not" do
      miss(3, "/.git/config")
      assert [_] = rules()
    end

    test "ordinary missing pages do not trip the bait threshold" do
      miss(2, "/old-post")
      assert rules() == []
      miss(1, "/wp-login-help")
      assert rules() == []
    end
  end

  describe "expiry" do
    test "an expired block stops matching and a fresh trip blocks again" do
      miss(4)
      assert [first] = rules()

      KilnCMS.Repo.query!(
        "UPDATE ip_block_rules SET expires_at = now() - interval '1 minute' WHERE id = $1",
        [Ecto.UUID.dump!(first.id)]
      )

      IpBlocklist.clear()
      refute IpBlocklist.blocked?(org_id(), @ip)

      # The next block window: the trip claim is per window.
      KilnCMS.Repo.query!("DELETE FROM throttle_counters WHERE bucket = 'scanner_trip'")
      miss(1)

      assert [second] = rules()
      refute second.id == first.id
      assert DateTime.compare(second.expires_at, DateTime.utc_now()) == :gt
      assert IpBlocklist.blocked?(org_id(), @ip)
      assert length(events()) == 2
    end
  end

  describe "false-positive guards" do
    test "off by default: nothing is counted or written" do
      Application.delete_env(:kiln_cms, :scanner_blocking)
      refute ScannerGuard.enabled?()

      miss(10)
      miss(5, "/wp-login.php")

      assert counter_rows() == 0
      assert rules() == []
    end

    test "loopback, private, unique-local and CGNAT addresses are never counted" do
      for ip <- [
            {127, 0, 0, 1},
            {10, 0, 0, 5},
            {172, 20, 1, 1},
            {192, 168, 1, 1},
            {169, 254, 1, 1},
            {100, 64, 1, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 1}
          ] do
        miss(10, "/wp-login.php", ip: ip)
      end

      assert counter_rows() == 0
      assert rules() == []
    end

    test "a signed-in visitor is not counted" do
      miss(10, "/wp-login.php", user: %{id: "u"})
      assert counter_rows() == 0
    end

    test "a browser navigation (Sec-Fetch headers) is not counted" do
      miss(10, "/wp-login.php", headers: [{"sec-fetch-mode", "navigate"}])
      miss(10, "/wp-login.php", headers: [{"sec-fetch-dest", "document"}])
      miss(10, "/wp-login.php", headers: [{"sec-fetch-site", "cross-site"}])
      assert counter_rows() == 0
    end

    test "a same-origin or direct fetch with no other Sec-Fetch header still counts" do
      miss(4, "/nope", headers: [{"sec-fetch-site", "same-origin"}])
      assert [_] = rules()
    end

    test "only GET and HEAD are counted" do
      miss(10, "/wp-login.php", method: "POST")
      assert counter_rows() == 0

      miss(4, "/nope", method: "HEAD")
      assert [_] = rules()
    end

    test "a trusted proxy range is never counted" do
      Application.put_env(:kiln_cms, :trusted_proxies, ["203.0.113.0/24"])
      miss(10, "/wp-login.php")
      assert counter_rows() == 0
    end

    test "a forwarding header with no trusted proxy configured is never counted" do
      Application.put_env(:kiln_cms, :trusted_proxies, [])
      miss(10, "/wp-login.php", headers: [{"x-forwarded-for", "198.51.100.7"}])
      assert counter_rows() == 0
    end

    test "an address the list already blocks is not counted further" do
      CMS.create_ip_block_rule!(%{cidr: "203.0.113.9", confirm_self_block: true},
        actor: admin(),
        tenant: org_id()
      )

      IpBlocklist.clear()
      miss(10)
      assert counter_rows() == 0
    end

    test "a request with no resolved site is not counted" do
      miss(10, "/nope", org_id: nil)
      assert counter_rows() == 0
    end

    test "an address that signed in here recently is not blocked, an old sign-in does not protect it" do
      Ash.Seed.seed!(Security.Event, %{
        org_id: org_id(),
        type: :sign_in,
        ip: "203.0.113.9",
        inserted_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
      })

      miss(4)
      assert rules() == []
      assert events() == []

      KilnCMS.Repo.query!("DELETE FROM throttle_counters WHERE bucket = 'scanner_trip'")
      KilnCMS.Repo.query!("DELETE FROM security_events")

      Ash.Seed.seed!(Security.Event, %{
        org_id: org_id(),
        type: :sign_in,
        ip: "203.0.113.9",
        inserted_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      })

      miss(1)
      assert [_] = rules()
    end
  end

  describe "search-engine claims (#2254)" do
    @googlebot "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

    # Each test gets an address of its own (results are cached per address)
    # and a rate-limit scope of its own (lookup budgets are per network, and
    # every address here is in 66.249/16).
    setup do
      previous = Application.get_env(:kiln_cms, CrawlerVerification)

      Application.put_env(
        :kiln_cms,
        CrawlerVerification,
        Keyword.put(previous || [], :rate_scope, "sg-cv-#{System.unique_integer([:positive])}")
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, CrawlerVerification, previous),
          else: Application.delete_env(:kiln_cms, CrawlerVerification)
      end)

      ip = KilnCMS.Test.PublicAddress.v4()
      CrawlerVerification.forget(ip)
      StubCrawlerResolver.reset(ip)
      on_exit(fn -> CrawlerVerification.forget(ip) end)

      %{ip: ip}
    end

    test "a verified claim is exempt from the miss threshold, not from bait paths", %{ip: ip} do
      CrawlerVerification.put_result(:google, ip, :verified)

      miss(10, "/gone", ua: @googlebot, ip: ip)
      assert rules() == []

      miss(3, "/wp-login.php", ua: @googlebot, ip: ip)
      assert [_] = rules()
    end

    test "a claim whose lookup has not finished is exempt", %{ip: ip} do
      StubCrawlerResolver.put_ptr(ip, {:block, self()})

      miss(10, "/gone", ua: @googlebot, ip: ip)
      assert rules() == []

      # One lookup, still waiting on DNS, for all ten misses.
      assert_receive {StubCrawlerResolver, :blocked, resolver, _callers, :ptr, ^ip}
      assert StubCrawlerResolver.calls(:ptr, ip) == 1
      StubCrawlerResolver.release(resolver)
    end

    test "a claim DNS proved false is counted like any other client", %{ip: ip} do
      CrawlerVerification.put_result(:google, ip, {:rejected, :wrong_domain})

      miss(3, "/gone", ua: @googlebot, ip: ip)
      assert rules() == []
      miss(1, "/gone", ua: @googlebot, ip: ip)
      assert [event] = events()
      assert event.metadata["reason"] == "miss_threshold"
    end

    test "a resolver error is not a proof: still exempt", %{ip: ip} do
      CrawlerVerification.put_result(:google, ip, {:error, :timeout})

      miss(10, "/gone", ua: @googlebot, ip: ip)
      assert rules() == []
    end

    test "with verification off, the engine's name is enough, and nothing is looked up",
         %{ip: ip} do
      previous = Application.get_env(:kiln_cms, CrawlerVerification, [])
      Application.put_env(:kiln_cms, CrawlerVerification, Keyword.put(previous, :enabled, false))

      miss(10, "/gone", ua: @googlebot, ip: ip)
      assert rules() == []
      assert StubCrawlerResolver.calls(:ptr, ip) == 0

      miss(3, "/wp-login.php", ua: @googlebot, ip: ip)
      assert [_] = rules()
    end

    test "with verification off, a planted failure is not read", %{ip: ip} do
      CrawlerVerification.put_result(:google, ip, {:rejected, :no_ptr})
      previous = Application.get_env(:kiln_cms, CrawlerVerification, [])
      Application.put_env(:kiln_cms, CrawlerVerification, Keyword.put(previous, :enabled, false))

      miss(10, "/gone", ua: @googlebot, ip: ip)
      assert rules() == []
    end

    for ua <- [
          "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
          "Twitterbot/1.0",
          "LinkedInBot/1.0 (compatible; Mozilla/5.0; Apache-HttpClient +http://www.linkedin.com)",
          "Mozilla/5.0 (compatible; Yahoo! Slurp; http://help.yahoo.com/help/us/ysearch/slurp)"
        ] do
      test "#{ua |> String.split(["/", " "]) |> hd()} is not exempt", %{ip: ip} do
        miss(4, "/gone", ua: unquote(ua), ip: ip)
        assert [_] = rules()
        assert StubCrawlerResolver.calls(:ptr, ip) == 0
      end
    end

    test "a link-preview fetcher is not exempt with verification off either", %{ip: ip} do
      previous = Application.get_env(:kiln_cms, CrawlerVerification, [])
      Application.put_env(:kiln_cms, CrawlerVerification, Keyword.put(previous, :enabled, false))

      miss(4, "/gone", ua: "facebookexternalhit/1.1", ip: ip)
      assert [_] = rules()
    end
  end

  describe "isolation" do
    test "one org's trip does not block the same address in another" do
      other = org("sg-other")

      miss(4)
      assert [_] = rules()

      assert rules(other.id) == []
      refute IpBlocklist.blocked?(other.id, @ip)

      # Its own misses are counted separately, not carried over.
      miss(2, "/nope", org_id: other.id)
      assert rules(other.id) == []
    end

    test "an IPv6 client is counted and blocked as its /64" do
      miss(2, "/nope", ip: {0x2001, 0xDB8, 1, 2, 0, 0, 0, 5})
      miss(2, "/nope", ip: {0x2001, 0xDB8, 1, 2, 9, 9, 9, 9})

      assert [rule] = rules()
      assert rule.cidr == "2001:db8:1:2::/64"
    end
  end

  describe "the event" do
    test "carries the address and only the allowlisted metadata, never the path" do
      miss(3, "/wp-login.php")

      assert [event] = events()
      assert event.type == :ip_auto_blocked
      assert event.ip == "203.0.113.9"
      assert event.actor_id == nil

      assert event.metadata == %{
               "reason" => "bait_path",
               "count" => 2,
               "window_minutes" => 10,
               "block_minutes" => 60
             }

      refute inspect(event.metadata) =~ "wp-login"
    end

    test "a second trip in the same block window writes no second rule or event" do
      miss(4)
      KilnCMS.Repo.query!("DELETE FROM ip_block_rules")
      IpBlocklist.clear()

      miss(3)

      assert rules() == []
      assert length(events()) == 1
    end

    test "a sampled telemetry counter fires once per block" do
      test_pid = self()
      handler = "sg-blocked-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :scanner_guard, :blocked],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:blocked, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      miss(4)
      assert_received {:blocked, %{count: 1}, %{reason: "miss_threshold"}}
    end
  end

  describe "the cap" do
    test "at the cap a new trip is skipped, not an old rule evicted" do
      Application.put_env(:kiln_cms, :scanner_blocking,
        enabled: true,
        threshold: 3,
        max_auto_rules: 2
      )

      for n <- 1..2 do
        Ash.Seed.seed!(CMS.IpBlockRule, %{
          cidr: "198.51.100.#{n}/32",
          note: ScannerGuard.note(),
          org_id: org_id(),
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        })
      end

      # An operator's own rule and an expired automatic one do not count.
      Ash.Seed.seed!(CMS.IpBlockRule, %{cidr: "198.51.100.50/32", org_id: org_id()})

      miss(4)
      assert length(rules()) == 3
      refute IpBlocklist.blocked?(org_id(), @ip)
      assert events() == []
    end

    test "below the cap, expired and manual rules are not counted against it" do
      Application.put_env(:kiln_cms, :scanner_blocking,
        enabled: true,
        threshold: 3,
        max_auto_rules: 1
      )

      Ash.Seed.seed!(CMS.IpBlockRule, %{
        cidr: "198.51.100.1/32",
        note: ScannerGuard.note(),
        org_id: org_id(),
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

      Ash.Seed.seed!(CMS.IpBlockRule, %{cidr: "198.51.100.2/32", note: "mine", org_id: org_id()})

      miss(4)
      assert IpBlocklist.blocked?(org_id(), @ip)
    end
  end

  describe "failure" do
    test "a refused block (lost grant) is swallowed and nothing is written" do
      SystemActor.with_override(:scanner_guard, nil, fn ->
        assert :ok = ScannerGuard.record_miss(conn(), "/nope")
        miss(4)
      end)

      assert rules() == []
      assert events() == []
    end

    test "a malformed call still returns :ok" do
      assert :ok = ScannerGuard.record_miss(%Plug.Conn{remote_ip: nil, method: "GET"}, "/x")
      assert :ok = ScannerGuard.record_miss(:not_a_conn, "/x")
    end
  end

  describe "policy: the sign-in read" do
    test "only :scanner_guard may run sign_in_from_ip; other system actors and people are refused" do
      since = DateTime.add(DateTime.utc_now(), -3_600, :second)

      Ash.Seed.seed!(Security.Event, %{
        org_id: org_id(),
        type: :sign_in,
        ip: "203.0.113.9"
      })

      assert {:ok, [_]} =
               Security.sign_in_events_from_ip("203.0.113.9", since,
                 actor: SystemActor.new(:scanner_guard),
                 tenant: org_id(),
                 authorize_with: :error
               )

      for actor <- [SystemActor.new(:security), SystemActor.new(:ip_block), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Security.sign_in_events_from_ip("203.0.113.9", since,
                   actor: actor,
                   tenant: org_id(),
                   authorize_with: :error
                 )
      end

      # And the guard cannot read the plain log.
      assert {:error, %Ash.Error.Forbidden{}} =
               Security.list_events(
                 actor: SystemActor.new(:scanner_guard),
                 tenant: org_id(),
                 authorize_with: :error
               )
    end
  end
end
