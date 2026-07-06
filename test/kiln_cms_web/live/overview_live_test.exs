defmodule KilnCMSWeb.OverviewLiveTest do
  @moduledoc """
  The console home (`/editor/overview`): the bagua grid — content counts in
  the centre tile, one headline number per surrounding domain tile, and
  admin-only numbers rendered as “—” for editors.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_user(role) do
    email = "ov-live-#{System.unique_integer([:positive])}@example.com"

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

  defp seed_page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "ov-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  test "viewers are redirected away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:viewer)) |> live(~p"/editor/overview")
  end

  test "the centre tile counts content by state and surfaces attention items", %{conn: conn} do
    seed_page(%{state: :draft})
    seed_page(%{state: :published})
    seed_page(%{state: :in_review})

    {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert html =~ "Overview"
    assert lv |> element("#overview-total") |> render() =~ ">3<"
    assert html =~ "1 published · 1 in review · 1 drafts"
    assert html =~ "1 waiting for review"
  end

  test "a quiet site says so", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert html =~ "All quiet."
  end

  test "the kan tile counts scheduled transitions in the next week", %{conn: conn} do
    seed_page(%{state: :draft, scheduled_at: DateTime.add(DateTime.utc_now(), 2, :day)})
    seed_page(%{state: :published, unpublish_at: DateTime.add(DateTime.utc_now(), 3, :day)})
    # Outside the window — must not count.
    seed_page(%{state: :draft, scheduled_at: DateTime.add(DateTime.utc_now(), 30, :day)})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert lv |> element("#bagua-kan") |> render() =~ ">2<"
  end

  test "the xun tile reports translation coverage across locale variants", %{conn: conn} do
    covered = "ov-covered-#{System.unique_integer([:positive])}"
    for locale <- ["en", "fr", "es"], do: seed_page(%{slug: covered, locale: locale})
    seed_page(%{slug: "ov-gap-#{System.unique_integer([:positive])}", locale: "en"})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    rendered = lv |> element("#bagua-xun") |> render()
    assert rendered =~ "50%"
    assert rendered =~ "1 of 2 fully translated"
  end

  test "admin-only tiles render as — for editors", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert lv |> element("#bagua-zhen") |> render() =~ "—"
    assert lv |> element("#bagua-dui") |> render() =~ "—"
    assert lv |> element("#bagua-qian") |> render() =~ "—"
  end

  test "admins get webhook, form and key numbers", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

    assert lv |> element("#bagua-zhen") |> render() =~ ">0<"
    assert lv |> element("#bagua-dui") |> render() =~ "0 submissions this week"
    refute lv |> element("#bagua-qian") |> render() =~ "—"
  end

  test "every tile carries its trigram mark", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    for name <- ~w(xun li kun zhen dui gen kan qian) do
      assert html =~ ~s(id="bagua-#{name}")
    end

    assert html =~ "qian · heaven"
    assert html =~ "kun · earth"
    assert html =~ "taiji · centre"
  end
end
