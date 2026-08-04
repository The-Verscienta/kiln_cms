defmodule KilnCMSWeb.FunnelBuilderLiveTest do
  @moduledoc """
  The funnel builder (`/editor/funnels/:id`, admin-only): settings, picking a
  content type then item, drag reorder persisting `position`, and removing a
  step.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Analytics
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "funb-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "funb-#{System.unique_integer([:positive])}"

  # Creates a funnel (and optionally steps) FIRST, then mounts the builder —
  # the LiveView only sees steps that exist at mount (or that it creates).
  defp builder(conn, admin, steps \\ []) do
    funnel = Analytics.create_funnel!(%{name: "Signup", slug: slug()}, actor: admin)

    created =
      for step_attrs <- steps do
        Analytics.create_funnel_step!(Map.put(step_attrs, :funnel_id, funnel.id), actor: admin)
      end

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/funnels/#{funnel.id}")
    {funnel, created, lv, html}
  end

  test "editors are redirected away", %{conn: conn} do
    admin = authed_user(:admin)
    funnel = Analytics.create_funnel!(%{name: "Signup", slug: slug()}, actor: admin)

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/funnels/#{funnel.id}")
  end

  test "an unknown funnel id bounces back to the index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/editor/funnels"}}} =
             conn
             |> log_in(authed_user(:admin))
             |> live(~p"/editor/funnels/#{Ash.UUID.generate()}")
  end

  test "saving settings updates name, slug and active", %{conn: conn} do
    admin = authed_user(:admin)
    {funnel, [], lv, _html} = builder(conn, admin)

    html =
      lv
      |> form("form[phx-submit=save_funnel]", %{
        funnel: %{name: "Renamed", slug: funnel.slug, active: "false"}
      })
      |> render_submit()

    assert html =~ "Saved."
    updated = Analytics.get_funnel!(funnel.id, authorize?: false)
    assert updated.name == "Renamed"
    refute updated.active
  end

  test "picking a content type reloads the item picker, and adding a step creates it",
       %{conn: conn} do
    admin = authed_user(:admin)
    page = CMS.create_page!(%{title: "About", slug: "funb-about-#{slug()}"}, actor: admin)

    {funnel, [], lv, _html} = builder(conn, admin)

    # Selecting the type re-renders the item picker with that type's records.
    html =
      lv
      |> element("#step-type")
      |> render_change(%{"type" => "page"})

    assert html =~ page.title

    lv
    |> form("form[phx-submit=add_step]", %{content_id: page.id})
    |> render_submit()

    assert [step] = Analytics.funnel_steps_for!(funnel.id, authorize?: false)
    assert step.content_type == "page"
    assert step.content_id == page.id
  end

  test "a stale content id from a since-switched-away type is rejected, not silently mismatched",
       %{conn: conn} do
    admin = authed_user(:admin)
    page = CMS.create_page!(%{title: "About", slug: "funb-stale-#{slug()}"}, actor: admin)

    {funnel, [], lv, _html} = builder(conn, admin)

    # Switch the server's current type to "post" — as if the type dropdown
    # changed after the page id was already selected in the DOM.
    lv |> element("#step-type") |> render_change(%{"type" => "post"})

    # The submit races ahead with the stale page id instead of a post id.
    html = render_submit(lv, "add_step", %{"content_id" => page.id})

    assert html =~ "That item is no longer available"
    assert Analytics.funnel_steps_for!(funnel.id, authorize?: false) == []
  end

  test "adding a step without picking an item shows an error", %{conn: conn} do
    admin = authed_user(:admin)
    {funnel, [], lv, _html} = builder(conn, admin)

    html =
      lv
      |> form("form[phx-submit=add_step]", %{content_id: ""})
      |> render_submit()

    assert html =~ "Pick a content item first."
    assert Analytics.funnel_steps_for!(funnel.id, authorize?: false) == []
  end

  test "drag reorder persists positions", %{conn: conn} do
    admin = authed_user(:admin)

    {funnel, [a, b], lv, _html} =
      builder(conn, admin, [
        %{content_type: "page", content_id: Ash.UUID.generate(), position: 0},
        %{content_type: "page", content_id: Ash.UUID.generate(), position: 1}
      ])

    render_hook(lv, "reorder", %{"order" => [b.id, a.id]})

    ids = funnel.id |> Analytics.funnel_steps_for!(authorize?: false) |> Enum.map(& &1.id)
    assert ids == [b.id, a.id]
  end

  test "removing a step deletes it", %{conn: conn} do
    admin = authed_user(:admin)

    {funnel, [step], lv, _html} =
      builder(conn, admin, [%{content_type: "page", content_id: Ash.UUID.generate()}])

    lv
    |> element(~s(button[phx-click="remove_step"][phx-value-id="#{step.id}"]))
    |> render_click()

    assert Analytics.funnel_steps_for!(funnel.id, authorize?: false) == []
  end
end
