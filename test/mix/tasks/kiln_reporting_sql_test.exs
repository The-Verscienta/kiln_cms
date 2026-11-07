defmodule Mix.Tasks.Kiln.Reporting.SqlTest do
  @moduledoc """
  `mix kiln.reporting.sql` (#2295) prints a script for a read-only BI role.
  The printed text is checked for what it grants, and executed inside the
  sandbox transaction to prove the resulting role reads the views and not the
  base tables.
  """
  # Creates a role and grants on the shared schema, which lock the same
  # catalog rows; two open sandbox transactions doing so deadlock.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Repo
  alias Mix.Tasks.Kiln.Reporting.Sql

  defp print(args) do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Sql.run(args)

    receive do
      {:mix_shell, :info, [text]} -> text
    after
      0 -> flunk("nothing printed")
    end
  end

  test "prints the default role and every view grant, and runs nothing" do
    sql = print([])

    assert sql =~ ~s(CREATE ROLE "kiln_bi" LOGIN PASSWORD 'REPLACE_WITH_)
    assert sql =~ ~s(GRANT SELECT ON kiln_reporting_v1.pages TO "kiln_bi";)
    assert sql =~ ~s(GRANT SELECT ON kiln_reporting_v1.pages_field_values TO "kiln_bi";)
    assert sql =~ ~s(GRANT SELECT ON kiln_reporting_v1.entries TO "kiln_bi";)
    assert sql =~ "SET statement_timeout = '60s'"
    assert sql =~ "SET default_transaction_read_only = on"
    assert sql =~ "SET search_path = kiln_reporting_v1"
    assert sql =~ "read replica"
    assert sql =~ "every organization"
    refute sql =~ "CONNECT"
  end

  test "the script says what the settings and the REVOKE do not guarantee" do
    sql = Sql.script("kiln_bi")

    assert sql =~ "advisory"
    assert sql =~ "For hard enforcement connect to a read replica"
    assert sql =~ "PUBLIC"
    assert sql =~ "Re-run the GRANT lines after an upgrade"
  end

  test "the printed note about upgrades goes to stderr, not into the SQL" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Sql.run([])

    assert_received {:mix_shell, :error, [note]}
    assert note =~ "re-run this script after any upgrade"
    refute_received {:mix_shell, :error, _}
  end

  # A fresh `mix` has loaded no resource module, which is where the view list
  # once came back empty: the in-VM tests above run with every module loaded.
  @tag timeout: 180_000
  test "a fresh mix run lists every view" do
    mix = System.find_executable("mix") || flunk("mix is not on PATH")

    {out, status} =
      System.cmd(mix, ["kiln.reporting.sql"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: false,
        cd: File.cwd!()
      )

    assert status == 0
    grants = Regex.scan(~r/^GRANT SELECT ON kiln_reporting_v1\.\w+ TO /m, out)
    assert length(grants) == length(Sql.views())
    assert length(grants) >= 6
  end

  test "--database adds CONNECT" do
    sql = print(["--role", "bi_2", "--database", "kiln_prod"])
    assert sql =~ ~s(GRANT CONNECT ON DATABASE "kiln_prod" TO "bi_2";)
  end

  test "refuses names that are not safe identifiers" do
    for bad <- ["x; DROP ROLE y", "Upper", "1abc", "a-b", "", String.duplicate("a", 64), ~s(a")] do
      assert_raise Mix.Error, fn -> capture_io(fn -> Sql.run(["--role", bad]) end) end
      assert_raise Mix.Error, fn -> capture_io(fn -> Sql.run(["--database", bad]) end) end
    end
  end

  test "grants only on the reporting schema, never on public" do
    sql = print([])

    grants = Regex.scan(~r/^GRANT .*$/m, sql) |> List.flatten()
    assert grants != []

    for g <- grants do
      assert g =~ "kiln_reporting_v1" or g =~ "ON DATABASE"
    end

    refute sql =~ ~r/GRANT[^;]*public\./
    refute sql =~ "ALL TABLES"
    assert sql =~ ~s(REVOKE ALL ON SCHEMA public FROM "kiln_bi")
  end

  test "the printed script yields a role that reads the views and not the tables" do
    role = "kiln_bi_t#{System.unique_integer([:positive])}"

    sql =
      role
      |> Sql.script()
      |> String.replace("REPLACE_WITH_A_LONG_RANDOM_PASSWORD", "test-only")

    sql
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Enum.join("\n")
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Repo.query!/1)

    Repo.query!("SET LOCAL ROLE #{role}")
    # ALTER ROLE ... SET applies at login; a role switch keeps the session's
    # path, so set what a BI login would get.
    Repo.query!("SET LOCAL search_path = kiln_reporting_v1")

    try do
      assert %{rows: _} = Repo.query!("SELECT count(*) FROM pages")
      assert %{rows: _} = Repo.query!("SELECT count(*) FROM kiln_reporting_v1.pages_field_values")

      error =
        assert_raise Postgrex.Error, fn -> Repo.query!("SELECT 1 FROM public.pages LIMIT 1") end

      assert Exception.message(error) =~ "permission denied"
    after
      Repo.query!("RESET ROLE")
    end
  end

  test "the script carries the login-time settings" do
    assert Sql.script("kiln_bi") =~
             ~s(ALTER ROLE "kiln_bi" SET default_transaction_read_only = on;)
  end
end
