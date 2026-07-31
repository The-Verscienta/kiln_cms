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
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

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

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} =
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
      stub_release("v#{Kiln.Version.version()}")

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
      stub_release("v#{Kiln.Version.version()}")

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
end
