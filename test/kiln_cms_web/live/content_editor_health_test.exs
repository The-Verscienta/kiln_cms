defmodule KilnCMSWeb.ContentEditorHealthTest do
  @moduledoc """
  The freshness axis in the content editor's header
  (`docs/content-lifecycles.md`): a health pill next to the workflow state
  badge, and a **Mark reviewed** button that appears only when the health is
  actually asking for one.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "health-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "health-#{System.unique_integer([:positive])}"

  defp published_page(admin, attrs \\ %{}) do
    CMS.create_page!(Map.merge(%{title: "Monograph", slug: slug()}, attrs), actor: admin)
    |> CMS.publish_page!(%{}, actor: admin)
  end

  defp backdate!(record, days) do
    record
    |> Ash.Changeset.for_update(:backdate_published_at, %{
      published_at: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    })
    |> Ash.update!(authorize?: false)
  end

  test "fresh content shows no pill and no button", %{conn: conn} do
    admin = authed_user(:admin)
    page = published_page(admin, %{review_after_days: 365})

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    refute html =~ "Mark reviewed"
    refute html =~ "Overdue"
  end

  test "overdue content shows the pill and the button", %{conn: conn} do
    admin = authed_user(:admin)
    page = published_page(admin, %{review_after_days: 5}) |> backdate!(40)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    assert html =~ "Overdue"
    assert html =~ "Mark reviewed"
  end

  test "marking reviewed stamps the attestation and clears the pill", %{conn: conn} do
    admin = authed_user(:admin)
    page = published_page(admin, %{review_after_days: 5}) |> backdate!(40)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    html = lv |> element("button[phx-click='mark_reviewed']") |> render_click()

    assert CMS.get_page!(page.id, actor: admin).last_reviewed_at
    # The header re-renders from a re-fetched record, so the calculations moved
    # with it — a stale assign would have left the pill up.
    refute html =~ "Overdue"
    refute html =~ "Mark reviewed"
  end

  test "an expired flagged record reads expired, not overdue", %{conn: conn} do
    admin = authed_user(:admin)

    page =
      published_page(admin, %{expiry_action: :flag})
      |> CMS.update_page!(
        %{unpublish_at: DateTime.add(DateTime.utc_now(), -86_400, :second)},
        actor: admin
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    assert html =~ "Expired"
    assert html =~ "Mark reviewed"
  end
end
