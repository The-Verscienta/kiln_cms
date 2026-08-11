defmodule KilnCMSWeb.FunnelLiveTest do
  @moduledoc """
  The funnels index (`/editor/funnels`, admin-only): create (landing in the
  builder) and delete funnels. Picking steps happens in `FunnelBuilderLive`
  (see `funnel_builder_live_test.exs`).
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Analytics

  @password "password123456"

  defp authed_user(role) do
    email = "funl-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "funl-#{System.unique_integer([:positive])}"

  test "editors are redirected away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/funnels")
  end

  test "creating a funnel lands in its builder", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/funnels")

    funnel_slug = slug()

    lv
    |> form("form[phx-submit=create_funnel]", %{funnel: %{name: "Signup", slug: funnel_slug}})
    |> render_submit()

    assert [created] =
             Analytics.list_funnels!(authorize?: false, query: [filter: [slug: funnel_slug]])

    {path, _flash} = assert_redirect(lv)
    assert path == "/editor/funnels/#{created.id}"
  end

  test "funnels list links each funnel to its builder and shows its step count", %{conn: conn} do
    admin = authed_user(:admin)
    funnel = Analytics.create_funnel!(%{name: "Signup", slug: slug()}, actor: admin)

    Analytics.create_funnel_step!(
      %{funnel_id: funnel.id, content_type: "page", content_id: Ash.UUID.generate()},
      actor: admin
    )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/funnels")
    assert html =~ ~s(href="/editor/funnels/#{funnel.id}")
    assert html =~ "1 steps"
  end

  test "deleting a funnel removes it from the list", %{conn: conn} do
    admin = authed_user(:admin)
    funnel = Analytics.create_funnel!(%{name: "Signup", slug: slug()}, actor: admin)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/funnels")

    html =
      lv
      |> element(~s(button[phx-click="delete_funnel"][phx-value-id="#{funnel.id}"]))
      |> render_click()

    assert html =~ "Funnel deleted."
    assert {:error, _} = Analytics.get_funnel(funnel.id, authorize?: false)
  end
end
