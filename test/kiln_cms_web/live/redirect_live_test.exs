defmodule KilnCMSWeb.RedirectLiveTest do
  @moduledoc """
  Admin redirect management at /editor/redirects (#457): admin-only access,
  listing automatic rows with live-resolved destinations, manual creation
  (including deep legacy paths served by the delivery catch-all), validation,
  and pruning.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_user(role) do
    email = "redir-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  defp uniq, do: System.unique_integer([:positive])

  defp published_page(attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "rl-pg-#{uniq()}", state: :published}, attrs)
    )
  end

  defp open(conn, user) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/redirects")
    {lv, html}
  end

  test "anonymous users are sent to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/redirects")
  end

  test "editors are denied", %{conn: conn} do
    conn = log_in(conn, authed_user(:editor))

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "You need admin access" <> _}}}} =
             live(conn, ~p"/editor/redirects")
  end

  test "lists automatic rows with their live-resolved destination", %{conn: conn} do
    page = published_page()
    old_slug = page.slug
    renamed = CMS.update_page!(page, %{slug: "rl-pg-#{uniq()}"}, authorize?: false)

    {_lv, html} = open(conn, authed_user(:admin))

    assert html =~ "/#{old_slug}"
    assert html =~ ~s(href="/#{renamed.slug}")
  end

  test "a manual redirect is created and served, even for deep legacy paths", %{conn: conn} do
    page = published_page()
    legacy = "/2019/05/legacy-#{uniq()}"
    {lv, _html} = open(conn, authed_user(:admin))

    lv
    |> form("#new-redirect-form",
      redirect: %{path: legacy, locale: "en", type: "page", slug: page.slug}
    )
    |> render_submit()

    assert render(lv) =~ legacy

    # The delivery catch-all 301s the 3-segment path to the page's URL.
    assert redirected_to(get(conn, legacy), 301) == "/#{page.slug}"
  end

  test "rejects a target slug that doesn't exist", %{conn: conn} do
    {lv, _html} = open(conn, authed_user(:admin))

    html =
      lv
      |> form("#new-redirect-form",
        redirect: %{path: "/somewhere", locale: "en", type: "page", slug: "no-such-slug"}
      )
      |> render_submit()

    assert html =~ "check the target"
    assert CMS.list_redirects!(authorize?: false, query: [filter: [path: "/somewhere"]]) == []
  end

  test "rejects a path without a leading slash", %{conn: conn} do
    page = published_page()
    {lv, _html} = open(conn, authed_user(:admin))

    html =
      lv
      |> form("#new-redirect-form",
        redirect: %{path: "no-slash", locale: "en", type: "page", slug: page.slug}
      )
      |> render_submit()

    assert html =~ "must start with /"
  end

  test "deleting a redirect removes it", %{conn: conn} do
    page = published_page()
    old_slug = page.slug
    CMS.update_page!(page, %{slug: "rl-pg-#{uniq()}"}, authorize?: false)

    [row] = CMS.list_redirects!(authorize?: false, query: [filter: [path: "/#{old_slug}"]])
    {lv, _html} = open(conn, authed_user(:admin))

    lv
    |> element(~s(button[phx-click="delete"][phx-value-id="#{row.id}"]))
    |> render_click()

    assert CMS.list_redirects!(authorize?: false, query: [filter: [path: "/#{old_slug}"]]) == []
    assert conn |> get("/#{old_slug}") |> response(404)
  end

  describe "the 404s tab (#472)" do
    defp missed(path, attrs \\ %{}) do
      CMS.record_missed_path!(Map.merge(%{path: path, locale: "en"}, attrs), authorize?: false)
    end

    test "lists recorded misses, most-requested first", %{conn: conn} do
      quiet = missed("/quiet-#{uniq()}")
      loud = missed("/loud-#{uniq()}")
      for _ <- 1..3, do: missed(loud.path)

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:admin)) |> live(~p"/editor/redirects?tab=404s")

      assert html =~ loud.path
      assert html =~ quiet.path
      # The loud one sorts first — the tab is a work queue, not a log.
      assert :binary.match(html, loud.path) < :binary.match(html, quiet.path)
    end

    test "\"Create redirect\" prefills the form with the missed path", %{conn: conn} do
      row = missed("/broken-#{uniq()}")

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:admin)) |> live(~p"/editor/redirects?tab=404s")

      lv
      |> element(~s(button[phx-click="redirect_missed"][phx-value-id="#{row.id}"]))
      |> render_click()

      assert render(lv) =~ ~s(value="#{row.path}")
    end

    test "creating the redirect clears the path's counter", %{conn: conn} do
      page = published_page()
      row = missed("/gone-#{uniq()}")

      {lv, _html} = open(conn, authed_user(:admin))

      lv
      |> form("#new-redirect-form",
        redirect: %{path: row.path, locale: "en", type: "page", slug: page.slug}
      )
      |> render_submit()

      assert CMS.list_missed_paths!(authorize?: false) |> Enum.map(& &1.id) == []
      assert redirected_to(get(conn, row.path), 301) == "/#{page.slug}"
    end

    test "dismissing a path removes its row", %{conn: conn} do
      row = missed("/noise-#{uniq()}")

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:admin)) |> live(~p"/editor/redirects?tab=404s")

      lv
      |> element(~s(button[phx-click="dismiss_missed"][phx-value-id="#{row.id}"]))
      |> render_click()

      assert CMS.list_missed_paths!(authorize?: false) == []
    end
  end
end
