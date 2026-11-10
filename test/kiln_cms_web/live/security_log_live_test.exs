defmodule KilnCMSWeb.SecurityLogLiveTest do
  @moduledoc """
  The console screen behind `/editor/security-log` (#2241): admin-only, scoped
  to the request's site, filters in the URL, keyset "load more", and the
  retention form (with its keep-forever warning).
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Security

  @moduletag :capture_log
  @password "password1234!"

  setup do
    %{org: seed_org()}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/security-log")
    end

    for role <- [:editor, :viewer] do
      test "turns away a #{role} of this very site", %{conn: conn, org: org} do
        user = authed_user(unquote(role))
        grant_tier(user, org, unquote(role))
        record!(org, %{actor_label: "secret-#{unquote(role)}@example.com"})

        assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
                 conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/security-log")
      end
    end

    test "shows an admin their site's events, newest first", %{conn: conn, org: org} do
      record!(org, %{actor_label: "older@example.com", ip: "203.0.113.1"})
      Process.sleep(5)

      record!(org, %{
        type: :sign_in_failed,
        actor_label: "newer@example.com",
        ip: "203.0.113.2",
        user_agent: "Mozilla/5.0"
      })

      {:ok, _lv, html} = admin_conn(conn, org) |> live(~p"/editor/security-log")

      assert html =~ "Security log"
      assert html =~ "Failed sign-in"
      assert html =~ "203.0.113.2"
      assert html =~ "Mozilla/5.0"
      assert html =~ "UTC"
      assert position(html, "newer@example.com") < position(html, "older@example.com")
    end

    test "shows the empty state when nothing is recorded", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_conn(conn, org) |> live(~p"/editor/security-log")
      assert has_element?(lv, "#security-log-empty")
    end

    test "an admin of another site sees none of this site's events", %{conn: conn, org: org} do
      other = seed_org()
      record!(org, %{actor_label: "mine@example.com"})
      record!(other, %{actor_label: "theirs@example.com"})

      # Their own site: only their own event.
      {:ok, _lv, html} = admin_conn(conn, other) |> live(~p"/editor/security-log")
      assert html =~ "theirs@example.com"
      refute html =~ "mine@example.com"

      # This site, as the other site's admin: turned away.
      outsider = authed_user(:editor)
      grant_tier(outsider, other, :admin)

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> org_conn(org) |> log_in(outsider) |> live(~p"/editor/security-log")
    end

    test "escapes an attacker-chosen label and user agent", %{conn: conn, org: org} do
      record!(org, %{
        actor_label: "<script>alert(1)</script>",
        user_agent: "<img src=x onerror=alert(2)>"
      })

      {:ok, _lv, html} = admin_conn(conn, org) |> live(~p"/editor/security-log")

      refute html =~ "<script>alert(1)"
      refute html =~ "<img src=x"
      assert html =~ "&lt;script&gt;alert(1)"
    end
  end

  describe "filters" do
    setup %{org: org} do
      member = authed_user(:editor)
      grant_tier(member, org, :editor)
      %{member: member}
    end

    test "by event type", %{conn: conn, org: org} do
      record!(org, %{type: :sign_in, actor_label: "signin@example.com"})
      record!(org, %{type: :api_key_created, actor_label: "apikey@example.com"})

      {:ok, _lv, html} =
        admin_conn(conn, org) |> live(~p"/editor/security-log?type=api_key_created")

      assert html =~ "apikey@example.com"
      refute html =~ "signin@example.com"
    end

    test "by actor email, resolved among this site's members", %{
      conn: conn,
      org: org,
      member: member
    } do
      record!(org, %{actor_id: member.id, actor_label: member.email |> to_string()})
      record!(org, %{actor_label: "someone-else@example.com"})

      email = member.email |> to_string() |> String.upcase()
      {:ok, _lv, html} = admin_conn(conn, org) |> live(~p"/editor/security-log?actor=#{email}")

      assert html =~ String.downcase(email)
      refute html =~ "someone-else@example.com"
    end

    test "an address that is no member here shows nothing, not everything", %{
      conn: conn,
      org: org
    } do
      stranger = authed_user(:editor)
      elsewhere = seed_org()
      grant_tier(stranger, elsewhere, :editor)
      # The address is in ANOTHER site's log, which must not resolve here.
      record!(elsewhere, %{actor_id: stranger.id, actor_label: to_string(stranger.email)})
      record!(org, %{actor_label: "visible@example.com"})

      {:ok, lv, html} =
        admin_conn(conn, org)
        |> live(~p"/editor/security-log?actor=#{to_string(stranger.email)}")

      refute html =~ "visible@example.com"
      assert has_element?(lv, "#security-log-unknown-actor")
    end

    test "by date range, both days included", %{conn: conn, org: org} do
      old = ~U[2026-01-10 12:00:00.000000Z]
      recent = ~U[2026-02-10 12:00:00.000000Z]
      record!(org, %{actor_label: "jan@example.com"}, old)
      record!(org, %{actor_label: "feb@example.com"}, recent)

      {:ok, _lv, html} =
        admin_conn(conn, org) |> live(~p"/editor/security-log?from=2026-01-10&to=2026-01-10")

      assert html =~ "jan@example.com"
      refute html =~ "feb@example.com"
    end

    test "the form patches the URL, and a junk date is ignored", %{conn: conn, org: org} do
      record!(org, %{type: :sign_in, actor_label: "signin@example.com"})
      record!(org, %{type: :passkey_added, actor_label: "passkey@example.com"})

      {:ok, lv, _html} = admin_conn(conn, org) |> live(~p"/editor/security-log")

      html =
        lv
        |> form("#security-log-filters", filters: %{type: "passkey_added"})
        |> render_submit()

      assert_patch(lv, ~p"/editor/security-log?type=passkey_added")
      assert html =~ "passkey@example.com"
      refute html =~ "signin@example.com"

      {:ok, _lv, html} =
        admin_conn(conn, org) |> live(~p"/editor/security-log?from=not-a-date&type=bogus")

      assert html =~ "signin@example.com"
    end

    test "the download link carries the filters", %{conn: conn, org: org} do
      {:ok, lv, _html} =
        admin_conn(conn, org) |> live(~p"/editor/security-log?type=sign_in&from=2026-01-01")

      href = lv |> element("#security-log-export") |> render() |> Floki.parse_fragment!()
      assert inspect(href) =~ "/editor/security-log/export.csv?from=2026-01-01&type=sign_in"
    end
  end

  describe "load more" do
    test "pages 50 at a time", %{conn: conn, org: org} do
      for n <- 1..55, do: record!(org, %{actor_label: "row#{n}@example.com"})

      {:ok, lv, html} = admin_conn(conn, org) |> live(~p"/editor/security-log")

      assert length(Regex.scan(~r/id="security-event-/, html)) == 50
      assert has_element?(lv, "#security-log-load-more")

      html = lv |> element("#security-log-load-more") |> render_click()

      assert length(Regex.scan(~r/id="security-event-/, html)) == 55
      refute has_element?(lv, "#security-log-load-more")
    end
  end

  # A type a newer release added, read by this one during a rolling deploy or
  # after a rollback: one such row used to take the whole page down.
  describe "a type a newer release recorded (#2509)" do
    alias KilnCMS.NewerReleaseRows

    test "is listed, labeled with its stored name in a neutral badge", %{conn: conn, org: org} do
      record!(org, %{type: :sign_in_failed, actor_label: "known@example.com"})

      id =
        NewerReleaseRows.security_event!(%{
          org_id: org.id,
          actor_label: "newer@example.com",
          ip: "203.0.113.9"
        })

      {:ok, lv, html} = admin_conn(conn, org) |> live(~p"/editor/security-log")

      assert html =~ "known@example.com"
      assert html =~ "Failed sign-in"

      row = lv |> element("#security-event-#{id}") |> render()
      assert row =~ "Unrecognized event (#{NewerReleaseRows.unknown()})"
      assert row =~ "newer@example.com"
      assert row =~ "203.0.113.9"
      assert row =~ "bg-base-200"
      refute row =~ "bg-warning"
    end

    test "a known type filter leaves it out; an unknown type param is ignored", %{
      conn: conn,
      org: org
    } do
      record!(org, %{type: :sign_in, actor_label: "signin@example.com"})
      NewerReleaseRows.security_event!(%{org_id: org.id, actor_label: "newer@example.com"})

      {:ok, _lv, html} = admin_conn(conn, org) |> live(~p"/editor/security-log?type=sign_in")
      assert html =~ "signin@example.com"
      refute html =~ "newer@example.com"

      {:ok, _lv, html} =
        admin_conn(conn, org)
        |> live(~p"/editor/security-log?type=#{NewerReleaseRows.unknown()}")

      assert html =~ "signin@example.com"
      assert html =~ "newer@example.com"
    end

    test "the actor filter finds a person whose only event is one", %{conn: conn, org: org} do
      someone = Ash.UUID.generate()

      NewerReleaseRows.security_event!(%{
        org_id: org.id,
        actor_id: someone,
        actor_label: "only-new@example.com"
      })

      record!(org, %{actor_label: "someone-else@example.com"})

      {:ok, _lv, html} =
        admin_conn(conn, org) |> live(~p"/editor/security-log?actor=only-new@example.com")

      assert html =~ "Unrecognized event"
      refute html =~ "someone-else@example.com"
    end

    test "load more pages past it", %{conn: conn, org: org} do
      id =
        NewerReleaseRows.security_event!(%{
          org_id: org.id,
          inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      for n <- 1..50, do: record!(org, %{actor_label: "row#{n}@example.com"})

      {:ok, lv, _html} = admin_conn(conn, org) |> live(~p"/editor/security-log")
      refute has_element?(lv, "#security-event-#{id}")

      lv |> element("#security-log-load-more") |> render_click()
      assert has_element?(lv, "#security-event-#{id}")
    end
  end

  describe "retention" do
    test "shows the window and saves a new one", %{conn: conn, org: org} do
      {:ok, lv, html} = admin_conn(conn, org) |> live(~p"/editor/security-log")
      assert html =~ "365 days after they happen"
      refute has_element?(lv, "#security-log-retention-warning")

      html =
        lv |> form("#security-log-retention-form", retention: %{days: "30"}) |> render_submit()

      assert html =~ "Retention saved."
      assert html =~ "30 days after they happen"
      assert Security.retention_days(org) == 30
    end

    test "0 keeps forever and shows the warning", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_conn(conn, org) |> live(~p"/editor/security-log")

      html =
        lv |> form("#security-log-retention-form", retention: %{days: "0"}) |> render_submit()

      assert html =~ "Events are kept forever."
      assert has_element?(lv, "#security-log-retention-warning")
      assert render(lv) =~ "raw IP addresses"
      assert Security.retention_days(org) == 0
    end

    test "a bad value is refused and nothing changes", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_conn(conn, org) |> live(~p"/editor/security-log")

      for bad <- ["-1", "abc", "36501", "1.5"] do
        html =
          lv |> form("#security-log-retention-form", retention: %{days: bad}) |> render_submit()

        assert html =~ "Enter a whole number of days" or html =~ "could not be saved"
      end

      assert Security.retention_days(org) == 365
    end

    test "an admin who lost the tier cannot submit the form", %{conn: conn, org: org} do
      admin = authed_user(:editor)
      membership = grant_tier(admin, org, :admin)
      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(admin) |> live(~p"/editor/security-log")

      # The tier is revoked while the socket is open: the event re-checks.
      Ash.Seed.update!(membership, %{role: :editor})

      html =
        lv |> form("#security-log-retention-form", retention: %{days: "7"}) |> render_submit()

      assert html =~ "don&#39;t have permission"
      assert Security.retention_days(org) == 365
    end
  end

  defp record!(org, attrs, at \\ nil) do
    event =
      Security.record!(Map.merge(%{type: :sign_in}, attrs),
        actor: Security.system(),
        tenant: org.id
      )

    if at do
      KilnCMS.Repo.query!("UPDATE security_events SET inserted_at = $1 WHERE id = $2", [
        at,
        Ecto.UUID.dump!(event.id)
      ])
    end

    event
  end

  defp position(html, needle) do
    {pos, _len} = :binary.match(html, needle)
    pos
  end

  defp admin_conn(conn, org) do
    admin = authed_user(:editor)
    grant_tier(admin, org, :admin)
    conn |> org_conn(org) |> log_in(admin)
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Log Site",
      slug: "seclog-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "seclog-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

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
