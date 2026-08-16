defmodule KilnCMSWeb.GovernanceHealthTest do
  @moduledoc """
  The governance dashboard's **Content health** section
  (`docs/content-lifecycles.md`): counts by health, the worst offenders, the
  CSV export — and the distinction the panel exists to make, between "we
  checked and nothing is late" and "we have never asked".
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "gov-health-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "gov-health-#{System.unique_integer([:positive])}"

  defp overdue_page(admin, title) do
    page =
      CMS.create_page!(%{title: title, slug: slug(), review_after_days: 5}, actor: admin)
      |> CMS.publish_page!(%{}, actor: admin)

    page
    |> Ash.Changeset.for_update(:backdate_published_at, %{
      published_at: DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    })
    |> Ash.update!(authorize?: false)
  end

  test "says nothing is tracked when no content carries a lifecycle", %{conn: conn} do
    admin = authed_user(:admin)
    # Published, but with no cadence and no unpublish date.
    CMS.create_page!(%{title: "Plain", slug: slug()}, actor: admin)
    |> CMS.publish_page!(%{}, actor: admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/governance")

    assert html =~ "Content health"
    assert html =~ "nothing to age"
    # The distinction the panel exists to make: this must NOT read as a clean
    # bill of health.
    refute html =~ "Everything with a cadence is inside it"
  end

  test "reports a clean bill only when something is actually tracked", %{conn: conn} do
    admin = authed_user(:admin)

    CMS.create_page!(%{title: "Current", slug: slug(), review_after_days: 365}, actor: admin)
    |> CMS.publish_page!(%{}, actor: admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/governance")

    assert html =~ "Everything with a cadence is inside it"
    refute html =~ "nothing to age"
  end

  test "counts unhealthy content and lists the worst of it", %{conn: conn} do
    admin = authed_user(:admin)
    stale = overdue_page(admin, "Aconite monograph")

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/governance")

    assert html =~ "Overdue"
    assert html =~ stale.title
    assert html =~ ~p"/editor/content/page/#{stale.id}"
    refute html =~ "Everything with a cadence is inside it"
  end

  test "an expiry outranks an overdue review in the list", %{conn: conn} do
    admin = authed_user(:admin)
    overdue_page(admin, "Merely overdue")

    expired =
      CMS.create_page!(%{title: "Expired notice", slug: slug(), expiry_action: :flag},
        actor: admin
      )
      |> CMS.publish_page!(%{}, actor: admin)
      |> CMS.update_page!(
        %{unpublish_at: DateTime.add(DateTime.utc_now(), -86_400, :second)},
        actor: admin
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/governance")

    # Worst first: the expired row's link precedes the overdue one's.
    expired_at = :binary.match(html, "#{expired.id}") |> elem(0)
    overdue_at = :binary.match(html, "Merely overdue") |> elem(0)
    assert expired_at < overdue_at
  end

  describe "the CSV export" do
    test "carries every unhealthy row", %{conn: conn} do
      admin = authed_user(:admin)
      stale = overdue_page(admin, "Exportable monograph")

      conn = conn |> log_in(admin) |> get(~p"/editor/governance/health.csv")

      assert response_content_type(conn, :csv) =~ "text/csv"

      assert ["attachment; filename=\"content-health.csv\""] =
               get_resp_header(conn, "content-disposition")

      body = response(conn, 200)
      assert body =~ "type,title,health,due_at,id"
      assert body =~ stale.title
      assert body =~ "overdue"
    end

    test "is admin-only", %{conn: conn} do
      conn = conn |> log_in(authed_user(:editor)) |> get(~p"/editor/governance/health.csv")

      assert json_response(conn, 403) == %{"error" => "admin_required"}
    end
  end
end
