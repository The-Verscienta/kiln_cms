defmodule KilnCMS.Demo.RestoreConnectionTest do
  @moduledoc """
  What the demo reset hands `psql` and `pg_dump` (#2830, #2831, #2844): the
  same connection as an in-app backup (`KilnCMS.Backups.pg_connection/1`),
  and `--lock-wait-timeout` on the golden capture.

  The tools are stubs on `PATH` that log their argv and TLS environment.
  `async: false`: it rewrites `PATH` and the `KilnCMS.Backups` application
  config.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Demo.Restore

  setup do
    tmp = Path.join(System.tmp_dir!(), "kiln_demo_conn_#{System.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    log = Path.join(tmp, "calls.log")
    File.mkdir_p!(bin)

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    saved = Map.new(~w(PATH PGSSLMODE PGSSLROOTCERT), &{&1, System.get_env(&1)})
    System.delete_env("PGSSLMODE")
    System.delete_env("PGSSLROOTCERT")
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)

      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      File.rm_rf!(tmp)
    end)

    # One line per call: the tool, PGSSLMODE, PGSSLROOTCERT, then each
    # argument; pg_dump writes the file it was asked for.
    for tool <- ["pg_dump", "psql", "pg_restore"] do
      stub!(bin, tool, """
      { printf '%s|%s|%s' "#{tool}" "${PGSSLMODE-unset}" "${PGSSLROOTCERT-unset}"; printf '|%s' "$@"; echo; } >> "#{log}"
      for a in "$@"; do
        case "$a" in --file=*) printf 'PGDMP pretend dump' > "${a#--file=}" ;; esac
      done
      """)
    end

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, ssl: [verify: :verify_none], lock_wait_ms: 600_000)
    )

    %{tmp: tmp, bin: bin, log: log}
  end

  test "dump/2 gets the Repo's TLS and --lock-wait-timeout", ctx do
    assert :ok = Restore.dump("ecto://kiln:hunter2@db/kiln_demo", Path.join(ctx.tmp, "g.dump"))

    assert [["pg_dump", "require", "unset" | args], ["pg_restore" | _]] = calls(ctx)
    assert "--lock-wait-timeout=600000" in args
    assert List.last(args) == "postgres://kiln@db/kiln_demo"
  end

  test "run/2 gets the Repo's TLS", ctx do
    work = %{
      dir: ctx.tmp,
      wipe: Path.join(ctx.tmp, "w.sql"),
      restore: Path.join(ctx.tmp, "r.sql")
    }

    put_ssl(verify: :verify_peer, cacertfile: "/etc/kiln/ca.pem")

    assert :ok = Restore.run(work, "postgres://kiln@db/kiln_demo")

    assert [["psql", "verify-full", "/etc/kiln/ca.pem" | args]] = calls(ctx)
    assert "--dbname=postgres://kiln@db/kiln_demo" in args
  end

  test "a key=value string with a password is refused before either tool runs", ctx do
    url = "host=db password=hunter2 dbname=kiln_demo"
    work = %{dir: ctx.tmp, wipe: "w.sql", restore: "r.sql"}

    assert {:error, {:dump_failed, dump_error}} = Restore.dump(url, Path.join(ctx.tmp, "g.dump"))
    assert {:error, {:restore_failed, run_error}} = Restore.run(work, url)

    for error <- [dump_error, run_error] do
      assert error =~ "is not a postgres:// URL"
      refute error =~ "hunter2"
    end

    refute File.exists?(ctx.log)
  end

  test "a URL carrying sslpassword is refused before either tool runs (#3049)", ctx do
    url = "postgres://kiln@db/kiln_demo?sslpassword=hunter2"
    work = %{dir: ctx.tmp, wipe: "w.sql", restore: "r.sql"}

    assert {:error, {:dump_failed, dump_error}} = Restore.dump(url, Path.join(ctx.tmp, "g.dump"))
    assert {:error, {:restore_failed, run_error}} = Restore.run(work, url)

    for error <- [dump_error, run_error] do
      assert error =~ "carries sslpassword"
      refute error =~ "hunter2"
    end

    refute File.exists?(ctx.log)
  end

  test "a golden capture stuck behind a lock says so", ctx do
    stub!(ctx.bin, "pg_dump", """
    echo "pg_dump: error: query failed: ERROR:  canceling statement due to statement timeout" >&2
    echo "pg_dump: detail: Query was: LOCK TABLE public.pages IN ACCESS SHARE MODE" >&2
    exit 1
    """)

    assert {:error, {:dump_failed, message}} =
             Restore.dump("postgres://kiln@db/kiln_demo", Path.join(ctx.tmp, "g.dump"))

    assert message =~
             "pg_dump waited longer than BACKUP_LOCK_WAIT_SECONDS (600 s) for a table lock"

    assert message =~ "LOCK TABLE public.pages"
  end

  test "a TLS failure keeps the word libpq used", ctx do
    stub!(ctx.bin, "psql", """
    echo "psql: error: connection to server failed: SSL was required" >&2
    exit 2
    """)

    work = %{dir: ctx.tmp, wipe: "w.sql", restore: "r.sql"}

    assert {:error, {:restore_failed, message}} =
             Restore.run(work, "postgres://kiln@db/kiln_demo")

    assert message =~ "SSL was required"
  end

  defp put_ssl(ssl) do
    config = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(config, :ssl, ssl))
  end

  defp calls(ctx) do
    ctx.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "|"))
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end
end
