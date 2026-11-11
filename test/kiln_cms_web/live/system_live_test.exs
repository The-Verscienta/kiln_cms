defmodule KilnCMSWeb.SystemLiveTest do
  @moduledoc """
  The admin system/update page.

  Two things matter here beyond "it renders": the page is admin-only (it
  discloses the exact build a site runs, which is fingerprinting material for
  anyone probing for known-vulnerable versions), and it never offers to apply
  an update itself — see `KilnCMSWeb.SystemLive` for why.
  """
  # async: false - the update cache is a :persistent_term and the disabled
  # case flips global app env, both of which leak across concurrent tests.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias Kiln.Plugins.Health
  alias Kiln.Updates
  alias KilnCMS.Accounts.User

  @password "password123456"

  setup do
    Updates.clear_cache()
    on_exit(&Updates.clear_cache/0)
    :ok
  end

  defp authed_user(role) do
    email = "system-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The render_async/2 calls below pass an explicit timeout: the 100ms default
  # is too tight for a round trip through the Req.Test plug on a loaded machine.
  defp stub_release(tag) do
    Req.Test.stub(Updates, fn conn ->
      Req.Test.json(conn, %{
        "tag_name" => tag,
        "html_url" => "https://github.com/The-Verscienta/kiln_cms/releases/tag/#{tag}",
        "published_at" => "2026-07-01T12:00:00Z",
        "body" => "Notes."
      })
    end)
  end

  # The newest *final* release a running build can be "up to date" with.
  # `releases/latest` never returns a pre-release, so while the running build
  # is a candidate (`1.0.0-rc.1`) the newest release upstream reports is an
  # older final one, and stubbing the running version itself would be a
  # response GitHub cannot send (`Kiln.Updates` refuses it as `:prerelease`).
  defp newest_release do
    v = Version.parse!(Kiln.Version.version())

    cond do
      v.pre == [] -> to_string(v)
      v.patch > 0 -> "#{v.major}.#{v.minor}.#{v.patch - 1}"
      v.minor > 0 -> "#{v.major}.#{v.minor - 1}.0"
      true -> "#{v.major - 1}.0.0"
    end
  end

  defp newer_tag do
    parsed = Version.parse!(Kiln.Version.version())
    "v#{parsed.major}.#{parsed.minor + 1}.0"
  end

  # Merge, don't replace: dropping :req_options would send a stray check to the
  # real api.github.com.
  defp put_updates_env(key, value) do
    previous = Application.get_env(:kiln_cms, Updates, [])
    Application.put_env(:kiln_cms, Updates, Keyword.put(previous, key, value))
    on_exit(fn -> Application.put_env(:kiln_cms, Updates, previous) end)
  end

  # The command is the only copy-pasteable thing on the page, so it is asserted
  # exactly rather than with =~ — a stray `cd` is precisely the bug, and =~
  # can't tell "no cd" from "a cd somewhere else in the page".
  defp update_command(html) do
    case Regex.run(~r{<code>(.*?)</code>}s, html) do
      [_, command] -> command
      nil -> flunk("no command block rendered")
    end
  end

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/system")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               live(conn, ~p"/editor/system")
    end
  end

  describe "as an admin" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "renders the running version without waiting on the network", %{conn: conn} do
      # No stub is installed, so the check will fail — the version panel must
      # still render, since that's the half that doesn't need the network.
      Req.Test.stub(Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      assert html =~ "This instance"
      assert html =~ Kiln.Version.version()
    end

    test "shows the update command when behind upstream", %{conn: conn} do
      stub_release(newer_tag())

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2_000)

      assert html =~ "Update available"
      assert html =~ newer_tag()
      assert html =~ "mix kiln.update"
      # A GitHub answer carries no highlights, so the section is left out.
      refute html =~ "What&#39;s new in this release"
    end

    # #1877: the kilncms.dev feed answers first and carries each release's
    # highlights, which the page lists — escaped, since they are feed data.
    test "lists the feed's highlights for the newer release", %{conn: conn} do
      "v" <> version = newer_tag()

      Req.Test.stub(Updates, fn conn ->
        assert conn.host == "kilncms.dev"

        Req.Test.json(conn, %{
          "data" => [
            %{
              "attributes" => %{
                "custom_fields" => %{
                  "version" => version,
                  "released_on" => "2026-10-02",
                  "highlights" => "Faster publishing\n<b>Bold</b> claims"
                }
              }
            }
          ],
          "links" => %{"next" => nil}
        })
      end)

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2_000)

      assert html =~ "What&#39;s new in this release"
      assert html =~ "Faster publishing"
      assert html =~ "&lt;b&gt;Bold&lt;/b&gt; claims"
      assert html =~ "released 2026-10-02"
    end

    # The pin is a submodule *or* a fetched ref, at a path the project chose,
    # and this image has no checkout to look in. A hardcoded `cd` would be a
    # copy-pasteable "no such file or directory" for everyone on a layout other
    # than the reference one, compiled in with no way to correct it.
    test "prints no cd when the deployment wasn't told where its pin lives", %{conn: conn} do
      stub_release(newer_tag())

      {:ok, lv, _html} = live(conn, ~p"/editor/system")

      assert update_command(render_async(lv, 2_000)) == "mix kiln.update"
    end

    test "prefixes the command with a cd when KILN_PIN_PATH is set", %{conn: conn} do
      put_updates_env(:pin_path, "vendor/kiln")
      stub_release(newer_tag())

      {:ok, lv, _html} = live(conn, ~p"/editor/system")

      assert update_command(render_async(lv, 2_000)) == "cd vendor/kiln\nmix kiln.update"
    end

    test "reports up to date when running the newest release", %{conn: conn} do
      stub_release("v#{newest_release()}")

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2_000)

      assert html =~ "Up to date"
      refute html =~ "Update available"
    end

    test "degrades to a neutral message when upstream is unreachable", %{conn: conn} do
      Req.Test.stub(Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2_000)

      assert html =~ "Couldn&#39;t reach" or html =~ "Couldn't reach"
      refute html =~ "Update available"
    end

    # A misconfigured upstream is not an unreachable one. "Couldn't reach"
    # would send an operator to look at egress and DNS for a problem that is
    # one environment variable away, so it gets its own status.
    test "names the misconfiguration instead of blaming the network", %{conn: conn} do
      Req.Test.stub(Updates, fn _conn -> flunk("requested with a malformed repo") end)
      put_updates_env(:repo, "acmekiln")

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2_000)

      assert html =~ "KILN_UPDATE_REPO"
      refute html =~ "Couldn&#39;t reach"
      refute html =~ "Update available"
    end

    # The page links the release it names. Left deriving from upstream, a
    # fork's admin would be sent to someone else's releases page.
    test "links the configured repo when the release omits an html_url", %{conn: conn} do
      put_updates_env(:repo, "acme/kiln")

      Req.Test.stub(Updates, fn conn ->
        Req.Test.json(conn, %{"tag_name" => newer_tag(), "html_url" => nil})
      end)

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2_000)

      assert html =~ "https://github.com/acme/kiln/releases"
      refute html =~ "https://github.com/The-Verscienta/kiln_cms/releases"
    end

    test "check now re-queries upstream, bypassing the cache", %{conn: conn} do
      stub_release("v#{newest_release()}")

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      assert render_async(lv, 2_000) =~ "Up to date"

      stub_release(newer_tag())

      assert lv |> element("button", "Check now") |> render_click()
      assert render_async(lv, 2_000) =~ "Update available"
    end

    # The whole design rests on this: the page must never offer to mutate the
    # running instance. If someone adds such a control, this test should fail.
    test "offers no control that applies an update", %{conn: conn} do
      stub_release(newer_tag())

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2_000)

      refute html =~ ~r/phx-click="(apply|install|run)[-_]?update"/i
      assert html =~ "It does not deploy."
    end
  end

  describe "when update checks are disabled" do
    setup %{conn: conn} do
      # Merge, don't replace: dropping :req_options would send a stray check
      # to the real api.github.com.
      previous = Application.get_env(:kiln_cms, Updates, [])
      Application.put_env(:kiln_cms, Updates, Keyword.put(previous, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, Updates, previous) end)
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "says so, and makes no request", %{conn: conn} do
      Req.Test.stub(Updates, fn _conn -> flunk("checked upstream while disabled") end)

      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      assert html =~ "KILN_UPDATE_CHECK=false"
      assert html =~ Kiln.Version.version()
    end
  end

  # The cache has no bare put — `fetch_published/5` populates it from the fun.
  defp warm(org, slug),
    do: KilnCMS.Cache.fetch_published(org, "page", slug, "en", fn -> %{id: slug} end)

  describe "flushing the delivery cache (#483)" do
    setup do
      stub_release(newest_release())
      :ok
    end

    defp system_page(role) do
      {:ok, lv, html} =
        build_conn() |> log_in(authed_user(role)) |> live(~p"/editor/system")

      {lv, html}
    end

    test "an admin sees the button, with the cost stated" do
      {_lv, html} = system_page(:admin)

      assert html =~ "Flush delivery cache"
      # The button is destructive-ish: it trades a warm cache for database load,
      # so the page has to say so rather than presenting a free action.
      assert html =~ "re-reads the database"
      assert html =~ "data-confirm"
    end

    test "flushing clears BOTH delivery caches" do
      org = KilnCMS.Accounts.default_org_id()
      doc_id = Ash.UUID.generate()

      warm(org, "cached-slug")
      KilnCMS.Firing.Cache.put(org, :page, doc_id, :web, %{"html" => "<p>hi</p>"})

      # Both warm to begin with, or the assertions below prove nothing.
      assert {:ok, _} = KilnCMS.Firing.Cache.get(org, :page, doc_id, :web)

      {lv, _html} = system_page(:admin)
      lv |> element("button[phx-click='flush-cache']") |> render_click()

      # Clearing one and not the other leaves the site serving half-stale: the
      # record lookups repopulate from the database while the fired bodies keep
      # whatever they had. Reverting the artifacts half must fail here.
      assert KilnCMS.Firing.Cache.get(org, :page, doc_id, :web) == :miss

      # A miss now, where a warm entry would have been returned without the fun
      # running at all.
      assert KilnCMS.Cache.fetch_published(org, "page", "cached-slug", "en", fn -> :refetched end) ==
               :refetched
    end

    test "the count line reports what actually went" do
      org = KilnCMS.Accounts.default_org_id()
      warm(org, "counted-slug")
      KilnCMS.Firing.Cache.put(org, :page, Ash.UUID.generate(), :web, %{"html" => "<p>hi</p>"})

      {lv, _html} = system_page(:admin)
      html = lv |> element("button[phx-click='flush-cache']") |> render_click()

      # Not just "Dropped" — that renders for a zero flush too, so it would pass
      # against a no-op. Both caches are process-global and every other test in
      # the run writes to them, so assert the counts are non-zero rather than
      # exactly the two entries this test warmed: pinning "1" makes the test a
      # hostage to whatever else happened to be cached at that instant.
      assert [published, artifacts] =
               Regex.run(~r/Dropped (\d+) published entr\w+ and (\d+) artifact entries/, html,
                 capture: :all_but_first
               )

      assert String.to_integer(published) >= 1
      assert String.to_integer(artifacts) >= 1
    end

    test "an editor cannot reach the page at all" do
      assert {:error, {:redirect, _}} =
               build_conn() |> log_in(authed_user(:editor)) |> live(~p"/editor/system")
    end

    # The route gate is a PER-ORG tier while the flush is a global-admin action,
    # and the handler is what actually flushes — so the guard that matters is the
    # one inside `handle_event/3`, not the route. Driven directly, because the
    # route stops this principal before a socket exists.
    test "the handler itself refuses a non-admin" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: authed_user(:editor), flushed: nil, flash: %{}}
      }

      {:noreply, socket} = KilnCMSWeb.SystemLive.handle_event("flush-cache", %{}, socket)

      assert is_nil(socket.assigns.flushed)
      assert socket.assigns.flash["error"] =~ "admin access"
    end
  end

  # What the panel reports is compile-time data (`config :kiln_cms, :plugins`),
  # so in this suite it is always the fixture plugin — the same manifest
  # `mix kiln.plugins.list` prints, rendered as label/count pairs.
  describe "the plugins panel" do
    setup %{conn: conn} do
      # No release stub: the update check fails, and the panel must render
      # anyway — it reads compile-time data and never touches the network.
      Req.Test.stub(Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "lists what is compiled into this instance", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      panel = plugins_panel(html)

      assert panel =~ "fixture_plugin"
      assert panel =~ "1.2.3"
      assert panel =~ "Test fixture exercising every plugin seam."
      assert panel =~ "KilnCMS.FixturePlugin"

      # The homepage is where a plugin's docs and screenshots live: the node
      # carries the pointer, never the media.
      assert panel =~ "https://example.com/fixture-plugin"
    end

    # Exact map, not membership: a kind the plugin doesn't contribute must be
    # absent rather than rendered as a zero, which is the whole reason the
    # summary is worth reading.
    test "counts the kinds contributed and omits the rest", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      assert contribution_counts(html) == %{
               "Blocks" => "5",
               "Field types" => "4",
               "Image backends" => "1",
               "Nav items" => "1",
               "Admin routes" => "1",
               "Background queues" => "1",
               "Supervised children" => "1"
             }
    end

    # The counts say how much; this says what — in the words the plugin already
    # shows editors, so an operator can tell what it does without its source.
    test "names what each contribution is", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      panel = plugins_panel(html)

      assert panel =~ "What it adds"
      assert panel =~ "Checklist"
      assert panel =~ "Tasks with an owner each"
      assert panel =~ "One to five stars. For a review score."
      # The nav item names its page; the route it points at isn't listed twice.
      assert panel =~ "Fixture"
      assert length(String.split(panel, "/editor/fixture")) == 2
      assert panel =~ "1 worker"
      # Installed is not in use: the fixture backend is never selected here.
      assert panel =~ "Image backend"
      assert panel =~ "Installed, not selected"
    end

    test "reports rather than offers to install", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      panel = plugins_panel(html)

      assert panel =~ "mix kiln.plugins.list"
      assert panel =~ "mix kiln.plugins.doctor"
      # An install button would be the same lie an update button would be.
      refute panel =~ "phx-click"
    end
  end

  # Plugin health (#2244). Remote answers come from the `Kiln.Plugins.Health`
  # and `Kiln.SecurityNotices` Req.Test stubs; checks are off in this suite
  # unless a case turns them on.
  describe "plugin health" do
    setup %{conn: conn} do
      Req.Test.stub(Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      original = Application.get_env(:kiln_cms, Health, [])
      notices = Application.get_env(:kiln_cms, Kiln.SecurityNotices, [])
      Health.clear_cache()

      on_exit(fn ->
        Application.put_env(:kiln_cms, Health, original)
        Application.put_env(:kiln_cms, Kiln.SecurityNotices, notices)
        Health.clear_cache()
      end)

      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "with checks off, each plugin still gets a badge and nothing is asked", %{conn: conn} do
      stub_health()
      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      assert health_of(html, "KilnCMS.FixturePlugin") == "not_applicable"
      assert health_of(html, "KilnDepFixture.Plugin") == "unverifiable"
      assert plugins_panel(html) =~ "Built from this project"
      assert plugins_panel(html) =~ "Can&#39;t verify"
      assert plugins_panel(html) =~ "Plugin checks are off."
      assert html |> Floki.parse_document!() |> Floki.find("#check-plugins-now") == []
      refute_received {:health_request, _path}
    end

    test "with checks on, the page checks in the background and badges each plugin",
         %{conn: conn} do
      enable_health()
      stub_health()

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2000)

      assert_received {:health_request, "/api/json/entries/published"}
      assert health_of(html, "KilnCMS.FixturePlugin") == "not_applicable"
      assert health_of(html, "KilnDepFixture.Plugin") == "unverifiable"
      assert plugins_panel(html) =~ "Checked "
      assert has_element?(lv, "#check-plugins-now")
    end

    test "a matched security notice names itself and links the advisory", %{conn: conn} do
      enable_health()

      stub_health(
        notices: [
          notice(%{
            "package" => "kiln_dep_fixture",
            "affected_versions" => ">= 0.0.1",
            "severity" => "high",
            "advisory_id" => "KILN-2026-0042",
            "advisory_url" => "https://kilncms.dev/security/kiln-2026-0042"
          })
        ]
      )

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2000)

      assert health_of(html, "KilnDepFixture.Plugin") == "fail"
      panel = plugins_panel(html)
      assert panel =~ "Security notice"
      assert panel =~ "security notice KILN-2026-0042 (high)"
      assert panel =~ ~s(href="https://kilncms.dev/security/kiln-2026-0042")
    end

    # The fetch turns a crashing source into "did not answer", so the check
    # still finishes: the project's own plugin is known offline, the path
    # plugin's notices are unknown, and nothing reads as OK.
    test "a source that crashed renders unknown, never OK", %{conn: conn} do
      enable_health()
      stub_both(fn _conn -> exit(:boom) end)

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2000)

      assert health_of(html, "KilnCMS.FixturePlugin") == "not_applicable"
      assert health_of(html, "KilnDepFixture.Plugin") == "unknown"
      refute html =~ ~s(data-health="ok")
      assert plugins_panel(html) =~ "these results are unknown, not OK"
    end

    test "check plugins now asks again, past the cache", %{conn: conn} do
      enable_health()
      stub_health()

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      render_async(lv, 2000)
      assert_received {:health_request, _path}

      lv |> element("#check-plugins-now") |> render_click()
      render_async(lv, 2000)
      assert_received {:health_request, _path}
    end

    test "check plugins now with checks off asks nothing", %{conn: conn} do
      stub_health()
      {:ok, lv, _html} = live(conn, ~p"/editor/system")

      render_hook(lv, "check-plugins-now", %{})
      render_async(lv, 500)
      refute_received {:health_request, _path}
    end

    # The route stops these principals before a socket exists, so the handler
    # is driven directly: it is the guard that matters, since it makes
    # outbound requests and takes no actor a policy could refuse.
    test "the handler refuses an editor, and asks nothing" do
      enable_health()
      stub_health()

      socket = health_socket(authed_user(:editor))

      {:noreply, socket} =
        KilnCMSWeb.SystemLive.handle_event("check-plugins-now", %{}, socket)

      assert socket.assigns.flash["error"] =~ "admin access"
      assert %Health.Report{} = socket.assigns.plugin_health
      refute_received {:health_request, _path}
    end

    test "the handler refuses a platform admin whose temporary grant has expired" do
      enable_health()
      stub_health()

      # Mounted while the grant was live; it ran out before the press.
      expired = %{
        authed_user(:editor)
        | granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      {:noreply, socket} =
        KilnCMSWeb.SystemLive.handle_event("check-plugins-now", %{}, health_socket(expired))

      assert socket.assigns.flash["error"] =~ "admin access"
      refute_received {:health_request, _path}
    end
  end

  # The core's own security notices (#2522), in the Updates card. Answers come
  # from the `Kiln.SecurityNotices` Req.Test stub; the feed is off in this
  # suite unless a case turns it on.
  describe "security notices for the core" do
    setup %{conn: conn} do
      Req.Test.stub(Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      notices = Application.get_env(:kiln_cms, Kiln.SecurityNotices, [])
      Kiln.SecurityNotices.clear_cache()

      on_exit(fn ->
        Application.put_env(:kiln_cms, Kiln.SecurityNotices, notices)
        Kiln.SecurityNotices.clear_cache()
      end)

      %{conn: log_in(conn, authed_user(:admin))}
    end

    defp enable_notices do
      Application.put_env(
        :kiln_cms,
        Kiln.SecurityNotices,
        Keyword.put(Application.get_env(:kiln_cms, Kiln.SecurityNotices, []), :url, nil)
      )
    end

    defp stub_notices(entries) do
      test = self()

      Req.Test.stub(Kiln.SecurityNotices, fn conn ->
        send(test, {:notices_request, conn.request_path})
        Req.Test.json(conn, %{"data" => entries})
      end)
    end

    defp covering_notice do
      notice(%{
        "package" => "kiln_cms",
        "affected_versions" => "<= #{Kiln.Version.version()}",
        "patched_versions" => "99.0.0",
        "severity" => "medium",
        "advisory_id" => "GHSA-aaaa-bbbb-cccc",
        "advisory_url" =>
          "https://github.com/The-Verscienta/kiln_cms/security/advisories/GHSA-aaaa-bbbb-cccc"
      })
    end

    defp notices_line(html) do
      html |> Floki.parse_document!() |> Floki.find("#core-security-notices") |> Floki.text()
    end

    test "with the feed off, the card says so and nothing is asked", %{conn: conn} do
      stub_notices([])
      {:ok, _lv, html} = live(conn, ~p"/editor/system")

      assert notices_line(html) =~ "The security notices feed is turned off"
      refute_received {:notices_request, _path}
    end

    test "a notice covering this version names itself, its fix and links it", %{conn: conn} do
      enable_notices()
      stub_notices([covering_notice()])

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2000)
      line = notices_line(html)

      assert line =~ "A security notice covers Kiln #{Kiln.Version.version()}."
      assert line =~ "GHSA-aaaa-bbbb-cccc (medium): fixed in 99.0.0."

      assert has_element?(
               lv,
               ~s(#core-security-notices a[href="https://github.com/The-Verscienta/kiln_cms/security/advisories/GHSA-aaaa-bbbb-cccc"]),
               "Advisory GHSA-aaaa-bbbb-cccc"
             )
    end

    test "an unsafe advisory link is dropped, the notice still listed", %{conn: conn} do
      enable_notices()

      stub_notices([
        notice(%{
          "package" => "kiln_cms",
          "affected_versions" => "<= #{Kiln.Version.version()}",
          "advisory_id" => "GHSA-aaaa-bbbb-cccc",
          "advisory_url" => "javascript:alert(1)"
        })
      ])

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      html = render_async(lv, 2000)

      assert notices_line(html) =~ "GHSA-aaaa-bbbb-cccc"
      refute has_element?(lv, "#core-security-notices a")
    end

    test "no notice for this version reads as such", %{conn: conn} do
      enable_notices()
      stub_notices([])

      {:ok, lv, _html} = live(conn, ~p"/editor/system")

      assert notices_line(render_async(lv, 2000)) =~
               "No published security notice covers Kiln #{Kiln.Version.version()}."
    end

    test "an unreachable feed is unknown, not clean", %{conn: conn} do
      enable_notices()
      Req.Test.stub(Kiln.SecurityNotices, &Req.Test.transport_error(&1, :econnrefused))

      {:ok, lv, _html} = live(conn, ~p"/editor/system")

      assert notices_line(render_async(lv, 2000)) =~
               "Couldn't reach the security notices feed."
    end

    test "check now asks the feed again, past the cache", %{conn: conn} do
      enable_notices()
      stub_notices([])

      {:ok, lv, _html} = live(conn, ~p"/editor/system")
      render_async(lv, 2000)
      assert_received {:notices_request, _path}

      stub_notices([covering_notice()])
      lv |> element("button", "Check now") |> render_click()

      assert notices_line(render_async(lv, 2000)) =~ "A security notice covers Kiln"
      assert_received {:notices_request, _path}
    end

    test "with update checks off, there is no line and nothing is asked", %{conn: conn} do
      enable_notices()
      stub_notices([])
      previous = Application.get_env(:kiln_cms, Updates, [])
      Application.put_env(:kiln_cms, Updates, Keyword.put(previous, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, Updates, previous) end)

      {:ok, lv, _html} = live(conn, ~p"/editor/system")

      refute has_element?(lv, "#core-security-notices")
      refute_received {:notices_request, _path}
    end

    # The route stops these principals before a socket exists, so the handler
    # is driven directly: it makes outbound requests and takes no actor a
    # policy could refuse.
    test "the check now handler refuses an editor, and asks nothing" do
      enable_notices()
      stub_notices([])
      Req.Test.stub(Updates, fn _conn -> flunk("checked upstream for a non-admin") end)

      {:noreply, socket} =
        KilnCMSWeb.SystemLive.handle_event(
          "check-now",
          %{},
          check_now_socket(authed_user(:editor))
        )

      assert socket.assigns.flash["error"] =~ "admin access"
      assert socket.assigns.update == {:ok, :current}
      assert socket.assigns.core_notices == :disabled
      refute_received {:notices_request, _path}
    end

    test "the check now handler refuses a platform admin whose grant has expired" do
      enable_notices()
      stub_notices([])

      expired = %{
        authed_user(:editor)
        | granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      {:noreply, socket} =
        KilnCMSWeb.SystemLive.handle_event("check-now", %{}, check_now_socket(expired))

      assert socket.assigns.flash["error"] =~ "admin access"
      refute_received {:notices_request, _path}
    end
  end

  defp check_now_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_user: user,
        update: {:ok, :current},
        core_notices: :disabled,
        flash: %{}
      }
    }
  end

  defp enable_health do
    Application.put_env(
      :kiln_cms,
      Health,
      Keyword.put(Application.get_env(:kiln_cms, Health, []), :enabled, true)
    )

    # The notices feed is off in the test config; unset, it follows the update
    # feed (kilncms.dev's), as in production.
    Application.put_env(
      :kiln_cms,
      Kiln.SecurityNotices,
      Keyword.put(Application.get_env(:kiln_cms, Kiln.SecurityNotices, []), :url, nil)
    )
  end

  # Both names: Hex is asked through `Kiln.Plugins.Health`'s options, the
  # notices feed through `Kiln.SecurityNotices`'s.
  defp stub_both(fun) do
    Req.Test.stub(Health, fun)
    Req.Test.stub(Kiln.SecurityNotices, fun)
  end

  # Answers like kilncms.dev's published-entries endpoint (the only request a
  # suite with no Hex plugin makes), and tells the test about every request.
  defp stub_health(opts \\ []) do
    test = self()
    notices = %{"data" => Keyword.get(opts, :notices, [])}

    stub_both(fn conn ->
      send(test, {:health_request, conn.request_path})
      Req.Test.json(conn, notices)
    end)
  end

  defp notice(fields) do
    %{"id" => "1", "attributes" => %{"title" => "A notice", "custom_fields" => fields}}
  end

  defp health_socket(user) do
    report = %Health.Report{plugins: [], state: :fresh, checked_at: DateTime.utc_now()}

    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_user: user, plugin_health: report, flash: %{}}
    }
  end

  # The `data-health` key of the badge on the row for `module_name`.
  defp health_of(html, module_name) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#plugins > ul > li")
    |> Enum.find(&(&1 |> Floki.raw_html() |> String.contains?(module_name)))
    |> case do
      nil -> flunk("no row for #{module_name}")
      row -> row |> Floki.attribute(".plugin-health", "data-health") |> List.first()
    end
  end

  defp plugins_panel(html) do
    html |> Floki.parse_document!() |> Floki.find("#plugins") |> Floki.raw_html()
  end

  # The panel renders one row per compiled plugin, each with its own `dl`, so
  # this scopes to the fixture plugin's row before reading the pairs. An
  # unscoped `#plugins dl > div` merges every plugin's counts into one map,
  # which holds only while the fixture plugin is the sole entry — untrue in a
  # downstream project's composed suite, where its own plugin is registered
  # beside the fixture (projects/README.md) and contributes rows of its own.
  defp contribution_counts(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#plugins li")
    |> Enum.find([], &(&1 |> Floki.raw_html() |> String.contains?("KilnCMS.FixturePlugin")))
    |> List.wrap()
    |> Floki.find("dl > div")
    |> Map.new(fn pair ->
      {pair |> Floki.find("dt") |> Floki.text() |> String.trim(),
       pair |> Floki.find("dd") |> Floki.text() |> String.trim()}
    end)
  end

  describe "KilnCMS.Cache.flush_delivery/0" do
    test "reports counts from both caches and is safe to repeat" do
      org = KilnCMS.Accounts.default_org_id()
      warm(org, "flush-me")

      assert %{published: published, artifacts: artifacts} = KilnCMS.Cache.flush_delivery()
      assert published >= 1
      assert is_integer(artifacts)

      # A second flush on an empty cache is a no-op, not an error — the mix task
      # and the button both call it without checking first.
      assert %{published: 0, artifacts: 0} = KilnCMS.Cache.flush_delivery()
    end
  end
end
