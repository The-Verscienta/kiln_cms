defmodule KilnCMS.Scripts.StagingScriptTest do
  @moduledoc """
  `scripts/staging.sh up` and the connections it hands libpq (#2719, #2726):
  `pg_dump` reads `PROD_DATABASE_URL` and `psql` writes `STAGING_DATABASE_URL`,
  each as a `postgres://` URI with no password in argv, and each with its own
  URL's password as `PGPASSWORD`. The two may differ, and neither may reach the
  other process.

  `createdb`, `pg_dump`, `psql` and `KILN_BIN` are stubs on `PATH` that log
  their argv and whether `PGPASSWORD` reached them. Skipped where bash is
  missing.

  `async: false`: it spawns processes and rewrites `PATH` for the child only,
  but shares the tmp namespace with the other script tests.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/staging.sh", __DIR__)

  unless System.find_executable("bash"), do: @moduletag(skip: "needs bash on PATH")

  setup do
    tmp = Path.join(System.tmp_dir!(), "kiln_staging_#{System.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    log = Path.join(tmp, "calls.log")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # One line per call: the tool, PGPASSWORD (or `-`), then each argument.
    for tool <- ["createdb", "pg_dump", "psql", "kiln"] do
      extra =
        case tool do
          "pg_dump" -> "echo 'select 1;'"
          "psql" -> "cat > /dev/null"
          _ -> ""
        end

      stub!(bin, tool, """
      #!/bin/sh
      # One write per line: `pg_dump | psql` runs both stubs at once, and
      # separate printfs to the shared log interleave. A single append of a
      # short line is atomic.
      line="$(printf '%s|%s' "#{tool}" "${PGPASSWORD--}"; printf '|%s' "$@")"
      printf '%s\n' "$line" >> "#{log}"
      #{extra}
      """)
    end

    %{tmp: tmp, bin: bin, log: log}
  end

  test "pg_dump and psql each get their own URL's password, and only through PGPASSWORD", ctx do
    assert {_out, 0} =
             up(ctx,
               prod: "ecto://prod:prod%40pw@prod-db:5432/kiln_prod?sslmode=require",
               staging: "postgres://stage:stage-pw@stage-db/kiln_staging"
             )

    calls = calls(ctx)

    assert ["pg_dump", "prod@pw" | dump_args] = Enum.find(calls, &(hd(&1) == "pg_dump"))
    assert List.last(dump_args) == "postgres://prod@prod-db:5432/kiln_prod?sslmode=require"

    assert ["psql", "stage-pw" | psql_args] = Enum.find(calls, &(hd(&1) == "psql"))
    assert List.last(psql_args) == "postgres://stage@stage-db/kiln_staging"

    for [_tool, _password | args] <- calls, arg <- args do
      refute arg =~ "prod%40pw"
      refute arg =~ "prod@pw"
      refute arg =~ "stage-pw"
    end
  end

  test "the closing hint prints the staging URL without its password", ctx do
    assert {out, 0} =
             up(ctx,
               prod: "ecto://prod:prod-pw@prod-db/kiln_prod",
               staging: "ecto://stage:stage%40pw@stage-db/kiln_staging?sslmode=require"
             )

    assert out =~ "DATABASE_URL=postgres://stage@stage-db/kiln_staging?sslmode=require"
    refute out =~ "stage%40pw"
    refute out =~ "stage@pw"
    refute out =~ "prod-pw"
  end

  test "a URL without a password leaves that side to the operator's own PGPASSWORD", ctx do
    assert {_out, 0} =
             up(ctx,
               prod: "ecto://prod:prod-pw@prod-db/kiln_prod",
               staging: "ecto://stage@stage-db/kiln_staging",
               env: [{"PGPASSWORD", "from-env"}]
             )

    calls = calls(ctx)
    assert ["pg_dump", "prod-pw" | _] = Enum.find(calls, &(hd(&1) == "pg_dump"))

    assert ["psql", "from-env" | psql_args] = Enum.find(calls, &(hd(&1) == "psql"))
    assert List.last(psql_args) == "postgres://stage@stage-db/kiln_staging"
  end

  test "a failed dump fails the run", ctx do
    stub!(ctx.bin, "pg_dump", "#!/bin/sh\nexit 1\n")

    assert {_out, status} =
             up(ctx,
               prod: "ecto://prod:prod-pw@prod-db/kiln_prod",
               staging: "ecto://stage:stage-pw@stage-db/kiln_staging"
             )

    assert status != 0
    refute Enum.any?(calls(ctx), &(hd(&1) == "kiln"))
  end

  defp calls(ctx) do
    ctx.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "|"))
  end

  defp up(ctx, opts) do
    env =
      [
        {"PROD_DATABASE_URL", opts[:prod]},
        {"STAGING_DATABASE_URL", opts[:staging]},
        {"KILN_BIN", Path.join(ctx.bin, "kiln")},
        {"PGPASSWORD", nil},
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
      ]

    env =
      Enum.reduce(opts[:env] || [], env, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end)

    System.cmd("bash", [@script, "up"], env: env, stderr_to_stdout: true)
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
