defmodule KilnCMSWeb.InstanceSecurityLogLiveTest do
  @moduledoc """
  The instance security log page and its CSV (#2541): platform admins only.
  The default site's admin, who clears the console's per-site admin gate, is
  turned away by the page and refused the download; a platform admin reads and
  exports. A canceled backup is shown here and not in the default site's log.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Security

  @moduletag :capture_log
  @password "password1234!"

  describe "page access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(conn, ~p"/editor/instance-security-log")
    end

    test "turns away the default site's admin, who is no platform admin", %{conn: conn} do
      record!(%{actor_label: "ops@example.com"})
      user = default_site_admin()

      # The premise: they clear the route's per-site admin gate.
      assert Accounts.Scoping.effective_tier(user, Accounts.default_org_id()) == :admin

      assert {:error, {:live_redirect, %{to: "/access-denied?needs=platform"}}} =
               conn |> log_in(user) |> live(~p"/editor/instance-security-log")
    end

    test "a platform admin sees the events, filters by type and actor", %{conn: conn} do
      record!(%{
        actor_id: Ecto.UUID.generate(),
        actor_label: "ops@example.com",
        ip: "203.0.113.7",
        target_type: "backup_run"
      })

      {:ok, lv, html} =
        conn |> log_in(authed_user(:admin)) |> live(~p"/editor/instance-security-log")

      assert html =~ "Instance security log"
      assert html =~ "Backup canceled"
      assert html =~ "ops@example.com"
      assert html =~ "203.0.113.7"
      assert has_element?(lv, "#instance-security-log-retention", "365 days")

      lv
      |> form("#instance-security-log-filters", filters: %{actor: "nobody@example.com"})
      |> render_submit()

      assert has_element?(lv, "#instance-security-log-unknown-actor")
      refute render(lv) =~ "203.0.113.7"

      lv
      |> form("#instance-security-log-filters", filters: %{actor: "OPS@example.com"})
      |> render_submit()

      assert render(lv) =~ "203.0.113.7"
    end

    test "events are refused once the platform grant expires mid-session", %{conn: conn} do
      record!(%{actor_label: "ops@example.com"})
      # Long enough for a slow sign-in and mount on a busy host to finish first.
      expires_at = DateTime.add(DateTime.utc_now(), 5, :second)

      user =
        authed_user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: expires_at
        })

      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/instance-security-log")

      Process.sleep(max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0) + 100)

      html =
        lv
        |> form("#instance-security-log-filters", filters: %{type: "backup_canceled"})
        |> render_submit()

      assert html =~ "Only platform administrators can view the instance security log."
    end
  end

  describe "where a canceled backup shows" do
    test "the site log links here for a platform admin only", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/security-log")
      assert has_element?(lv, "#security-log-instance-link")

      {:ok, lv, _html} = conn |> log_in(default_site_admin()) |> live(~p"/editor/security-log")
      refute has_element?(lv, "#security-log-instance-link")
    end

    test "the default site's admin does not see an instance event in their log", %{conn: conn} do
      record!(%{actor_label: "ops-secret@example.com"})

      {:ok, _lv, html} = conn |> log_in(default_site_admin()) |> live(~p"/editor/security-log")
      refute html =~ "ops-secret@example.com"
      refute html =~ "Backup canceled"
    end
  end

  describe "CSV" do
    test "a platform admin downloads the instance log", %{conn: conn} do
      record!(%{actor_label: "ops@example.com", ip: "203.0.113.7"})

      conn =
        conn
        |> log_in(authed_user(:admin))
        |> get(~p"/editor/instance-security-log/export.csv")

      assert response(conn, 200)

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "instance-security-log-"
      assert conn.resp_body =~ "backup_canceled"
      assert conn.resp_body =~ "ops@example.com"
      assert conn.resp_body =~ "203.0.113.7"
    end

    test "the default site's admin and anonymous callers are refused", %{conn: conn} do
      record!(%{actor_label: "ops-secret@example.com"})

      for c <- [log_in(conn, default_site_admin()), conn] do
        c = get(c, ~p"/editor/instance-security-log/export.csv")
        assert json_response(c, 403)["error"] == "admin_required"
        refute c.resp_body =~ "ops-secret@example.com"
      end
    end

    test "the site CSV does not carry an instance event", %{conn: conn} do
      record!(%{actor_label: "ops-secret@example.com"})

      conn =
        conn |> log_in(default_site_admin()) |> get(~p"/editor/security-log/export.csv")

      assert response(conn, 200)
      refute conn.resp_body =~ "ops-secret@example.com"
    end
  end

  defp record!(attrs) do
    Security.record_instance_event!(Map.merge(%{type: :backup_canceled}, attrs),
      actor: Security.system()
    )
  end

  defp default_site_admin do
    user = authed_user(:editor)

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: Accounts.default_org_id(),
      role: :admin
    })

    user
  end

  defp authed_user(role, attrs \\ %{}) do
    email = "instlog-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
