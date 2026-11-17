defmodule KilnCMS.Backups.PgConnectionTest do
  @moduledoc """
  What the in-app backup hands `pg_dump` (#2830, #2831, #2844): the TLS
  settings that follow the app's Repo, a refused `key=value` string, the
  `--lock-wait-timeout` flag, and the errors each of those leaves on the run.

  `pg_dump` is a stub on `PATH` that logs its argv and its TLS environment and
  fails, so these run without the client tools; the one `:pg_tools` case
  really holds a lock against a scratch database of its own.

  `async: false`: it rewrites `PATH`, the process environment and the
  `KilnCMS.Backups` application config.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bkconn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil, keep_days: 14)
    )

    saved = Map.new(~w(PGSSLMODE PGSSLROOTCERT PATH), &{&1, System.get_env(&1)})
    System.delete_env("PGSSLMODE")
    System.delete_env("PGSSLROOTCERT")

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)

      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "pg_connection/1" do
    test "follows the Repo's TLS: require for verify_none" do
      set_config(ssl: [verify: :verify_none])

      assert Backups.pg_connection("ecto://kiln:hunter2@db/kiln") ==
               {:ok,
                {"postgres://kiln@db/kiln", [{"PGPASSWORD", "hunter2"}, {"PGSSLMODE", "require"}]}}
    end

    test "verify-full against the CA file the Repo verifies with" do
      set_config(ssl: [verify: :verify_peer, cacertfile: "/etc/kiln/ca.pem", depth: 3])

      assert Backups.pg_connection("postgres://kiln@db/kiln") ==
               {:ok,
                {"postgres://kiln@db/kiln",
                 [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", "/etc/kiln/ca.pem"}]}}
    end

    test "nothing when the URL or the operator already decides" do
      set_config(ssl: [verify: :verify_none])

      assert {:ok, {_url, []}} = Backups.pg_connection("postgres://kiln@db/kiln?sslmode=disable")

      System.put_env("PGSSLMODE", "verify-ca")
      assert {:ok, {_url, []}} = Backups.pg_connection("postgres://kiln@db/kiln")
    end

    test "the test Repo's own TLS (none) adds nothing" do
      assert Backups.pg_ssl() == KilnCMS.Repo.config()[:ssl]

      assert {:ok, {"postgres://kiln@db/kiln", []}} =
               Backups.pg_connection("postgres://kiln@db/kiln")
    end

    test "refuses a key=value string with a password" do
      assert Backups.pg_connection("host=db password=hunter2") == {:error, :refused_conninfo}
    end
  end

  describe "an in-app backup's pg_dump" do
    setup ctx do
      log = Path.join(ctx.dir, "pg_dump")

      fake_bin([
        {"pg_dump",
         """
         printf '%s\\n' "$@" > "#{log}.args"
         printf '%s|%s' "${PGSSLMODE-unset}" "${PGSSLROOTCERT-unset}" > "#{log}.tls"
         echo "pg_dump: error: connection to server failed: SSL was required" >&2
         exit 1
         """},
        {"pg_restore", "exit 0\n"}
      ])

      %{log: log}
    end

    test "gets PGSSLMODE=require when the Repo encrypts without verifying", ctx do
      set_config(ssl: [verify: :verify_none], database_url: "ecto://kiln:hunter2@db/kiln")

      assert {:error, _} = BackupChain.run()
      assert File.read!(ctx.log <> ".tls") == "require|unset"
    end

    test "gets verify-full and the CA file when the Repo verifies the server", ctx do
      set_config(
        ssl: [verify: :verify_peer, cacertfile: "/etc/kiln/ca.pem"],
        database_url: "postgres://kiln@db/kiln"
      )

      assert {:error, _} = BackupChain.run()
      assert File.read!(ctx.log <> ".tls") == "verify-full|/etc/kiln/ca.pem"
    end

    test "gets no TLS of its own with the test Repo, and the operator's PGSSLMODE untouched",
         ctx do
      set_config(database_url: "postgres://kiln@db/kiln")

      assert {:error, _} = BackupChain.run()
      assert File.read!(ctx.log <> ".tls") == "unset|unset"

      System.put_env("PGSSLMODE", "disable")
      set_config(ssl: [verify: :verify_none])
      assert {:error, _} = BackupChain.run()
      assert File.read!(ctx.log <> ".tls") == "disable|unset"
    end

    test "is passed --lock-wait-timeout, 600000 ms unless configured", ctx do
      set_config(database_url: "postgres://kiln@db/kiln")

      assert {:error, _} = BackupChain.run()
      assert "--lock-wait-timeout=600000" in args(ctx)

      set_config(lock_wait_ms: 5000)
      assert {:error, _} = BackupChain.run()
      assert "--lock-wait-timeout=5000" in args(ctx)
    end

    test "a TLS failure keeps the word libpq used: the TLS settings are not redacted", _ctx do
      set_config(ssl: [verify: :verify_none], database_url: "postgres://kiln@db/kiln")

      assert {:error, _} = BackupChain.run()
      assert [%Backups.Run{error: error}] = runs()
      assert error =~ "SSL was required"
    end

    test "a key=value string with a password fails the run at once, saying why", ctx do
      set_config(database_url: "host=db user=kiln password=hunter2 dbname=kiln")

      assert {:error, :refused_conninfo} = BackupChain.run()
      refute File.exists?(ctx.log <> ".args")

      assert [%Backups.Run{status: :failed, error: error}] = runs()
      assert error =~ "is not a postgres:// URL"
      assert error =~ "postgres:///database?host=/socket/dir"
      refute error =~ "hunter2"
    end

    test "a lock-wait timeout is recorded as one, in plain words", _ctx do
      fake_bin([
        {"pg_dump",
         """
         echo "pg_dump: error: query failed: ERROR:  canceling statement due to statement timeout" >&2
         echo "pg_dump: detail: Query was: LOCK TABLE public.pages IN ACCESS SHARE MODE" >&2
         exit 1
         """}
      ])

      set_config(database_url: "postgres://kiln@db/kiln", lock_wait_ms: 30_000)

      assert {:error, _} = BackupChain.run()
      assert [%Backups.Run{error: error}] = runs()

      assert error =~
               "pg_dump waited longer than BACKUP_LOCK_WAIT_SECONDS (30 s) for a table lock"

      assert error =~ "LOCK TABLE public.pages"
    end
  end

  describe "a real lock (#2844)" do
    @describetag :pg_tools

    setup ctx do
      # Random, not `System.unique_integer/1`: that counter is per-VM, and the
      # partitioned CI shards share one Postgres server.
      db = "kiln_lock_it_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      admin!(&Postgrex.query!(&1, "CREATE DATABASE \"#{db}\"", []))

      on_exit(fn ->
        admin!(&Postgrex.query!(&1, "DROP DATABASE IF EXISTS \"#{db}\" WITH (FORCE)", []))
      end)

      {:ok, conn} = Postgrex.start_link(conn_opts(db))
      Postgrex.query!(conn, "CREATE TABLE held (id int)", [])
      Postgrex.query!(conn, "INSERT INTO held VALUES (1)", [])

      Map.merge(ctx, %{db: db, conn: conn})
    end

    test "pg_dump gives up after the lock wait and the run says why", ctx do
      parent = self()

      holder =
        spawn(fn ->
          Postgrex.transaction(
            ctx.conn,
            fn conn ->
              Postgrex.query!(conn, "LOCK TABLE held IN ACCESS EXCLUSIVE MODE", [])
              send(parent, :locked)

              receive do
                :release -> :ok
              end
            end,
            timeout: :infinity
          )
        end)

      assert_receive :locked, 5000
      on_exit(fn -> send(holder, :release) end)

      set_config(database_url: url(ctx.db), lock_wait_ms: 500)

      assert {:error, {:exit_status, "pg_dump", _status, _output}} = BackupChain.run()

      assert [%Backups.Run{status: :failed, error: error}] = runs()

      assert error =~
               "pg_dump waited longer than BACKUP_LOCK_WAIT_SECONDS (500 ms) for a table lock"

      assert error =~ "LOCK TABLE public.held"
      send(holder, :release)
    end
  end

  defp runs, do: Backups.list_runs!(actor: Backups.system())

  defp args(ctx), do: ctx.log |> Kernel.<>(".args") |> File.read!() |> String.split("\n")

  defp set_config(overrides) do
    current = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(current, overrides))
  end

  # A directory of fake executables ahead of the real ones on PATH; restored
  # by the module's setup.
  defp fake_bin(scripts) do
    bin = Path.join(System.tmp_dir!(), "kiln_bkconnbin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(bin) end)

    for {name, body} <- scripts do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
    end

    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
  end

  defp admin!(fun) do
    {:ok, conn} = Postgrex.start_link(conn_opts("postgres"))

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  # Not `Repo.config/0` as it is: that carries the SQL sandbox pool.
  defp conn_opts(database) do
    config = KilnCMS.Repo.config()

    [
      hostname: config[:hostname] || "localhost",
      port: config[:port] || 5432,
      username: config[:username],
      password: config[:password],
      database: database
    ]
  end

  defp url(database) do
    opts = conn_opts(database)

    userinfo =
      case {opts[:username], opts[:password]} do
        {nil, _} -> ""
        {user, nil} -> "#{encode(user)}@"
        {user, password} -> "#{encode(user)}:#{encode(password)}@"
      end

    "postgres://#{userinfo}#{opts[:hostname]}:#{opts[:port]}/#{database}"
  end

  defp encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
