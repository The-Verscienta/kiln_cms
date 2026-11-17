defmodule KilnCMS.Scripts.RestoreDbTest do
  @moduledoc """
  `scripts/restore.sh db` and `drill` and the connection they hand libpq
  (#2719, #2726, #2831, #2833): an `ecto://` `RESTORE_DATABASE_URL` reaches `pg_restore` and
  `psql` as a `postgres://` URI, and the password reaches them through
  `PGPASSWORD` only, never argv (world-readable through `/proc/<pid>/cmdline`
  and `ps`).

  `pg_restore`, `psql` and `createdb` are stubs on `PATH` that log their argv
  and whether `PGPASSWORD` reached them. Skipped where bash is missing.

  Both commands verify the dump against its `kiln-db-<stamp>.sha256` sidecar
  before they touch a database (#2877): a mismatch refuses the restore with no
  call logged, and a dump with no sidecar warns, or is refused under
  `RESTORE_REQUIRE_CHECKSUM=1`.

  `async: false`: it spawns processes and rewrites `PATH` for the child only,
  but shares the tmp namespace with the other script tests.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Backups.Checksum
  alias KilnCMS.Test.ShellTools

  # CI's `backup_scripts_portability` job runs this file under bash 3.2 and
  # under bsdtar (`--only shell_portability`).
  @moduletag :shell_portability

  @script Path.expand("../../scripts/restore.sh", __DIR__)
  @no_checksum "WARNING: no checksum found for this database dump"

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

  test "a key=value string with a password is refused before any tool runs (#2831)", ctx do
    for command <- ["db", "drill"] do
      assert {out, status} =
               restore(ctx, [command, ctx.dump], "host=db password=hunter2 dbname=kiln_drill")

      assert status != 0, command
      assert out =~ "RESTORE_DATABASE_URL is not a postgres:// URL", command
      refute out =~ "hunter2", command
      refute File.exists?(ctx.log), command
    end
  end

  test "libpq gets Ecto's ssl=false as sslmode=disable; the printed hint keeps the URL as written (#2833)",
       ctx do
    url = "ecto://kiln:hunter2@db/kiln_drill?ssl=false&pool_size=5"

    assert {out, 0} = restore(ctx, ["drill", ctx.dump], url)

    assert [_createdb, ["pg_restore", "hunter2" | restore_args] | checks] = calls(ctx)
    assert "--dbname=postgres://kiln@db/kiln_drill?sslmode=disable" in restore_args

    for ["psql", "hunter2" | args] <- checks do
      assert List.last(args) == "postgres://kiln@db/kiln_drill?sslmode=disable"
    end

    # The hint is an app's DATABASE_URL, which Ecto reads as written.
    assert out =~ ~s(STAGING_DATABASE_URL="postgres://kiln@db/kiln_drill?ssl=false&pool_size=5")
    refute out =~ "hunter2"
  end

  test "the script sets no TLS of its own (#2830)", ctx do
    stub!(ctx.bin, "pg_restore", """
    #!/bin/sh
    printf '%s|%s\\n' "${PGSSLMODE-unset}" "${PGSSLROOTCERT-unset}" >> "#{ctx.log}"
    """)

    assert {_out, 0} =
             restore(ctx, ["db", ctx.dump], "postgres://kiln@db/kiln_restore", [
               {"DATABASE_SSL", "true"},
               {"DATABASE_SSL_CACERTFILE", "/etc/ca.pem"}
             ])

    assert File.read!(ctx.log) =~ "unset|unset\n"
  end

  describe "the dump's checksum sidecar (#2877)" do
    if !(System.find_executable("sha256sum") || System.find_executable("shasum")),
      do: @describetag(skip: "needs sha256sum or shasum on PATH")

    test "a matching sidecar is verified, then the dump is restored", ctx do
      sidecar!(ctx)

      for command <- ["db", "drill"] do
        File.rm(ctx.log)
        assert {out, 0} = restore(ctx, [command, ctx.dump], drill_url()), command
        assert out =~ "==> Verifying checksum from kiln-db-20261112-000000.sha256", command
        assert out =~ "kiln-db-20261112-000000.dump: OK", command
        refute out =~ "WARNING", command
        assert [["createdb" | _], ["pg_restore" | _] | _] = calls(ctx), command
      end
    end

    test "a mismatch refuses the restore before any tool runs", ctx do
      sidecar!(ctx)
      File.write!(ctx.dump, "PGDMP pretend dumq")

      for command <- ["db", "drill"] do
        assert {out, status} = restore(ctx, [command, ctx.dump], drill_url())
        assert status != 0, command
        assert out =~ "checksum verification FAILED for kiln-db-20261112-000000.dump", command
        assert out =~ "nothing was restored", command
        refute File.exists?(ctx.log), command
      end
    end

    test "without RESTORE_CONFIRM, a mismatch is refused before the prompt", ctx do
      sidecar!(ctx)
      File.write!(ctx.dump, "PGDMP pretend dumq")

      assert {out, status} =
               restore(ctx, ["db", ctx.dump], drill_url(), [{"RESTORE_CONFIRM", nil}])

      assert status != 0
      assert out =~ "checksum verification FAILED"
      refute out =~ "Type the database name"
      refute File.exists?(ctx.log)
    end

    test "no sidecar warns and restores", ctx do
      for command <- ["db", "drill"] do
        File.rm(ctx.log)
        assert {out, 0} = restore(ctx, [command, ctx.dump], drill_url()), command
        assert out =~ @no_checksum, command
        assert out =~ "Expected kiln-db-20261112-000000.sha256 next to the dump.", command
        assert [["createdb" | _], ["pg_restore" | _] | _] = calls(ctx), command
      end
    end

    test "no sidecar is refused under RESTORE_REQUIRE_CHECKSUM=1", ctx do
      for command <- ["db", "drill"] do
        assert {out, status} =
                 restore(ctx, [command, ctx.dump], drill_url(), [
                   {"RESTORE_REQUIRE_CHECKSUM", "1"}
                 ])

        assert status != 0, command
        assert out =~ @no_checksum, command
        assert out =~ "RESTORE_REQUIRE_CHECKSUM=1 and no checksum was found", command
        refute File.exists?(ctx.log), command
      end
    end

    test "a sidecar that lists another file, or more than the dump, is refused", ctx do
      hex = sha256(ctx.dump)
      sidecar = sidecar_path(ctx)

      for entries <- [
            [{"kiln-db-20261111-000000.dump", hex}],
            [{"kiln-db-20261112-000000.dump", hex}, {"kiln-media-20261112-000000.tar.gz", hex}]
          ] do
        File.rm(sidecar)
        :ok = Checksum.write_sidecar(sidecar, entries)

        for command <- ["db", "drill"] do
          assert {out, status} = restore(ctx, [command, ctx.dump], drill_url())
          assert status != 0, command

          assert out =~
                   "kiln-db-20261112-000000.sha256 does not list exactly kiln-db-20261112-000000.dump",
                 command

          refute File.exists?(ctx.log), command
        end
      end
    end

    test "a malformed sidecar is refused", ctx do
      for body <- ["", "deadbeef  kiln-db-20261112-000000.dump\n", "not a checksum\n"] do
        File.write!(sidecar_path(ctx), body)

        for command <- ["db", "drill"] do
          assert {out, status} = restore(ctx, [command, ctx.dump], drill_url())
          assert status != 0, command
          assert out =~ "has a missing or malformed checksum line", command
          refute File.exists?(ctx.log), command
        end
      end
    end

    test "a dump not named kiln-db-<stamp>.dump warns, or is refused under " <>
           "RESTORE_REQUIRE_CHECKSUM=1",
         ctx do
      other = Path.join(ctx.tmp, "backup.dump")
      File.cp!(ctx.dump, other)

      assert {out, 0} = restore(ctx, ["db", other], drill_url())
      assert out =~ @no_checksum
      assert out =~ "Expected a kiln-db-<stamp>.sha256 sidecar next to the dump."

      File.rm!(ctx.log)

      assert {out, status} =
               restore(ctx, ["db", other], drill_url(), [{"RESTORE_REQUIRE_CHECKSUM", "1"}])

      assert status != 0
      assert out =~ "RESTORE_REQUIRE_CHECKSUM=1 and no checksum was found"
      refute File.exists?(ctx.log)
    end

    # bash 3.2 is what macOS ships as /bin/bash; CI builds it (KILN_BASH32).
    unless ShellTools.bash32(),
      do: @tag(skip: "needs bash 3.2 (/bin/bash on macOS, or KILN_BASH32)")

    test "under bash 3.2: a match restores, a mismatch is refused", ctx do
      sidecar!(ctx)
      assert {out, 0} = restore(ctx, ["db", ctx.dump], drill_url(), [], ShellTools.bash32())
      assert out =~ "kiln-db-20261112-000000.dump: OK"
      assert [_createdb, ["pg_restore" | _]] = calls(ctx)

      File.rm!(ctx.log)
      File.write!(ctx.dump, "PGDMP pretend dumq")
      assert {out, status} = restore(ctx, ["db", ctx.dump], drill_url(), [], ShellTools.bash32())
      assert status != 0
      assert out =~ "checksum verification FAILED"
      refute File.exists?(ctx.log)
    end
  end

  defp drill_url, do: "postgres://kiln@db/kiln_drill"

  defp sidecar_path(ctx), do: Path.join(ctx.tmp, "kiln-db-20261112-000000.sha256")

  defp sidecar!(ctx) do
    :ok =
      Checksum.write_sidecar(sidecar_path(ctx), [
        {"kiln-db-20261112-000000.dump", sha256(ctx.dump)}
      ])
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp calls(ctx) do
    ctx.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "|"))
  end

  defp restore(ctx, args, url, extra \\ [], bash \\ "bash") do
    env =
      [
        {"RESTORE_DATABASE_URL", url},
        {"RESTORE_CONFIRM", "yes"},
        {"RESTORE_REQUIRE_CHECKSUM", nil},
        {"PGPASSWORD", nil},
        {"PGSSLMODE", nil},
        {"PGSSLROOTCERT", nil},
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
      ]

    env = Enum.reduce(extra, env, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end)

    System.cmd(bash, [@script | args], env: env, stderr_to_stdout: true)
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
