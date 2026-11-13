defmodule KilnCMS.Backups.PgUrlTest do
  @moduledoc """
  `KilnCMS.Backups.PgUrl` (#2719, #2726): a `DATABASE_URL` as libpq reads it,
  with the password moved out of argv.

  The same table drives the shell copy (`pg_conn_split`) in
  `test/scripts/pg_conn_split_test.exs`, so the two cannot drift apart.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.PgUrl

  @cases KilnCMS.Test.PgUrlCases.cases()

  describe "split/1" do
    for {label, input, url, password} <- @cases do
      @input input
      @url url
      @env if(password, do: [{"PGPASSWORD", password}], else: [])

      test label do
        assert PgUrl.split(@input) == {@url, @env}
      end
    end

    test "nil" do
      assert PgUrl.split(nil) == {nil, []}
    end

    test "never raises, whatever follows a `%`" do
      for tail <- ["%", "%z", "%zz", "%0", "%%", "%g0", "%00"] do
        assert {"postgres://u@h/db", [{"PGPASSWORD", "p" <> ^tail}]} =
                 PgUrl.split("postgres://u:p#{tail}@h/db")
      end
    end
  end

  describe "normalize/1" do
    test "rewrites the ecto scheme, in any case, and nothing else" do
      assert PgUrl.normalize("ecto://u:p%40@h/db?sslmode=require") ==
               "postgres://u:p%40@h/db?sslmode=require"

      assert PgUrl.normalize("Ecto://h/db") == "postgres://h/db"
      assert PgUrl.normalize("postgresql://h/db") == "postgresql://h/db"
      assert PgUrl.normalize("host=db dbname=kiln") == "host=db dbname=kiln"
      assert PgUrl.normalize("ecto:/h/db") == "ecto:/h/db"
      assert PgUrl.normalize("") == ""
      assert PgUrl.normalize(nil) == nil
    end
  end
end
