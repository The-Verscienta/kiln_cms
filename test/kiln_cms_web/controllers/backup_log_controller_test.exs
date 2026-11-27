defmodule KilnCMSWeb.BackupLogControllerTest do
  @moduledoc """
  `GET /editor/backups/runs/:id/log.txt` (part of #2230): a platform admin's
  download of one run's log, redacted again and sanitized; refused for anyone
  else and while the console shares an origin, with nothing charged before
  those checks; rate-limited on the `:export` bucket.

  `async: false`: it changes the rate limits, `PGPASSWORD`, the
  `KilnCMS.Backups` env and `:console_host`, all VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.RateLimitHelpers
  alias KilnCMS.Security

  @password "password123456"
  @stamp "20261127-031700"

  setup do
    RateLimitHelpers.restore_limits_on_exit()
    pgpassword = System.get_env("PGPASSWORD")
    backups = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    console = Application.get_env(:kiln_cms, :console_host)
    System.delete_env("PGPASSWORD")

    on_exit(fn ->
      if pgpassword,
        do: System.put_env("PGPASSWORD", pgpassword),
        else: System.delete_env("PGPASSWORD")

      Application.put_env(:kiln_cms, KilnCMS.Backups, backups)

      if console,
        do: Application.put_env(:kiln_cms, :console_host, console),
        else: Application.delete_env(:kiln_cms, :console_host)
    end)

    %{run: run!(:fail, default_messages(), @stamp)}
  end

  defp unique_stamp do
    n = System.unique_integer([:positive]) |> rem(1_000_000) |> Integer.to_string()
    "20261126-" <> String.pad_leading(n, 6, "0")
  end

  defp run!(outcome, messages, stamp \\ unique_stamp()) do
    run = Backups.start_run!(%{stamp: stamp, trigger: "manual"}, actor: Backups.system())
    attrs = %{log: Enum.map(messages, &line/1)}

    case outcome do
      :fail -> Backups.fail_run!(run, Map.put(attrs, :error, "it broke"), actor: Backups.system())
      :running -> Backups.record_run_progress!(run, attrs, actor: Backups.system())
    end
  end

  defp line({level, step, message}),
    do: %{at: DateTime.utc_now(), level: level, step: step, message: message}

  defp default_messages do
    [
      {:info, "dump", "pg_dump started"},
      {:warn, "offsite", "retrying"},
      {:error, "offsite", "rclone failed"}
    ]
  end

  defp authed_user(role, attrs \\ %{}) do
    email = "blc-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  defp fetch(conn, id), do: get(conn, "/editor/backups/runs/#{id}/log.txt")

  defp error_code(conn) do
    [_, code] = Regex.run(~r/error: (\S+)\n\z/, conn.resp_body)
    code
  end

  defp spent(user), do: RateLimitHelpers.spent(:export, "actor:" <> user.id)

  defp second_org! do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Second",
      slug: "blc-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  describe "a platform admin's download" do
    test "is the log as a text attachment, every level, never cached", %{conn: conn, run: run} do
      conn = conn |> log_in(authed_user(:admin)) |> fetch(run.id)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="kiln-backup-log-#{@stamp}.txt")]

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      body = conn.resp_body
      assert body =~ "# Kiln backup log\n"
      assert body =~ "# Backup: #{@stamp} (manual, failed)"
      assert body =~ "# Error: it broke"
      assert body =~ "INFO  dump pg_dump started"
      assert body =~ "WARN  offsite retrying"
      assert body =~ "ERROR offsite rclone failed"
    end

    test "keeps the truncated marker", %{conn: conn} do
      messages = for i <- 1..250, do: {:info, "archive", "part #{i}"}
      run = run!(:fail, messages)

      body = conn |> log_in(authed_user(:admin)) |> fetch(run.id) |> response(200)
      assert body =~ ~r/WARN  truncated \d+ log entries were dropped/
    end

    test "works while the run is running, and records no instance event", %{conn: conn} do
      admin = authed_user(:admin)
      before = Security.list_instance_events!(%{}, actor: admin)
      run = run!(:running, [{:info, "dump", "so far"}])

      body = conn |> log_in(admin) |> fetch(run.id) |> response(200)
      assert body =~ "(manual, running)"
      assert body =~ "# Finished: -"
      assert body =~ "INFO  dump so far"

      assert Security.list_instance_events!(%{}, actor: admin) == before
    end

    test "is redacted again: pattern secrets, a PGPASSWORD known later, the DATABASE_URL password",
         %{conn: conn} do
      run =
        run!(:fail, [
          {:error, "dump", "password=Hunter2Hunter2"},
          {:error, "dump", "postgres://u:Pw12345678@db/x"},
          {:error, "offsite", ":s3,access_key_id=AKIAEXAMPLE,secret_access_key=SuperSecret123:b"},
          {:error, "dump", "literal LaterKnown555 here"},
          {:error, "dump", "literal DbUrlPw0rd77 here"}
        ])

      System.put_env("PGPASSWORD", "LaterKnown555")

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(
          Application.get_env(:kiln_cms, KilnCMS.Backups, []),
          :database_url,
          "postgres://kiln:DbUrlPw0rd77@db.internal/kiln_prod"
        )
      )

      body = conn |> log_in(authed_user(:admin)) |> fetch(run.id) |> response(200)

      for secret <-
            ~w(Hunter2Hunter2 Pw12345678 SuperSecret123 AKIAEXAMPLE LaterKnown555 DbUrlPw0rd77) do
        refute body =~ secret
      end

      assert body =~ "literal *** here"
    end

    test "replaces ESC, C1 and bidi characters in the body", %{conn: conn} do
      run = run!(:fail, [{:error, "dump", "\e[2Jcleared\u009B \u202Egnp.exe"}])
      body = conn |> log_in(authed_user(:admin)) |> fetch(run.id) |> response(200)

      refute body =~ "\e"
      refute body =~ "\u009B"
      refute body =~ "\u202E"
      assert body =~ "\u{FFFD}[2Jcleared\u{FFFD} \u{FFFD}gnp.exe"
    end
  end

  describe "the run" do
    test "an id that isn't a UUID, and an unknown one, are the same 404", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))

      for id <- ["not-a-uuid", Ash.UUID.generate()] do
        refused = fetch(conn, id)
        assert refused.status == 404
        assert error_code(refused) == "not_found"
      end
    end
  end

  describe "who" do
    test "anyone but a platform admin is 403, and charges nothing", %{conn: conn, run: run} do
      org_admin = authed_user(:viewer)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: Accounts.default_org_id(),
        user_id: org_admin.id,
        role: :admin
      })

      expired =
        authed_user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {1, _} =
        KilnCMS.Repo.update_all(
          from(u in "users", where: u.id == type(^expired.id, :binary_id)),
          set: [granted_role_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      for user <- [authed_user(:editor), authed_user(:viewer), org_admin, expired] do
        refused = build_conn() |> log_in(user) |> fetch(run.id)
        assert refused.status == 403
        assert error_code(refused) == "admin_required"
        refute refused.resp_body =~ "rclone failed"
        assert spent(user) == 0
      end

      anonymous = fetch(conn, run.id)
      assert anonymous.status == 403
      assert error_code(anonymous) == "admin_required"
    end

    test "an admin demoted since signing in is 403", %{conn: conn, run: run} do
      admin = authed_user(:admin)

      {1, _} =
        KilnCMS.Repo.update_all(
          from(u in "users", where: u.id == type(^admin.id, :binary_id)),
          set: [role: "editor"]
        )

      assert conn |> log_in(admin) |> fetch(run.id) |> response(403)
    end
  end

  describe "while the console shares an origin" do
    setup do
      Application.delete_env(:kiln_cms, :console_host)
      :ok
    end

    test "a second organization refuses: 403, nothing sent, nothing charged", %{
      conn: conn,
      run: run
    } do
      admin = authed_user(:admin)
      conn = log_in(conn, admin)
      assert conn |> fetch(run.id) |> response(200)
      assert spent(admin) == 1

      second_org!()

      refused = fetch(conn, run.id)
      assert refused.status == 403
      assert error_code(refused) == "console_shares_origin"
      refute refused.resp_body =~ "rclone failed"
      assert spent(admin) == 1

      # An unknown id answers the same: the origin decides before the read.
      assert conn |> fetch(Ash.UUID.generate()) |> error_code() == "console_shares_origin"
    end

    test "a console host of its own allows it again", %{run: run} do
      site = second_org!()
      KilnCMS.SecondFactorFixtures.with_console_host()

      assert build_conn()
             |> KilnCMS.SecondFactorFixtures.console_conn(site)
             |> log_in(authed_user(:admin))
             |> fetch(run.id)
             |> response(200)
    end
  end

  describe "the rate limit" do
    test "the :export bucket answers 429 once spent, per admin", %{conn: conn, run: run} do
      RateLimitHelpers.put_limit(:export, 2)
      admin = authed_user(:admin)
      other = authed_user(:admin)
      conn = log_in(conn, admin)

      for _ <- 1..2, do: assert(conn |> fetch(run.id) |> response(200))

      limited = fetch(conn, run.id)
      assert limited.status == 429
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) >= 1

      # An unknown id is charged too, so guessing ids costs.
      assert conn |> fetch(Ash.UUID.generate()) |> response(429)

      assert build_conn() |> log_in(other) |> fetch(run.id) |> response(200)
    end
  end
end
