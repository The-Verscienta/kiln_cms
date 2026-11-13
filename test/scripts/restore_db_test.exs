defmodule KilnCMS.Scripts.RestoreDbTest do
  @moduledoc """
  `scripts/restore.sh db` and `drill` and the connection they hand libpq
  (#2719, #2726): an `ecto://` `RESTORE_DATABASE_URL` reaches `pg_restore` and
  `psql` as a `postgres://` URI, and the password reaches them through
  `PGPASSWORD` only, never argv (world-readable through `/proc/<pid>/cmdline`
  and `ps`).

  `pg_restore`, `psql` and `createdb` are stubs on `PATH` that log their argv
  and whether `PGPASSWORD` reached them. Skipped where bash is missing.

  `async: false`: it spawns processes and rewrites `PATH` for the child only,
  but shares the tmp namespace with the other script tests.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/restore.sh", __DIR__)

  unless System.find_executable("bash"), do: @moduletag(skip: "needs bash on PATH")

  setup do
    tmp = Path.join(System.tmp_dir!(), "kiln_restore_db_#{System.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    log = Path.join(tmp, "calls.log")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # One line per call: the tool, PGPASSWORD (or `-`), then each argument.
    for tool <- ["pg_restore", "psql", "createdb"] do
      stub!(bin, tool, """
      #!/bin/sh
      { printf '%s|%s' "#{tool}" "${PGPASSWORD--}"; printf '|%s' "$@"; echo; } >> "#{log}"
      #{if tool == "psql", do: "echo 3", else: ""}
      """)
    end

    dump = Path.join(tmp, "kiln-db-20261112-000000.dump")
    File.write!(dump, "PGDMP pretend dump")

    %{tmp: tmp, bin: bin, log: log, dump: dump}
  end

  test "db: pg_restore gets a postgres:// URL and the password through PGPASSWORD", ctx do
    assert {_out, 0} = restore(ctx, ["db", ctx.dump], "ecto://kiln:hunter2@db:5432/kiln_restore")

    assert [
             ["createdb", "-", "kiln_restore"],
             ["pg_restore", "hunter2" | args]
           ] = calls(ctx)

    assert "--dbname=postgres://kiln@db:5432/kiln_restore" in args
    assert List.last(args) == ctx.dump
    refute Enum.any?(args, &(&1 =~ "hunter2"))
  end

  test "drill: pg_restore and every psql check get the same, without the password in argv",
       ctx do
    url = "ecto://kiln:p%40ss%3Aword@db/kiln_drill?sslmode=require&password=hunter2"

    assert {out, 0} = restore(ctx, ["drill", ctx.dump], url)
    assert out =~ "Drill restore looks sane"

    assert [["createdb", "-", "kiln_drill"], ["pg_restore", "hunter2" | restore_args] | checks] =
             calls(ctx)

    assert "--dbname=postgres://kiln@db/kiln_drill?sslmode=require" in restore_args
    assert length(checks) == 5

    for check <- checks do
      assert ["psql", "hunter2" | args] = check
      assert List.last(args) == "postgres://kiln@db/kiln_drill?sslmode=require"
    end

    for [_tool, _password | args] <- calls(ctx), arg <- args do
      refute arg =~ "hunter2"
      refute arg =~ "p%40ss"
    end

    # The closing hint shows the URL to scrub, without either password.
    assert out =~ ~s(STAGING_DATABASE_URL="postgres://kiln@db/kiln_drill?sslmode=require")
    refute out =~ "hunter2"
    refute out =~ "p%40ss"
    refute out =~ "p@ss"
  end

  test "without a password in the URL, the operator's own PGPASSWORD still applies", ctx do
    assert {_out, 0} =
             restore(ctx, ["db", ctx.dump], "ecto://kiln@db/kiln_restore", [
               {"PGPASSWORD", "from-env"}
             ])

    assert [_createdb, ["pg_restore", "from-env" | args]] = calls(ctx)
    assert "--dbname=postgres://kiln@db/kiln_restore" in args
  end

  defp calls(ctx) do
    ctx.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "|"))
  end

  defp restore(ctx, args, url, extra \\ []) do
    env =
      [
        {"RESTORE_DATABASE_URL", url},
        {"RESTORE_CONFIRM", "yes"},
        {"PGPASSWORD", nil},
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
      ]

    env = Enum.reduce(extra, env, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end)

    System.cmd("bash", [@script | args], env: env, stderr_to_stdout: true)
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
