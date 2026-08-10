defmodule KilnCMS.CMS.MissedPathTest do
  @moduledoc """
  The aggregated 404 counter (#472): what delivery records, what it refuses to
  record, and the bounds that keep an anonymously-writable table from becoming
  a liability.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  alias KilnCMS.CMS
  alias KilnCMS.CMS.MissedPath

  # `config :kiln_cms, :async_analytics, false` (config/test.exs) keeps the
  # recorder inline, on the request's sandbox-owned connection — a detached task
  # would run outside the ExUnit SQL sandbox. Don't touch that setting here:
  # deleting it rather than restoring it leaks `true` into every later test.
  setup do
    settings = Application.get_env(:kiln_cms, :missed_paths)

    on_exit(fn ->
      if settings,
        do: Application.put_env(:kiln_cms, :missed_paths, settings),
        else: Application.delete_env(:kiln_cms, :missed_paths)
    end)
  end

  defp rows do
    MissedPath
    |> Ash.Query.sort(path: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp visit(conn, path), do: get(conn, path)

  test "an unresolvable path is recorded once, then counted", %{conn: conn} do
    visit(conn, "/no-such-page")
    visit(build_conn(), "/no-such-page")

    assert [row] = rows()
    assert row.path == "/no-such-page"
    assert row.count == 2
    assert row.locale == "en"
    assert row.last_seen_at
  end

  test "a trailing slash lands on the same counter as the bare path", %{conn: conn} do
    visit(conn, "/legacy-page")
    visit(build_conn(), "/legacy-page/")

    assert [%{path: "/legacy-page", count: 2}] = rows()
  end

  test "deep legacy paths — the whole point after a migration — are recorded", %{conn: conn} do
    visit(conn, "/2019/05/old-post")

    assert [%{path: "/2019/05/old-post"}] = rows()
  end

  # The recorded path must be the one `Redirects.resolve/3` is asked for, or the
  # tab's one-click redirect writes a row that can never fire — and every
  # spelling of one URL burns its own capped slot.
  test "the path is recorded as delivery resolves it, not as it was typed", %{conn: conn} do
    visit(conn, "/blog/gone")
    # Empty segments collapse when the router splits the target, so this is the
    # same route and must be the same counter — `conn.request_path` keeps them.
    visit(build_conn(), "/blog//gone")

    assert [%{path: "/blog/gone", count: 2}] = rows()
  end

  test "a percent-encoded path is recorded decoded, so a redirect for it fires", %{conn: conn} do
    visit(conn, "/caf%C3%A9-gone")

    assert [%{path: "/café-gone"}] = rows()
  end

  test "a query string never reaches the row", %{conn: conn} do
    visit(conn, "/secret-thing?token=abc123")

    assert [%{path: "/secret-thing"}] = rows()
  end

  test "a served page records nothing", %{conn: conn} do
    page =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Live",
        slug: "live-#{System.unique_integer([:positive])}",
        state: :published
      })

    visit(conn, "/#{page.slug}")

    assert rows() == []
  end

  describe "the junk filter" do
    test "drops vulnerability probing and asset fetches" do
      for path <- [
            "/wp-login.php",
            "/xmlrpc.php",
            "/.git/config",
            "/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php",
            "/.well-known/traffic-advice",
            "/static/app.js",
            "/images/hero.png",
            "/config.yml"
          ] do
        visit(build_conn(), path)
      end

      assert rows() == []
    end

    # #920. `junk_extension?/1` reads only the last dot-separated piece of the
    # basename, so `/.env` was dropped while `/.env.local` was recorded —
    # `"local"` is not a listed extension. One scanner family per line here, and
    # each one was spending a capped slot.
    test "drops the dotfile families a last-segment extension check misses" do
      for path <- [
            "/.env.local",
            "/.env.production",
            "/.ssh/id_rsa",
            "/.aws/credentials",
            "/.svn/entries",
            "/.DS_Store",
            "/.htaccess",
            "/nested/.env.local"
          ] do
        visit(build_conn(), path)
      end

      assert rows() == []
    end

    test "drops the scanner roots that have no content behind them" do
      for path <- [
            "/wp-admin",
            "/wp-admin/setup-config.php",
            "/wp-includes/x",
            "/actuator/health"
          ] do
        visit(build_conn(), path)
      end

      assert rows() == []
    end

    # The counterweight to the rule above: `/wp-content` misses are real inbound
    # links after a WordPress migration, which is the whole reason this feature
    # exists. A filter that swallowed them would be worse than no filter.
    test "keeps /wp-content, which is real inbound traffic after a migration", %{conn: conn} do
      visit(conn, "/wp-content/uploads/2019/logo-page")

      assert [%{path: "/wp-content/uploads/2019/logo-page"}] = rows()
    end

    test "keeps .html — the legacy paths a static-site migration leaves behind", %{conn: conn} do
      visit(conn, "/about.html")

      assert [%{path: "/about.html"}] = rows()
    end

    test "drops an absurdly long path", %{conn: conn} do
      visit(conn, "/" <> String.duplicate("a", 300))

      assert rows() == []
    end
  end

  # An anonymous writer can ask for a million distinct paths; the cap is what
  # stops that from becoming a million rows.
  describe "the per-org cap" do
    setup do
      Application.put_env(:kiln_cms, :missed_paths, max_paths: 2)
      :ok
    end

    test "holds the table at max_paths", %{conn: conn} do
      for path <- ["/one", "/two", "/three", "/four"], do: visit(build_conn(), path)

      assert length(rows()) == 2

      # A path already counted keeps counting.
      visit(conn, "/four")
      assert Enum.find(rows(), &(&1.path == "/four")).count == 2
    end

    # Refusing new rows at the cap would let one cheap flood pin the table full
    # of one-hit junk and deny the feature permanently. Eviction means a genuine
    # URL can only be displaced by a path with *more* real traffic behind it.
    test "evicts the least-requested row rather than refusing the new one", %{conn: conn} do
      # `/popular` earns its place; `/junk` is a single probe.
      for _ <- 1..5, do: visit(build_conn(), "/popular")
      visit(build_conn(), "/junk")

      assert length(rows()) == 2

      visit(conn, "/newly-broken")

      paths = Enum.map(rows(), & &1.path)
      assert "/popular" in paths
      assert "/newly-broken" in paths
      refute "/junk" in paths
    end

    # #920, and the direction is the entire finding. Both rows below have a
    # count of 1, so the tie-break decides — and it used to be `last_seen_at:
    # :asc`, which evicts the OLDEST equal-count row. That is the genuine miss
    # recorded weeks ago, while the rows that caused the cap (an attacker's
    # fresh junk) are the newest and were chosen last. A flood at the
    # `:delivery` bucket's 300/min would clear every real row inside twenty
    # minutes and then hold the table.
    test "among equal counts it evicts the newest row, not the oldest", %{conn: conn} do
      visit(build_conn(), "/genuine-old-miss")
      visit(build_conn(), "/attacker-junk")

      assert length(rows()) == 2

      visit(conn, "/attacker-junk-2")

      paths = Enum.map(rows(), & &1.path)
      assert "/genuine-old-miss" in paths
      assert "/attacker-junk-2" in paths
      refute "/attacker-junk" in paths
    end
  end

  # #920. At the cap, every 404 on a new path runs the eviction read — on the
  # public, unauthenticated delivery path, against the pool that renders pages.
  # Unindexed that is a seq scan plus a top-N sort of the whole capped table.
  describe "the eviction index" do
    # `enable_seqscan = off` because the test table is tiny and Postgres would
    # rightly scan it; the question here is not what the planner prefers today
    # but whether the index CAN serve this sort at all, which is a property of
    # the column directions and nothing else.
    defp eviction_plan do
      KilnCMS.Repo.query!("SET enable_seqscan = off")

      %{rows: rows} =
        KilnCMS.Repo.query!("""
        EXPLAIN SELECT id FROM missed_paths
        WHERE org_id = '00000000-0000-0000-0000-000000000000'
        ORDER BY count ASC, last_seen_at DESC LIMIT 1
        """)

      Enum.map_join(rows, "\n", &List.first/1)
    end

    test "serves the eviction sort with no sort node at all" do
      plan = eviction_plan()

      assert plan =~ "missed_paths_eviction_index"

      # The assertion that would have caught the first version of this index.
      # It was all-ascending while the sort is `count ASC, last_seen_at DESC`,
      # and a btree is walked forward or backward as a whole — so the plan was
      # `Incremental Sort -> Index Scan`. Harmless-looking, and exactly wrong in
      # the case that matters: under a flood nearly every row has `count = 1`,
      # so the first group is nearly the whole table.
      refute plan =~ "Sort"
    end

    # The SQL above is hand-written, so it can drift from what `evict/1` asks
    # for and keep passing while the real query goes back to scanning. This
    # pins the two together.
    test "and the directions it is built for are the ones evict/1 sorts by" do
      source = File.read!("lib/kiln_cms_web/missed_path_tracking.ex")

      assert source =~ "sort(count: :asc, last_seen_at: :desc)"
    end
  end

  test "capture can be switched off entirely", %{conn: conn} do
    Application.put_env(:kiln_cms, :missed_paths, enabled: false)

    visit(conn, "/off-the-record")

    assert rows() == []
  end

  # The retention purge is the bound the privacy story rests on, so exercise the
  # trigger itself — `list_tenants`, `use_tenant_from_record?` and the custom
  # worker/scheduler module names all only fail here.
  test "the nightly trigger purges rows past the window and keeps recent ones" do
    days = MissedPath.retention_days()
    old = seeded_row(DateTime.add(DateTime.utc_now(), -(days + 1), :day))
    recent = seeded_row(DateTime.add(DateTime.utc_now(), -1, :day))

    AshOban.schedule_and_run_triggers(MissedPath,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    ids = Enum.map(rows(), & &1.id)
    refute old.id in ids
    assert recent.id in ids
  end

  defp seeded_row(last_seen_at) do
    Ash.Seed.seed!(MissedPath, %{
      path: "/seeded-#{System.unique_integer([:positive])}",
      locale: "en",
      count: 1,
      last_seen_at: last_seen_at
    })
  end

  test "the retention read only sees rows older than the window" do
    org_id = KilnCMS.Accounts.default_org_id()

    fresh =
      CMS.record_missed_path!(%{path: "/fresh", locale: "en"},
        authorize?: false,
        tenant: org_id
      )

    stale =
      CMS.record_missed_path!(%{path: "/stale", locale: "en"},
        authorize?: false,
        tenant: org_id
      )

    long_ago = DateTime.add(DateTime.utc_now(), -(MissedPath.retention_days() + 1), :day)
    Ash.Seed.update!(stale, %{last_seen_at: long_ago})

    expired =
      MissedPath
      |> Ash.Query.for_read(:expired)
      |> Ash.read!(authorize?: false, tenant: org_id)

    assert Enum.map(expired, & &1.id) == [stale.id]
    refute fresh.id in Enum.map(expired, & &1.id)
  end
end
