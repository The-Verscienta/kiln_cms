defmodule KilnCMSWeb.ImageBackendLiveTest do
  @moduledoc """
  System → Image backend (#1955): platform-admin only, and each of its three
  answers — the selection, the connection, the library — against the test
  plugin's fixture backend (`KilnCMS.FixturePlugin.ImageBackend`).
  """
  # async: false — the selected backend and its steering live in the global
  # app env.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.FixturePlugin.ImageBackend, as: Fixture

  @password "password123456"
  @path "/editor/system/image-backend"

  setup do
    on_exit(fn ->
      Application.delete_env(:kiln_cms, :image_backend)
      Application.delete_env(:kiln_cms, :fixture_image_backend)
    end)
  end

  defp select_backend(module \\ Fixture, opts \\ []) do
    Application.put_env(:kiln_cms, :image_backend, module)
    Application.put_env(:kiln_cms, :fixture_image_backend, opts)
  end

  defp authed_user(role) do
    email = "image-backend-live-#{System.unique_integer([:positive])}@example.com"

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

  defp admin_conn(conn) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(authed_user(:admin))
  end

  # The async results go through a Task; the 100ms default is tight on a
  # loaded machine.
  defp settled(lv), do: render_async(lv, 2_000)

  describe "access" do
    test "editors are sent away", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(authed_user(:editor))

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} = live(conn, @path)
    end

    test "System links to it while a backend is installed", %{conn: conn} do
      # System also checks upstream for a release; that isn't this test's.
      previous = Application.get_env(:kiln_cms, Kiln.Updates, [])
      Application.put_env(:kiln_cms, Kiln.Updates, Keyword.put(previous, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, Kiln.Updates, previous) end)

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/editor/system")
      assert has_element?(lv, ~s{#image-backend-link[href="#{@path}"]})
    end
  end

  describe "selection" do
    test "with none selected, it lists what could be, as config lines", %{conn: conn} do
      {:ok, lv, html} = live(admin_conn(conn), @path)

      assert html =~ "None selected"
      assert html =~ "config :kiln_cms, :image_backend, KilnCMS.FixturePlugin.ImageBackend"
      refute has_element?(lv, "#image-backend-connection")
      refute has_element?(lv, "#image-backend-library")
    end

    test "an active backend is named with its plugin", %{conn: conn} do
      select_backend()
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      html = settled(lv)

      assert html =~ "Receiving uploads"
      assert html =~ "fixture_images"
      assert html =~ "fixture_plugin"
    end

    test "one missing its settings says uploads stay here", %{conn: conn} do
      select_backend(Fixture, configured?: false)
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      html = settled(lv)

      assert html =~ "Missing settings"
      assert html =~ "new uploads go to this server&#39;s storage"
    end

    test "a selected module that isn't a backend is called out", %{conn: conn} do
      select_backend(String)
      {:ok, lv, html} = live(admin_conn(conn), @path)

      assert html =~ "Not installed"
      assert html =~ "names String, which isn&#39;t an installed image backend"
      refute has_element?(lv, "#image-backend-connection")
    end
  end

  describe "connection" do
    test "a reachable backend shows what it found", %{conn: conn} do
      select_backend(Fixture, check: {:ok, [{"Stored images", "42"}]})
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      settled(lv)

      assert has_element?(lv, "#check-ok", "Reachable")
      assert has_element?(lv, "#check-ok dd", "42")
    end

    test "an unreachable one shows the backend's reason", %{conn: conn} do
      select_backend(Fixture, check: {:error, "The token was revoked"})
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      settled(lv)

      assert has_element?(lv, "#check-error", "The token was revoked")
    end

    test "a check that raises is shown as a failure, not a crashed page", %{conn: conn} do
      select_backend(Fixture, check: fn -> raise "boom" end)
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      settled(lv)

      assert has_element?(lv, "#check-error", "boom")
    end

    test "a backend that can't check says so", %{conn: conn} do
      select_backend(Fixture, check: :unsupported)
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      settled(lv)

      assert has_element?(lv, "#check-unsupported")
    end

    test "checking again asks the backend afresh", %{conn: conn} do
      select_backend(Fixture, check: {:error, "The token was revoked"})
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      settled(lv)
      assert has_element?(lv, "#check-error")

      select_backend(Fixture, check: {:ok, []})
      lv |> element("button", "Check again") |> render_click()
      settled(lv)

      assert has_element?(lv, "#check-ok")
      refute has_element?(lv, "#check-error")
    end
  end

  describe "library" do
    test "counts this site's rows, and offers the adoption command", %{conn: conn} do
      select_backend()
      key = "imported-#{System.unique_integer([:positive])}"

      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: "held.png",
        url: Fixture.url(key),
        storage_key: key,
        image_backend: Fixture.name()
      })

      for url <- ["https://images.fixture.test/a/public", "https://images.fixture.test/b/public"],
          do: Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{filename: "linked.png", url: url})

      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: "elsewhere.png",
        url: "https://cdn.example.com/x.png"
      })

      {:ok, lv, _html} = live(admin_conn(conn), @path)
      html = settled(lv)

      assert has_element?(lv, "#census-held", "1")
      assert has_element?(lv, "#census-awaiting", "2")
      assert has_element?(lv, "#census-unrecognised", "1")

      org_id = KilnCMS.Accounts.default_org_id()

      # A release has no Mix, so it gets its own, labelled, commands; for the
      # default site they name no org, so there are no inner quotes to lose.
      assert has_element?(
               lv,
               "#adopt-release",
               "bin/kiln_cms rpc 'KilnCMS.Release.adopt_image_backend(dry_run: true)'"
             )

      assert has_element?(lv, "#adopt-release", "KilnCMS.Release.adopt_image_backend()'")
      assert has_element?(lv, "#adopt-mix", "--org #{org_id} --dry-run")
      assert html =~ "mix kiln.media.adopt_image_backend --org #{org_id}"
    end

    test "with nothing to adopt, there's no command", %{conn: conn} do
      select_backend()
      {:ok, lv, _html} = live(admin_conn(conn), @path)
      html = settled(lv)

      assert has_element?(lv, "#census-awaiting", "0")
      refute html =~ "mix kiln.media.adopt_image_backend"
      refute html =~ "adopt_image_backend("
    end
  end
end
