defmodule KilnCMSWeb.GovernanceLiveTest do
  @moduledoc """
  Governance dashboard LiveView + export (#352).

  `async: false` since #858: the live-claims panel resolves
  `KilnCMS.Compliance.Settings`, which reads application env and a shared
  Cachex. Both are VM-global, so an async sibling would see this file's
  configuration — the failure that looks like a race and is not one.
  """
  use KilnCMSWeb.ConnCase, async: false

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

  test "the CSV export returns the flat trail to admins only", %{conn: conn} do
    admin = authed_user(:admin)
    post = CMS.create_post!(%{title: "CSV, \"Exported\"", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    CMS.record_consent!(
      %{content_type: "post", content_id: post.id, kind: :reviewer_signoff, grantor: "Dr. Ada"},
      actor: admin
    )

    response =
      conn
      |> log_in(admin)
      |> get(~p"/editor/governance/post/#{post.id}/export.csv")

    assert response.status == 200
    assert response.resp_headers |> List.keyfind("content-type", 0) |> elem(1) =~ "text/csv"

    body = response.resp_body
    assert String.starts_with?(body, "kind,at,action,who,publish,changed")
    assert body =~ "version,"
    assert body =~ "publish"
    # The acting user lands in the "who" column; consents ride along.
    assert body =~ to_string(admin.email)
    assert body =~ "consent,"
    assert body =~ "Dr. Ada"

    # Editors are forbidden.
    forbidden =
      conn
      |> log_in(authed_user(:editor))
      |> get(~p"/editor/governance/post/#{post.id}/export.csv")

    assert forbidden.status == 403
  end

  test "the timeline shows who made each change (#352)", %{conn: conn} do
    admin = authed_user(:admin)
    post = CMS.create_post!(%{title: "Who Post", slug: slug()}, actor: admin)

    {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")
    assert html =~ to_string(admin.email)
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

  # #858. `docs/p3-plan.md` said claim checks would feed this dashboard and they
  # never did — the findings lived only in the editor's panel and the publish
  # gate's refusal, neither of which answers "what is published in our name".
  describe "live claims panel (#858)" do
    setup do
      original = Application.get_env(:kiln_cms, KilnCMS.Compliance)
      org = KilnCMS.Accounts.default_org_id()

      on_exit(fn ->
        Application.put_env(:kiln_cms, KilnCMS.Compliance, original || [])
        KilnCMS.Cache.bust_compliance(org)
      end)

      # `Settings.for_org/1` is cached per org, so setting application env
      # without busting leaves the page rendering the previous configuration.
      configure = fn opts ->
        Application.put_env(:kiln_cms, KilnCMS.Compliance, opts)
        KilnCMS.Cache.bust_compliance(org)
      end

      %{configure: configure}
    end

    test "a published claim is named on the dashboard", %{conn: conn, configure: configure} do
      configure.(enabled: true, rules: :default)
      admin = authed_user(:admin)

      %{title: "Our clinically proven method", slug: slug()}
      |> CMS.create_page!(actor: admin)
      |> CMS.publish_page!(%{}, actor: admin)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "Live claims"
      assert html =~ "Our clinically proven method"
      # The phrase itself, not just the document: a report that says a page is
      # flagged without saying what it said sends the reader back to the editor
      # to find out, which is the trip this panel exists to save.
      assert html =~ "clinically proven"
      assert html =~ "would refuse a publish"
    end

    test "off is rendered as off, not as a clean bill of health", %{
      conn: conn,
      configure: configure
    } do
      configure.(enabled: false, rules: :default)
      admin = authed_user(:admin)

      %{title: "Our clinically proven method", slug: slug()}
      |> CMS.create_page!(actor: admin)
      |> CMS.publish_page!(%{}, actor: admin)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "Claim checking is off for this site"
      # And it must not quietly report the flagged page as clean.
      refute html =~ "No flagged claims"
    end

    test "a site with nothing flagged says so", %{conn: conn, configure: configure} do
      configure.(enabled: true, rules: :default)
      admin = authed_user(:admin)

      %{title: "An ordinary page", slug: slug()}
      |> CMS.create_page!(actor: admin)
      |> CMS.publish_page!(%{}, actor: admin)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "No flagged claims"
      assert html =~ "scanned"
    end
  end
end
