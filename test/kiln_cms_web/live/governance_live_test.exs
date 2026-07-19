defmodule KilnCMSWeb.GovernanceLiveTest do
  @moduledoc "Governance dashboard LiveView + export (#352)."
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "gov-live-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "govl-#{System.unique_integer([:positive])}"

  test "editors are redirected away (admin-only)", %{conn: conn} do
    conn = log_in(conn, authed_user(:editor))
    assert {:error, {:redirect, _}} = live(conn, ~p"/editor/governance")
  end

  test "the index lists content and links to its trail", %{conn: conn} do
    admin = authed_user(:admin)
    CMS.create_post!(%{title: "Auditable Post", slug: slug()}, actor: admin)

    {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")
    assert html =~ "Governance"
    assert html =~ "Auditable Post"
  end

  test "the detail shows the version timeline and consents", %{conn: conn} do
    admin = authed_user(:admin)
    post = CMS.create_post!(%{title: "Detailed Post", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    CMS.record_consent!(
      %{content_type: "post", content_id: post.id, kind: :reviewer_signoff, grantor: "Dr. Ada"},
      actor: admin
    )

    {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")
    assert html =~ "Detailed Post"
    assert html =~ "Version timeline"
    assert html =~ "publish"
    assert html =~ "reviewer_signoff"
    assert html =~ "Dr. Ada"
  end

  test "the export endpoint returns the trail JSON to admins only", %{conn: conn} do
    admin = authed_user(:admin)
    post = CMS.create_post!(%{title: "Exported", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    body =
      conn
      |> log_in(admin)
      |> get(~p"/editor/governance/post/#{post.id}/export.json")
      |> json_response(200)

    assert body["item"]["title"] == "Exported"
    assert is_list(body["timeline"])

    # Editors are forbidden.
    forbidden =
      conn
      |> log_in(authed_user(:editor))
      |> get(~p"/editor/governance/post/#{post.id}/export.json")

    assert forbidden.status == 403
  end

  test "the detail shows the chain status and can record a consent (#352/#356)", %{conn: conn} do
    admin = authed_user(:admin)
    post = CMS.create_post!(%{title: "Chain Post", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    {:ok, view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

    # An anchor was minted at publish; no signing key in test config → intact/unsigned.
    assert html =~ "chain-status"
    assert html =~ "History intact" or html =~ "History verified"

    # Record a consent from the dashboard.
    view
    |> form("#record-consent-form", %{
      "consent" => %{
        "kind" => "reviewer_signoff",
        "grantor" => "Dr. Grace",
        "reference" => "TICKET-42",
        "note" => ""
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "Dr. Grace"
    assert html =~ "TICKET-42"

    assert [consent] = CMS.list_consents_for!("post", post.id, authorize?: false)
    assert consent.kind == :reviewer_signoff
  end

  test "old → new value diffs are shown in the timeline (#352)", %{conn: conn} do
    admin = authed_user(:admin)
    post = CMS.create_post!(%{title: "Before", slug: slug()}, actor: admin)
    CMS.update_post!(post, %{title: "After"}, actor: admin)

    {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

    assert html =~ "Before"
    assert html =~ "After"
  end
end
