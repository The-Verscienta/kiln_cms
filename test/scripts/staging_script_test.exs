defmodule KilnCMS.Scripts.StagingScriptTest do
  @moduledoc """
  `scripts/staging.sh up` and the connections it hands libpq (#2719, #2726,
  #2831, #2833):
  `pg_dump` reads `PROD_DATABASE_URL` and `psql` writes `STAGING_DATABASE_URL`,
  each as a `postgres://` URI with no password in argv, and each with its own
  URL's password as `PGPASSWORD`. The two may differ, and neither may reach the
  other process.

  `up` and `down` create and drop only a database whose name looks like a
  throwaway clone, and do it on the server `STAGING_DATABASE_URL` names, not
  libpq's default one (#2722).

  `createdb`, `dropdb`, `pg_dump`, `psql` and `KILN_BIN` are stubs on `PATH`
  that log their argv and whether `PGPASSWORD` reached them. Skipped where
  bash is missing.

  `async: false`: it spawns processes and rewrites `PATH` for the child only,
  but shares the tmp namespace with the other script tests.
  """
  use ExUnit.Case, async: false

  # CI's `backup_scripts_portability` job runs this file under bash 3.2 and
  # under bsdtar (`--only shell_portability`).
  @moduletag :shell_portability

  @script Path.expand("../../scripts/staging.sh", __DIR__)

  unless System.find_executable("bash"), do: @moduletag(skip: "needs bash on PATH")

  setup do
    tmp = Path.join(System.tmp_dir!(), "kiln_staging_#{System.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    log = Path.join(tmp, "calls.log")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # One line per call: the tool, PGPASSWORD (or `-`), then each argument.
    for tool <- ["createdb", "dropdb", "pg_dump", "psql", "kiln"] do
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

  # #2721: production's queued jobs carry recipients and payloads; the clone
  # gets the table without its rows.
  test "pg_dump leaves out the rows of oban_jobs", ctx do
    assert {_out, 0} =
             up(ctx,
               prod: "postgres://prod@prod-db/kiln_prod",
               staging: "postgres://stage@stage-db/kiln_staging"
             )

    assert ["pg_dump", _password | dump_args] = Enum.find(calls(ctx), &(hd(&1) == "pg_dump"))
    assert "--exclude-table-data=oban_jobs" in dump_args
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

  test "a key=value string with a password is refused before anything is created (#2831)", ctx do
    for {prod, staging, var} <- [
          {"host=prod password=prod-pw dbname=kiln_prod", "ecto://stage@stage-db/kiln_staging",
           "PROD_DATABASE_URL"},
          {"ecto://prod@prod-db/kiln_prod", "host=stage password=stage-pw dbname=kiln_staging",
           "STAGING_DATABASE_URL"}
        ] do
      assert {out, status} = up(ctx, prod: prod, staging: staging)

      assert status != 0
      assert out =~ "#{var} is not a postgres:// URL"
      refute out =~ "prod-pw"
      refute out =~ "stage-pw"
      refute File.exists?(ctx.log), "a tool ran for #{var}"
    end
  end

  test "a URL carrying sslpassword is refused before anything is created (#3049)", ctx do
    for {prod, staging, var} <- [
          {"ecto://prod@prod-db/kiln_prod?sslpassword=prod-pw",
           "ecto://stage@stage-db/kiln_staging", "PROD_DATABASE_URL"},
          {"ecto://prod@prod-db/kiln_prod",
           "postgres://stage@stage-db/kiln_staging?sslpass%77ord=stage-pw",
           "STAGING_DATABASE_URL"}
        ] do
      assert {out, status} = up(ctx, prod: prod, staging: staging)

      assert status != 0
      assert out =~ "#{var} carries sslpassword"
      refute out =~ "prod-pw"
      refute out =~ "stage-pw"
      refute File.exists?(ctx.log), "a tool ran for #{var}"
    end
  end

  test "libpq gets Ecto's ssl=false as sslmode=disable; the printed DATABASE_URL keeps it as written (#2833)",
       ctx do
    assert {out, 0} =
             up(ctx,
               prod: "ecto://prod:prod-pw@prod-db/kiln_prod?ssl=false&pool_size=5",
               staging: "ecto://stage:stage-pw@stage-db/kiln_staging?ssl=false&pool_size=5"
             )

    calls = calls(ctx)
    assert ["pg_dump", _ | dump_args] = Enum.find(calls, &(hd(&1) == "pg_dump"))
    assert List.last(dump_args) == "postgres://prod@prod-db/kiln_prod?sslmode=disable"
    assert ["psql", _ | psql_args] = Enum.find(calls, &(hd(&1) == "psql"))
    assert List.last(psql_args) == "postgres://stage@stage-db/kiln_staging?sslmode=disable"

    # Printed for a Kiln instance, whose Ecto reads `ssl=false` and
    # `pool_size` itself and libpq's `sslmode` not at all.
    assert out =~ "DATABASE_URL=postgres://stage@stage-db/kiln_staging?ssl=false&pool_size=5"
    refute out =~ "stage-pw"
  end

  # #2977: only the prod config reads DATABASE_URL, so `mix` under any other
  # MIX_ENV migrated the developer's own database instead of the clone.
  describe "KILN_BIN=mix (the default)" do
    # What a prod boot needs, as the operator exports it.
    @prod_boot [
      {"KILN_BIN", nil},
      {"SECRET_KEY_BASE", "fresh-secret-key-base"},
      {"TOKEN_SIGNING_SECRET", "fresh-token-signing-secret"}
    ]

    @urls [
      prod: "postgres://prod@prod-db/kiln_prod",
      staging: "postgres://stage@stage-db/kiln_staging"
    ]

    setup ctx do
      mix_stub!(ctx)
      :ok
    end

    # Logs MIX_ENV and DATABASE_URL with its argv, so a test can see which
    # database each mix run was pointed at, and in which environment. Exits 1
    # for the mix task named `fail` (`run` is the preflight).
    defp mix_stub!(ctx, fail \\ "") do
      stub!(ctx.bin, "mix", """
      #!/bin/sh
      line="$(printf 'mix|%s|%s' "${MIX_ENV--}" "${DATABASE_URL--}"; printf '|%s' "$@")"
      printf '%s\\n' "$line" >> "#{ctx.log}"
      [ "$1" = "#{fail}" ] && exit 1
      exit 0
      """)
    end

    defp mix_calls(ctx), do: Enum.filter(calls(ctx), &(hd(&1) == "mix"))

    test "with MIX_ENV unset, checks the prod config, then migrates and scrubs under MIX_ENV=prod",
         ctx do
      assert {out, 0} = up(ctx, @urls ++ [env: [{"MIX_ENV", nil} | @prod_boot]])

      assert out =~ "running mix with MIX_ENV=prod"
      staging = "postgres://stage@stage-db/kiln_staging"

      assert [
               ["mix", "prod", ^staging, "run", "--no-start", "-e", ":ok"],
               ["mix", "prod", ^staging, "ecto.migrate"],
               ["mix", "prod", ^staging, "kiln.staging.scrub", "--yes"]
             ] = mix_calls(ctx)

      # The preflight runs before anything is created or copied.
      assert ["mix" | _] = hd(calls(ctx))
    end

    test "with MIX_ENV=prod, runs as given", ctx do
      assert {_out, 0} = up(ctx, @urls ++ [env: [{"MIX_ENV", "prod"} | @prod_boot]])

      assert for(["mix", mix_env | _] <- calls(ctx), do: mix_env) == ["prod", "prod", "prod"]
    end

    test "any other MIX_ENV is refused before anything is created or copied", ctx do
      for {command, mix_env} <- [{"up", "dev"}, {"up", "test"}, {"scrub", "dev"}] do
        assert {out, status} =
                 run(ctx, command, @urls ++ [env: [{"MIX_ENV", mix_env} | @prod_boot]])

        assert status != 0, "#{command} ran under MIX_ENV=#{mix_env}"
        assert out =~ "KILN_BIN=mix needs MIX_ENV=prod (or unset), not MIX_ENV=#{mix_env}"
        refute File.exists?(ctx.log), "a tool ran for #{command} under MIX_ENV=#{mix_env}"
      end
    end

    test "a missing SECRET_KEY_BASE or TOKEN_SIGNING_SECRET is refused before anything runs",
         ctx do
      for {command, unset} <- [
            {"up", ["SECRET_KEY_BASE"]},
            {"up", ["TOKEN_SIGNING_SECRET"]},
            {"scrub", ["SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET"]}
          ] do
        env = Enum.reduce(unset, @prod_boot, &List.keystore(&2, &1, 0, {&1, nil}))
        assert {out, status} = run(ctx, command, @urls ++ [env: [{"MIX_ENV", nil} | env]])

        assert status != 0
        assert out =~ "KILN_BIN=mix boots the prod config, which needs: #{Enum.join(unset, " ")}."
        assert out =~ "nothing was created or copied"
        refute File.exists?(ctx.log), "a tool ran for #{command} without #{inspect(unset)}"
      end
    end

    test "a prod config that does not load is refused before anything is created or copied",
         ctx do
      mix_stub!(ctx, "run")

      assert {out, status} = up(ctx, @urls ++ [env: [{"MIX_ENV", nil} | @prod_boot]])

      assert status != 0
      assert out =~ "the prod config does not load under MIX_ENV=prod"
      assert [["mix", "prod", _url, "run" | _]] = calls(ctx)
    end

    test "a failed migrate after the copy says the clone is unscrubbed, and drops it", ctx do
      mix_stub!(ctx, "ecto.migrate")

      assert {out, status} = up(ctx, @urls ++ [env: [{"MIX_ENV", nil} | @prod_boot]])

      assert status != 0
      assert out =~ "migrate failed after production was copied into kiln_staging"
      assert out =~ "kiln_staging holds UNSCRUBBED production data"
      assert out =~ "Dropped kiln_staging"

      assert [
               "dropdb",
               "-",
               "--if-exists",
               "--maintenance-db=postgres://stage@stage-db/kiln_staging?dbname=postgres",
               "--",
               "kiln_staging"
             ] = List.last(calls(ctx))

      refute Enum.any?(mix_calls(ctx), &("kiln.staging.scrub" in &1))
    end

    test "a failed scrub after the copy says so, and says how to drop it when dropdb fails",
         ctx do
      mix_stub!(ctx, "kiln.staging.scrub")
      stub!(ctx.bin, "dropdb", "#!/bin/sh\nexit 1\n")

      assert {out, status} = up(ctx, @urls ++ [env: [{"MIX_ENV", nil} | @prod_boot]])

      assert status != 0
      assert out =~ "the scrub failed after production was copied into kiln_staging"
      assert out =~ "Could not drop kiln_staging"
      assert out =~ "Drop it yourself NOW"

      # The hint names the clone's own server, as dropdb reads it.
      assert out =~
               "dropdb --if-exists --maintenance-db='postgres://stage@stage-db/kiln_staging?dbname=postgres' -- 'kiln_staging'"

      refute out =~ "Staging is ready"
    end

    test "a non-ephemeral staging name is refused before the prod config is checked", ctx do
      urls = Keyword.put(@urls, :staging, "postgres://stage@stage-db/kiln_prod")

      assert {out, status} = up(ctx, urls ++ [env: [{"MIX_ENV", nil} | @prod_boot]])

      assert status != 0

      assert out =~
               "STAGING_DATABASE_URL names kiln_prod, which does not look like a throwaway clone"

      refute File.exists?(ctx.log), "a tool ran"
    end

    test "a failed re-scrub says the clone may hold unscrubbed data, and keeps it", ctx do
      mix_stub!(ctx, "kiln.staging.scrub")

      assert {out, status} = run(ctx, "scrub", @urls ++ [env: [{"MIX_ENV", nil} | @prod_boot]])

      assert status != 0
      assert out =~ "the scrub failed. Treat the clone as holding UNSCRUBBED"
      refute Enum.any?(calls(ctx), &(hd(&1) == "dropdb"))
    end

    test "a release KILN_BIN ignores MIX_ENV and the prod-boot variables", ctx do
      assert {_out, 0} =
               up(ctx, @urls ++ [env: [{"MIX_ENV", "dev"}, {"SECRET_KEY_BASE", nil}]])

      assert Enum.any?(calls(ctx), &(hd(&1) == "kiln"))
      refute Enum.any?(calls(ctx), &(hd(&1) == "mix"))
    end
  end

  # #2722: the database `up` and `down` act on is the one libpq reads from the
  # URL, on the URL's server, and its name must look like a throwaway clone.
  describe "the staging database name and server" do
    @maint "--maintenance-db=postgres://stage@stage-db:6432/kiln_staging?sslmode=require&dbname="

    test "the script's markers are KilnCMS.Staging's" do
      [_, markers] =
        Regex.run(~r/^STAGING_EPHEMERAL_MARKERS="([^"]*)"$/m, File.read!(@script))

      assert String.split(markers) == KilnCMS.Staging.ephemeral_markers()
    end

    test "down drops the database on the URL's server, with the password in PGPASSWORD only",
         ctx do
      assert {out, 0} =
               down(
                 ctx,
                 "ecto://stage:stage%40pw@stage-db:6432/kiln_staging?sslmode=require&pool_size=5"
               )

      assert out =~ "Dropping throwaway database: kiln_staging"

      assert [["dropdb", "stage@pw", "--if-exists", maint, "--", "kiln_staging"]] = calls(ctx)
      assert maint == @maint <> "postgres"
    end

    test "down retries through template1 when the postgres database fails", ctx do
      fail_through!(ctx, "dbname=postgres")

      assert {_out, 0} =
               down(ctx, "postgres://stage:pw@stage-db:6432/kiln_staging?sslmode=require")

      assert [
               ["dropdb", "pw", "--if-exists", first, "--", "kiln_staging"],
               ["dropdb", "pw", "--if-exists", second, "--", "kiln_staging"]
             ] = calls(ctx)

      assert first == @maint <> "postgres"
      assert second == @maint <> "template1"
    end

    test "down fails, naming both attempts' errors, when neither works", ctx do
      fail_through!(ctx, "dbname=")

      assert {out, status} = down(ctx, "postgres://stage@stage-db/kiln_staging")

      assert status != 0
      assert out =~ "could not drop kiln_staging on the server in STAGING_DATABASE_URL"
      assert out =~ "through postgres: dropdb: connection refused"
      assert out =~ "through template1: dropdb: connection refused"
      refute out =~ "done."
    end

    test "down refuses a production-looking name, and drops nothing", ctx do
      assert {out, status} = down(ctx, "postgres://prod@prod-db/kiln_prod")

      assert status != 0

      assert out =~
               "STAGING_DATABASE_URL names kiln_prod, which does not look like a throwaway clone"

      assert out =~ "staging, preview, ephemeral, tmp, scratch"
      assert out =~ "Nothing was dropped"
      refute File.exists?(ctx.log), "dropdb ran"
    end

    test "down refuses a URL whose database it cannot check", ctx do
      for {url, message} <- [
            {"postgres://stage@stage-db/kiln_staging?dbname=kiln_prod",
             "sets dbname in its query"},
            {"postgres://stage@stage-db/kiln_staging?sslmode=require&db%6Eame=kiln_prod",
             "sets dbname in its query"},
            {"postgres://stage@stage-db", "names no database"},
            {"postgres://stage@stage-db/?sslmode=require", "names no database"},
            {"host=stage-db dbname=kiln_staging", "must be a postgres://"},
            {"kiln_staging", "must be a postgres://"}
          ] do
        assert {out, status} = down(ctx, url)

        assert status != 0, url
        assert out =~ "STAGING_DATABASE_URL #{message}", url
        refute File.exists?(ctx.log), "dropdb ran for #{url}"
      end
    end

    test "down refuses a key=value string with a password before anything runs", ctx do
      assert {out, status} = down(ctx, "host=stage-db password=stage-pw dbname=kiln_staging")

      assert status != 0
      assert out =~ "STAGING_DATABASE_URL is not a postgres:// URL"
      refute out =~ "stage-pw"
      refute File.exists?(ctx.log)
    end

    # libpq reads a host in brackets up to the `]`, whatever is inside: a
    # socket directory's `/` there does not start the path.
    test "down reads the database after a bracketed host, as libpq does", ctx do
      for url <- [
            "postgres://[/tmp]/kiln_prod",
            "postgres://stage@[/tmp]:5432/kiln_prod?sslmode=disable",
            "postgres://stage@h1,[/tmp]/kiln_prod",
            "postgres://stage@[/tmp/kiln_staging]/kiln_prod"
          ] do
        assert {out, status} = down(ctx, url)

        assert status != 0, url

        assert out =~
                 "STAGING_DATABASE_URL names kiln_prod, which does not look like a throwaway clone",
               url

        refute File.exists?(ctx.log), "dropdb ran for #{url}"
      end

      assert {_out, 0} = down(ctx, "postgres://stage@[::1]:5432/kiln_staging")
      assert {_out, 0} = down(ctx, "postgres://stage@h1,[/tmp]/kiln_staging?sslmode=disable")

      assert [
               ["dropdb", _, "--if-exists", first, "--", "kiln_staging"],
               ["dropdb", _, "--if-exists", second, "--", "kiln_staging"]
             ] = calls(ctx)

      assert first == "--maintenance-db=postgres://stage@[::1]:5432/kiln_staging?dbname=postgres"

      assert second ==
               "--maintenance-db=postgres://stage@h1,[/tmp]/kiln_staging?sslmode=disable&dbname=postgres"
    end

    test "down refuses a bracketed host libpq cannot read", ctx do
      for url <- [
            "postgres://stage@[/tmp/kiln_staging",
            "postgres://stage@[]/kiln_staging",
            "postgres://stage@[::1]x/kiln_staging",
            "postgres://[/tmp]@stage-db/kiln_staging"
          ] do
        assert {out, status} = down(ctx, url)

        assert status != 0, url
        assert out =~ "STAGING_DATABASE_URL has a host in [ ] that libpq cannot read", url
        assert out =~ "Nothing was dropped", url
        refute File.exists?(ctx.log), "dropdb ran for #{url}"
      end
    end

    # libpq takes `kiln_prod#staging` as the name; Ecto's URI.parse takes
    # `kiln_prod` and drops `#staging` as a fragment.
    test "down refuses a # after the host", ctx do
      for url <- [
            "postgres://stage@stage-db/kiln_prod#staging",
            "postgres://stage@stage-db/kiln_staging?application_name=a#b",
            "postgres://stage@[/tmp]/kiln_prod#staging"
          ] do
        assert {out, status} = down(ctx, url)

        assert status != 0, url
        assert out =~ "STAGING_DATABASE_URL has a # after its host", url
        refute File.exists?(ctx.log), "dropdb ran for #{url}"
      end
    end

    test "the maintenance database is added without an empty query parameter", ctx do
      for url <- [
            "postgres://stage@stage-db/kiln_staging?sslmode=require&",
            "postgres://stage@stage-db/kiln_staging?",
            "postgres://stage@stage-db/kiln_staging"
          ] do
        assert {_out, 0} = down(ctx, url)
      end

      assert [
               ["dropdb", _, _, "--maintenance-db=" <> first, "--", "kiln_staging"],
               ["dropdb", _, _, "--maintenance-db=" <> second, "--", "kiln_staging"],
               ["dropdb", _, _, "--maintenance-db=" <> third, "--", "kiln_staging"]
             ] = calls(ctx)

      assert first == "postgres://stage@stage-db/kiln_staging?sslmode=require&dbname=postgres"
      assert second == "postgres://stage@stage-db/kiln_staging?dbname=postgres"
      assert third == "postgres://stage@stage-db/kiln_staging?dbname=postgres"
    end

    test "KILN_STAGING_FORCE, spelled as Kiln reads a flag, lets down drop any name", ctx do
      for value <- ["yes", "TRUE", " on ", "1"] do
        File.rm(ctx.log)

        assert {out, 0} =
                 down(ctx, "postgres://stage@stage-db/kiln_prod",
                   env: [{"KILN_STAGING_FORCE", value}]
                 )

        assert out =~ "KILN_STAGING_FORCE is on: accepting kiln_prod"
        assert [["dropdb", _, "--if-exists", _, "--", "kiln_prod"]] = calls(ctx)
      end

      for value <- ["", "no", "false", "please"] do
        assert {out, status} =
                 down(ctx, "postgres://stage@stage-db/kiln_prod2",
                   env: [{"KILN_STAGING_FORCE", value}]
                 )

        assert status != 0, "KILN_STAGING_FORCE=#{inspect(value)} forced the drop"

        assert out =~
                 "STAGING_DATABASE_URL names kiln_prod2, which does not look like a throwaway clone",
               "KILN_STAGING_FORCE=#{inspect(value)}"

        refute out =~ "KILN_STAGING_FORCE is on"
        refute Enum.any?(calls(ctx), &("kiln_prod2" in &1))
      end
    end

    test "a marker matches in any case, and the name is percent-decoded as libpq reads it",
         ctx do
      assert {_out, 0} = down(ctx, "postgres://stage@stage-db/KILN_STAGING")
      assert {_out, 0} = down(ctx, "postgres://stage@stage-db/kiln%5Fpreview")

      assert [
               ["dropdb", _, _, _, "--", "KILN_STAGING"],
               ["dropdb", _, _, _, "--", "kiln_preview"]
             ] = calls(ctx)
    end

    test "up refuses a production-looking name before anything is created or copied", ctx do
      assert {out, status} =
               up(ctx,
                 prod: "postgres://prod@prod-db/kiln_prod",
                 staging: "postgres://stage@stage-db/kiln_prod"
               )

      assert status != 0

      assert out =~
               "STAGING_DATABASE_URL names kiln_prod, which does not look like a throwaway clone"

      assert out =~ "Nothing was created or copied"
      refute out =~ "Cloning production"
      refute File.exists?(ctx.log), "a tool ran"
    end

    test "up refuses a production name after a bracketed host, and a # after the host",
         ctx do
      for {staging, message} <- [
            {"postgres://stage@[/tmp]/kiln_prod",
             "STAGING_DATABASE_URL names kiln_prod, which does not look like a throwaway clone"},
            {"postgres://stage@h1,[/tmp]/kiln_prod",
             "STAGING_DATABASE_URL names kiln_prod, which does not look like a throwaway clone"},
            {"postgres://stage@[/tmp/kiln_staging", "STAGING_DATABASE_URL has a host in [ ]"},
            {"postgres://stage@stage-db/kiln_prod#staging",
             "STAGING_DATABASE_URL has a # after its host"}
          ] do
        assert {out, status} =
                 up(ctx, prod: "postgres://prod@prod-db/kiln_prod", staging: staging)

        assert status != 0, staging
        assert out =~ message, staging
        assert out =~ "Nothing was created or copied", staging
        refute File.exists?(ctx.log), "a tool ran for #{staging}"
      end
    end

    test "up creates the database after a bracketed host", ctx do
      assert {_out, 0} =
               up(ctx,
                 prod: "postgres://prod@prod-db/kiln_prod",
                 staging: "postgres://stage@[::1]:5432/kiln_staging"
               )

      assert [["createdb", _, maint, "--", "kiln_staging"] | _] = calls(ctx)
      assert maint == "--maintenance-db=postgres://stage@[::1]:5432/kiln_staging?dbname=postgres"
    end

    test "up creates the database on the URL's server, with the password in PGPASSWORD only",
         ctx do
      assert {_out, 0} =
               up(ctx,
                 prod: "postgres://prod@prod-db/kiln_prod",
                 staging: "postgres://stage:stage-pw@stage-db:6432/kiln_staging?sslmode=require"
               )

      assert [["createdb", "stage-pw", maint, "--", "kiln_staging"] | _] = calls(ctx)
      assert maint == @maint <> "postgres"
    end

    test "up goes on when createdb fails both ways, and says why", ctx do
      fail_through!(ctx, "dbname=", "createdb")

      assert {out, 0} =
               up(ctx,
                 prod: "postgres://prod@prod-db/kiln_prod",
                 staging: "postgres://stage@stage-db/kiln_staging"
               )

      assert out =~ "createdb skipped — assuming kiln_staging exists"
      assert out =~ "through template1: createdb: connection refused"
      assert Enum.any?(calls(ctx), &(hd(&1) == "psql"))
    end
  end

  # Replaces the `tool` stub with one that logs its call, then fails (saying
  # so on stderr) when any argument contains `match`.
  defp fail_through!(ctx, match, tool \\ "dropdb") do
    stub!(ctx.bin, tool, """
    #!/bin/sh
    line="$(printf '%s|%s' "#{tool}" "${PGPASSWORD--}"; printf '|%s' "$@")"
    printf '%s\\n' "$line" >> "#{ctx.log}"
    case "$*" in
      *#{match}*) echo "#{tool}: connection refused" >&2; exit 1 ;;
    esac
    """)
  end

  defp down(ctx, staging, opts \\ []),
    do: run(ctx, "down", Keyword.merge(opts, staging: staging))

  defp calls(ctx) do
    ctx.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "|"))
  end

  defp up(ctx, opts), do: run(ctx, "up", opts)

  defp run(ctx, command, opts) do
    env =
      [
        {"PROD_DATABASE_URL", opts[:prod]},
        {"STAGING_DATABASE_URL", opts[:staging]},
        {"KILN_BIN", Path.join(ctx.bin, "kiln")},
        {"PGPASSWORD", nil},
        {"KILN_STAGING_FORCE", nil},
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
      ]

    env =
      Enum.reduce(opts[:env] || [], env, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end)

    System.cmd("bash", [@script, command], env: env, stderr_to_stdout: true)
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
