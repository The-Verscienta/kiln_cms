defmodule KilnCMSWeb.BackupDownloadControllerTest do
  @moduledoc """
  `POST /editor/backups/download` (part of #2225): a platform admin's
  one-minute link to one local file of a backup, refused for anyone else,
  for another session, on another server, and while the console shares an
  origin; audited before any byte is sent, and nothing sent when it can't be.

  `async: false`: it changes the VM-wide `KilnCMS.Backups` env (`:dir`), the
  download action's test seams, the rate limits and, in one describe,
  `:console_host`.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{Token, User}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, DirId}
  alias KilnCMS.Backups.Run.Actions.Download
  alias KilnCMS.RateLimitHelpers
  alias KilnCMS.Security
  alias KilnCMSWeb.BackupDownloadToken

  @password "password123456"
  @stamp "20261118-031700"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_dlc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :dir, dir))
    seams = Application.get_env(:kiln_cms, Download)
    RateLimitHelpers.restore_limits_on_exit()

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)

      if seams,
        do: Application.put_env(:kiln_cms, Download, seams),
        else: Application.delete_env(:kiln_cms, Download)

      File.rm_rf!(dir)
    end)

    data = :crypto.strong_rand_bytes(4_096)
    name = "kiln-db-#{@stamp}.dump"
    File.write!(Path.join([dir, "db", name]), data)

    run =
      %{stamp: @stamp, trigger: "test"}
      |> Backups.start_run!(actor: Backups.system())
      |> Backups.finish_run!(
        %{
          artifacts: [
            %{
              kind: :db,
              name: name,
              bytes: byte_size(data),
              verified: true,
              destinations: %{"local" => %{"status" => "ok"}}
            }
          ]
        },
        actor: Backups.system()
      )

    %{dir: dir, run: run, name: name, data: data}
  end

  defp seam(key, value) do
    Application.put_env(
      :kiln_cms,
      Download,
      Keyword.put(Application.get_env(:kiln_cms, Download, []), key, value)
    )
  end

  # A signed-in user: the struct carries this sign-in's token, so signing in
  # twice gives two sessions of one account.
  defp authed_user(role, attrs \\ %{}) do
    email = "dlc-#{role}-#{System.unique_integer([:positive])}@example.com"

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

    sign_in(email)
  end

  defp sign_in(email) do
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

  defp jti(user), do: Token.peeked_jti(user.__metadata__.token)

  defp token(user, run, name, opts \\ []) do
    BackupDownloadToken.sign(
      user,
      Keyword.get(opts, :jti, jti(user)),
      run.id,
      name,
      Keyword.get(opts, :dir_id, Backups.download_dir_id()),
      Keyword.take(opts, [:signed_at])
    )
  end

  defp download(conn, token), do: post(conn, ~p"/editor/backups/download", %{"token" => token})

  defp events do
    Security.list_instance_events!(%{type: :backup_downloaded}, authorize?: false)
  end

  defp error_code(conn),
    do: conn.resp_body |> String.split("error: ") |> List.last() |> String.trim()

  describe "a platform admin's download" do
    test "streams the file as an attachment and records it once", %{
      conn: conn,
      run: run,
      name: name,
      data: data
    } do
      admin = authed_user(:admin)
      conn = conn |> log_in(admin) |> download(token(admin, run, name))

      assert response(conn, 200) == data
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="#{name}")]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]

      assert [%{actor_id: actor_id, target_id: target_id, metadata: %{"file" => ^name}}] =
               events()

      assert {actor_id, target_id} == {admin.id, run.id}
    end

    test "the event is written before any byte is sent", %{conn: conn, run: run, name: name} do
      test = self()

      # The real recorder, wrapped: it reports whether the response had been
      # sent when it ran (`Plug.Adapters.Test.Conn` tells the test process).
      seam(:recorder, fn type, opts ->
        {:messages, messages} = Process.info(self(), :messages)
        send(test, {:recorded_before_send?, {:plug_conn, :sent} not in messages})
        KilnCMS.Security.Recorder.record(type, opts)
      end)

      admin = authed_user(:admin)
      conn = conn |> log_in(admin) |> download(token(admin, run, name))

      assert response(conn, 200)
      assert_received {:recorded_before_send?, true}
      assert [_event] = events()
    end

    test "an event that can't be written sends nothing: 503", %{run: run, name: name} do
      admin = authed_user(:admin)

      for answer <- [{:error, :boom}, :skipped] do
        seam(:recorder, fn _type, _opts -> answer end)
        conn = build_conn() |> log_in(admin) |> download(token(admin, run, name))

        assert response(conn, 503)
        assert error_code(conn) == "audit_failed"
        assert get_resp_header(conn, "content-disposition") == []
        assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      end

      assert events() == []
    end
  end

  describe "the link" do
    test "an expired one is 410", %{conn: conn, run: run, name: name} do
      admin = authed_user(:admin)
      signed_at = System.system_time(:second) - 61
      conn = conn |> log_in(admin) |> download(token(admin, run, name, signed_at: signed_at))

      assert response(conn, 410)
      assert error_code(conn) == "link_expired"
      assert events() == []
    end

    test "a forged, foreign-salt or missing one is 403", %{conn: conn, run: run} do
      admin = authed_user(:admin)
      conn = log_in(conn, admin)

      forged = Phoenix.Token.sign(KilnCMSWeb.Endpoint, "collab", %{"r" => run.id})

      for token <- [forged, "random", "abc%2F..%2Fetc", ""] do
        conn = download(conn, token)
        assert response(conn, 403)
        assert error_code(conn) == "invalid_link"
      end

      conn = post(conn, ~p"/editor/backups/download", %{})
      assert response(conn, 403)
      assert events() == []
    end

    test "another admin's link, and the same admin's from another session, are 403", %{
      conn: conn,
      run: run,
      name: name
    } do
      a = authed_user(:admin)
      b = authed_user(:admin)

      conn_b = conn |> log_in(b) |> download(token(a, run, name))
      assert response(conn_b, 403)
      assert error_code(conn_b) == "invalid_link"

      # The same account signed in twice: the link is session one's.
      a_again = sign_in(a.email |> to_string())
      assert jti(a_again) != jti(a)

      conn_a2 = build_conn() |> log_in(a_again) |> download(token(a, run, name))
      assert response(conn_a2, 403)
      assert error_code(conn_a2) == "invalid_link"

      # Minted for A, under B's own session: the user must match too.
      crossed = token(a, run, name, jti: jti(b))
      conn_x = build_conn() |> log_in(b) |> download(crossed)
      assert response(conn_x, 403)
      assert error_code(conn_x) == "invalid_link"

      # Session one itself is fine.
      assert build_conn() |> log_in(a) |> download(token(a, run, name)) |> response(200)
      assert length(events()) == 1
    end

    test "is a body parameter the request log never prints", %{conn: conn, run: run, name: name} do
      admin = authed_user(:admin)
      token = token(admin, run, name)
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert conn |> log_in(admin) |> download(token) |> response(200)
        end)

      assert log =~ "POST /editor/backups/download"
      assert log =~ ~s("token" => "[FILTERED]")
      refute log =~ token
    end

    test "a GET or HEAD is 405 and charges nothing", %{conn: conn, run: run, name: name} do
      RateLimitHelpers.put_limit(:export, 1)
      admin = authed_user(:admin)
      conn = log_in(conn, admin)

      for _ <- 1..3 do
        got = get(conn, ~p"/editor/backups/download")
        assert response(got, 405)
        assert get_resp_header(got, "allow") == ["POST"]

        assert conn |> head(~p"/editor/backups/download") |> response(405) == ""
      end

      assert conn |> download(token(admin, run, name)) |> response(200)
      assert length(events()) == 1
    end
  end

  describe "who" do
    test "anyone but a platform admin is 403 with a valid-looking link, and nothing recorded", %{
      conn: conn,
      run: run,
      name: name
    } do
      org_admin = authed_user(:viewer)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: Accounts.default_org_id(),
        user_id: org_admin.id,
        role: :admin
      })

      for user <- [authed_user(:editor), authed_user(:viewer), org_admin] do
        conn = build_conn() |> log_in(user) |> download(token(user, run, name))
        assert response(conn, 403)
        assert error_code(conn) == "admin_required"
      end

      admin = authed_user(:admin)
      anonymous = download(conn, token(admin, run, name))
      assert response(anonymous, 403)
      assert error_code(anonymous) == "admin_required"

      assert events() == []
    end

    test "an admin demoted between the click and the request is 403, with no bytes", %{
      conn: conn,
      run: run,
      name: name,
      data: data
    } do
      admin = authed_user(:admin)
      token = token(admin, run, name)

      {1, _} =
        KilnCMS.Repo.update_all(
          from(u in "users", where: u.id == type(^admin.id, :binary_id)),
          set: [role: "editor"]
        )

      conn = conn |> log_in(admin) |> download(token)
      assert response(conn, 403)
      refute conn.resp_body =~ data
      assert events() == []
    end

    test "a grant that expired since the click is 403", %{conn: conn, run: run, name: name} do
      user =
        authed_user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      token = token(user, run, name)

      {1, _} =
        KilnCMS.Repo.update_all(
          from(u in "users", where: u.id == type(^user.id, :binary_id)),
          set: [granted_role_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert conn |> log_in(user) |> download(token) |> response(403)
      assert events() == []
    end
  end

  describe "the file" do
    test "a name inside a correctly signed link is still matched against the row: 404", %{
      conn: conn,
      dir: dir,
      run: run
    } do
      File.write!(Path.join([dir, "db", "kiln-db-20261117-031700.dump"]), "other")
      File.write!(Path.join([dir, "db", "kiln-db-#{@stamp}.dump.partial"]), "partial")
      admin = authed_user(:admin)
      conn = log_in(conn, admin)

      bodies =
        for name <- [
              "../../etc/passwd",
              "/etc/passwd",
              "../db/kiln-db-#{@stamp}.dump",
              "kiln-db-20261117-031700.dump",
              "kiln-db-#{@stamp}.dump.partial",
              Artifact.sidecar_name(:media, @stamp),
              "manifest.json",
              String.duplicate("a", 300)
            ] do
          conn = download(conn, token(admin, run, name))
          assert response(conn, 404)
          assert error_code(conn) == "not_found"
          conn.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
      assert events() == []
    end

    test "a symlink and a pruned file are 404", %{conn: conn, dir: dir} do
      admin = authed_user(:admin)
      conn = log_in(conn, admin)

      linked = "kiln-db-20261116-031700.dump"
      File.ln_s!(Path.join(dir, "elsewhere"), Path.join([dir, "db", linked]))
      File.write!(Path.join(dir, "elsewhere"), "secret")
      link_run = imported!("20261116-031700", linked, %{"local" => %{"status" => "ok"}})

      pruned = "kiln-db-20261115-031700.dump"
      File.write!(Path.join([dir, "db", pruned]), "still here")
      pruned_run = imported!("20261115-031700", pruned, %{"local" => %{"status" => "pruned"}})

      for {run, name} <- [{link_run, linked}, {pruned_run, pruned}] do
        conn = download(conn, token(admin, run, name))
        assert response(conn, 404)
        refute conn.resp_body =~ "secret"
        refute conn.resp_body =~ "still here"
      end

      assert events() == []
    end

    test "a link whose server isn't this one is 409, and so is a run pinned elsewhere", %{
      conn: conn,
      dir: dir,
      run: run,
      name: name
    } do
      admin = authed_user(:admin)
      conn = log_in(conn, admin)
      {:ok, _here} = DirId.local(dir)

      other = download(conn, token(admin, run, name, dir_id: Ash.UUID.generate()))
      assert response(other, 409)
      assert error_code(other) == "other_server"

      # A click on a node with no id, answered here, where there is one.
      none = download(conn, token(admin, run, name, dir_id: nil))
      assert response(none, 409)

      pinned_name = "kiln-db-20261114-031700.dump"
      File.write!(Path.join([dir, "db", pinned_name]), "x")

      pinned =
        %{stamp: "20261114-031700", trigger: "test", dir_id: Ash.UUID.generate()}
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.finish_run!(
          %{artifacts: [%{kind: :db, name: pinned_name, bytes: 1, verified: true}]},
          actor: Backups.system()
        )

      conn = download(conn, token(admin, pinned, pinned_name))
      assert response(conn, 409)
      assert error_code(conn) == "other_server"
      assert events() == []
    end

    test "a backup still being written is 409", %{conn: conn, dir: dir} do
      admin = authed_user(:admin)
      name = "kiln-db-20261113-031700.dump"
      File.write!(Path.join([dir, "db", name]), "x")

      running =
        Backups.start_run!(%{stamp: "20261113-031700", trigger: "test"}, actor: Backups.system())

      conn = conn |> log_in(admin) |> download(token(admin, running, name))
      assert response(conn, 409)
      assert error_code(conn) == "in_progress"
      assert events() == []
    end
  end

  describe "the rate limit" do
    test "the :export bucket answers 429 and records nothing past it", %{
      conn: conn,
      run: run,
      name: name
    } do
      RateLimitHelpers.put_limit(:export, 2)
      admin = authed_user(:admin)
      other = authed_user(:admin)
      conn = log_in(conn, admin)

      for _ <- 1..2, do: assert(conn |> download(token(admin, run, name)) |> response(200))

      limited = download(conn, token(admin, run, name))
      assert response(limited, 429)
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) >= 1
      assert length(events()) == 2

      # Forged links are charged too.
      assert conn |> download("forged") |> response(429)

      # Another account's budget is untouched.
      assert build_conn() |> log_in(other) |> download(token(other, run, name)) |> response(200)
    end
  end

  describe "while the console shares an origin" do
    setup do
      previous = Application.get_env(:kiln_cms, :console_host)
      Application.delete_env(:kiln_cms, :console_host)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :console_host, previous),
          else: Application.delete_env(:kiln_cms, :console_host)
      end)
    end

    test "a second organization, even one created after the click, refuses: 403", %{
      conn: conn,
      run: run,
      name: name
    } do
      admin = authed_user(:admin)
      token = token(admin, run, name)

      Ash.Seed.seed!(Accounts.Organization, %{
        name: "Second",
        slug: "dl-second-#{System.unique_integer([:positive])}",
        status: :active
      })

      conn = conn |> log_in(admin) |> download(token)
      assert response(conn, 403)
      assert error_code(conn) == "console_shares_origin"
      assert events() == []
    end

    test "with a console host, a tenant site's host never serves the file", %{
      conn: conn,
      run: run,
      name: name
    } do
      site =
        Ash.Seed.seed!(Accounts.Organization, %{
          name: "Second",
          slug: "dl-site-#{System.unique_integer([:positive])}",
          status: :active
        })

      KilnCMS.SecondFactorFixtures.with_console_host()
      admin = authed_user(:admin)

      on_site = conn |> org_conn(site) |> log_in(admin) |> download(token(admin, run, name))
      refute on_site.status == 200
      assert events() == []

      # Its console host does.
      on_console =
        build_conn()
        |> KilnCMS.SecondFactorFixtures.console_conn(site)
        |> log_in(admin)
        |> download(token(admin, run, name))

      assert response(on_console, 200)
    end
  end

  defp imported!(stamp, name, destinations) do
    Backups.import_run!(
      %{
        stamp: stamp,
        trigger: "cron",
        status: :succeeded,
        components: [:db],
        started_at: ~U[2026-11-18 03:17:00.000000Z],
        finished_at: ~U[2026-11-18 03:20:00.000000Z],
        artifacts: [%{kind: :db, name: name, bytes: 1, destinations: destinations}]
      },
      actor: Backups.system()
    )
  end
end
