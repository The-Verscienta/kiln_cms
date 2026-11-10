defmodule KilnCMSWeb.SecurityLogExportControllerTest do
  @moduledoc """
  The security log CSV (#2241): admin-only, the page's filters, this site's
  rows only, and formula-injection-safe cells.

  `async: false`: the 413 test lowers the export cap with `Application.put_env/3`,
  which is VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.NewerReleaseRows
  alias KilnCMS.Security

  @moduletag :capture_log
  @password "password1234!"

  setup do
    %{org: seed_org()}
  end

  describe "tier gate" do
    test "an anonymous caller is refused", %{conn: conn, org: org} do
      conn = conn |> org_conn(org) |> get(~p"/editor/security-log/export.csv")
      assert json_response(conn, 403)["error"] == "admin_required"
    end

    for role <- [:editor, :viewer] do
      test "a #{role} is refused", %{conn: conn, org: org} do
        user = authed_user(unquote(role))
        grant_tier(user, org, unquote(role))
        record!(org, %{actor_label: "secret@example.com"})

        conn = conn |> org_conn(org) |> log_in(user) |> get(~p"/editor/security-log/export.csv")

        assert json_response(conn, 403)["error"] == "admin_required"
        refute conn.resp_body =~ "secret@example.com"
      end
    end

    test "an admin of another site is refused", %{conn: conn, org: org} do
      outsider = authed_user(:editor)
      grant_tier(outsider, seed_org(), :admin)

      conn = conn |> org_conn(org) |> log_in(outsider) |> get(~p"/editor/security-log/export.csv")
      assert json_response(conn, 403)["error"] == "admin_required"
    end
  end

  describe "export" do
    test "an admin gets this site's rows only, as a CSV attachment", %{conn: conn, org: org} do
      record!(org, %{
        type: :sign_in_failed,
        actor_label: "mine@example.com",
        ip: "203.0.113.9",
        user_agent: "Mozilla/5.0"
      })

      record!(seed_org(), %{actor_label: "theirs@example.com"})

      conn = admin_conn(conn, org) |> get(~p"/editor/security-log/export.csv")

      assert response(conn, 200)
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/csv"
      assert [disp] = get_resp_header(conn, "content-disposition")
      assert disp =~ "attachment"

      assert conn.resp_body =~ "time,type,actor,target_type,target_id,ip,user_agent"
      assert conn.resp_body =~ "sign_in_failed,mine@example.com,,,203.0.113.9,Mozilla/5.0"
      refute conn.resp_body =~ "theirs@example.com"
    end

    # A type a newer release added (#2509): exported under its stored name,
    # and left out by a known type filter.
    test "exports a type a newer release recorded under its stored name", %{
      conn: conn,
      org: org
    } do
      record!(org, %{type: :sign_in, actor_label: "signin@example.com"})

      NewerReleaseRows.security_event!(%{
        org_id: org.id,
        actor_label: "newer@example.com",
        ip: "203.0.113.10"
      })

      body = admin_conn(conn, org) |> get(~p"/editor/security-log/export.csv") |> response(200)

      assert body =~ "#{NewerReleaseRows.unknown()},newer@example.com,,,203.0.113.10,"
      assert body =~ "signin@example.com"

      body =
        admin_conn(conn, org)
        |> get(~p"/editor/security-log/export.csv?type=sign_in")
        |> response(200)

      assert body =~ "signin@example.com"
      refute body =~ "newer@example.com"
    end

    test "honours the type filter", %{conn: conn, org: org} do
      record!(org, %{type: :sign_in, actor_label: "signin@example.com"})
      record!(org, %{type: :api_key_created, actor_label: "apikey@example.com"})

      conn =
        admin_conn(conn, org) |> get(~p"/editor/security-log/export.csv?type=api_key_created")

      assert conn.resp_body =~ "apikey@example.com"
      refute conn.resp_body =~ "signin@example.com"
    end

    test "honours the date range", %{conn: conn, org: org} do
      record!(org, %{actor_label: "jan@example.com"}, ~U[2026-01-10 12:00:00.000000Z])
      record!(org, %{actor_label: "feb@example.com"}, ~U[2026-02-10 12:00:00.000000Z])

      conn =
        admin_conn(conn, org)
        |> get(~p"/editor/security-log/export.csv?from=2026-02-01&to=2026-02-28")

      assert conn.resp_body =~ "feb@example.com"
      refute conn.resp_body =~ "jan@example.com"
    end

    test "an actor that is no member here exports only the header", %{conn: conn, org: org} do
      stranger = authed_user(:editor)
      elsewhere = seed_org()
      grant_tier(stranger, elsewhere, :editor)
      record!(elsewhere, %{actor_id: stranger.id, actor_label: to_string(stranger.email)})
      record!(org, %{actor_label: "visible@example.com"})

      conn =
        admin_conn(conn, org)
        |> get(~p"/editor/security-log/export.csv?actor=#{to_string(stranger.email)}")

      assert response(conn, 200) =~ "time,type"
      refute conn.resp_body =~ "visible@example.com"
    end

    test "neutralises spreadsheet formulas in attacker-chosen cells", %{conn: conn, org: org} do
      record!(org, %{
        actor_label: "=HYPERLINK(\"http://x\",\"y\")",
        user_agent: "+cmd|' /C calc'!A0"
      })

      conn = admin_conn(conn, org) |> get(~p"/editor/security-log/export.csv")
      body = conn.resp_body

      assert body =~ "\"'=HYPERLINK(\"\"http://x\"\",\"\"y\"\")\""
      assert body =~ "'+cmd|"
      refute body =~ ~r/(^|,)=HYPERLINK/m
      refute body =~ ~r/(^|,)\+cmd/m
    end

    test "pages through more than one keyset page", %{conn: conn, org: org} do
      for n <- 1..520, do: record!(org, %{actor_label: "row#{n}@example.com"})

      conn = admin_conn(conn, org) |> get(~p"/editor/security-log/export.csv")

      assert length(String.split(conn.resp_body, "\r\n", trim: true)) == 521
    end

    test "answers 413 over the row cap", %{conn: conn, org: org} do
      previous = Application.get_env(:kiln_cms, :content_export)
      Application.put_env(:kiln_cms, :content_export, max_rows: 2)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :content_export, previous),
          else: Application.delete_env(:kiln_cms, :content_export)
      end)

      for n <- 1..3, do: record!(org, %{actor_label: "row#{n}@example.com"})

      conn = admin_conn(conn, org) |> get(~p"/editor/security-log/export.csv")
      assert json_response(conn, 413)["error"] == "too_many_rows"
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

  defp admin_conn(conn, org) do
    admin = authed_user(:editor)
    grant_tier(admin, org, :admin)
    conn |> org_conn(org) |> log_in(admin)
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Export Site",
      slug: "secexp-#{System.unique_integer([:positive])}",
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
    email = "secexp-#{role}-#{System.unique_integer([:positive])}@example.com"

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
