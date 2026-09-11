defmodule KilnCMS.Demo.RestoreTest do
  @moduledoc """
  The golden restore (`docs/demo-mode.md`).

  The `:pg_tools` cases really run `pg_dump`, `pg_restore` and `psql` — against
  a scratch database of their own, never the test database — because the
  claims are about what Postgres does: that the wipe and the restore are one
  transaction, that objects newer than the snapshot go, and that extensions
  survive. A mocked restore would prove none of it.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Demo.Restore

  @moduletag :capture_log

  describe "filter_listing/1" do
    @listing """
    ;
    ; Archive created at 2026-09-11 10:00:00 UTC
    ;     dbname: kiln_demo
    ;
    3; 3079 16385 EXTENSION - vector
    4521; 0 0 COMMENT - EXTENSION vector
    5; 2615 2200 SCHEMA - public pg_database_owner
    4522; 0 0 COMMENT - SCHEMA public pg_database_owner
    6; 2615 17000 SCHEMA - public_extra postgres
    220; 1259 16390 TABLE public items postgres
    4400; 0 16390 TABLE DATA public items postgres
    4401; 0 16400 TABLE DATA public tokens postgres
    4402; 0 16410 TABLE DATA public oban_jobs postgres
    4403; 0 16411 TABLE DATA public oban_peers postgres
    4404; 0 16412 TABLE DATA public tokens_archive postgres
    """

    test "comments out extensions, the public schema and the never-restored rows" do
      assert Restore.filter_listing(@listing) == """
             ;
             ; Archive created at 2026-09-11 10:00:00 UTC
             ;     dbname: kiln_demo
             ;
             ; skipped by demo reset: 3; 3079 16385 EXTENSION - vector
             ; skipped by demo reset: 4521; 0 0 COMMENT - EXTENSION vector
             ; skipped by demo reset: 5; 2615 2200 SCHEMA - public pg_database_owner
             ; skipped by demo reset: 4522; 0 0 COMMENT - SCHEMA public pg_database_owner
             6; 2615 17000 SCHEMA - public_extra postgres
             220; 1259 16390 TABLE public items postgres
             4400; 0 16390 TABLE DATA public items postgres
             ; skipped by demo reset: 4401; 0 16400 TABLE DATA public tokens postgres
             ; skipped by demo reset: 4402; 0 16410 TABLE DATA public oban_jobs postgres
             ; skipped by demo reset: 4403; 0 16411 TABLE DATA public oban_peers postgres
             4404; 0 16412 TABLE DATA public tokens_archive postgres
             """
    end

    test "names the source database from the header" do
      assert Restore.source_database(@listing) == "kiln_demo"
      assert Restore.source_database("; no header here\n") == nil
    end
  end

  test "a missing snapshot is refused before anything else happens" do
    path =
      Path.join(System.tmp_dir!(), "no-such-golden-#{System.unique_integer([:positive])}.dump")

    assert Restore.read_golden(path) == {:error, {:golden_missing, path}}
  end

  describe "against a real database" do
    @describetag :pg_tools

    setup do
      # Random, not `System.unique_integer/1`: that counter is per-VM, and the
      # partitioned CI shards share one Postgres server.
      db = "kiln_demo_it_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      dir = Path.join(System.tmp_dir!(), db)
      File.mkdir_p!(dir)

      admin!(&Postgrex.query!(&1, "CREATE DATABASE \"#{db}\"", []))

      on_exit(fn ->
        admin!(&Postgrex.query!(&1, "DROP DATABASE IF EXISTS \"#{db}\" WITH (FORCE)", []))
        File.rm_rf!(dir)
      end)

      {:ok, conn} = Postgrex.start_link(conn_opts(db))

      %{
        db: db,
        conn: conn,
        url: url(db),
        golden: Path.join(dir, "golden.dump"),
        work: Path.join(dir, "work")
      }
    end

    test "replaces the database with the snapshot — newer objects go, extensions and excluded tables stay",
         ctx do
      golden!(ctx)
      vandalize!(ctx.conn)

      assert {:ok, golden} = Restore.read_golden(ctx.golden)
      assert golden.source_database == ctx.db
      assert {:ok, work} = Restore.prepare(golden, ctx.work)
      assert Restore.run(work, ctx.url) == :ok

      assert rows(ctx.conn, "SELECT id, name, embedding::text FROM items ORDER BY id") ==
               [[1, "golden", "[1,2,3]"]]

      # A table created after the snapshot — a migration newer than it — is gone,
      # so the `migrate` that follows can create it again.
      assert rows(ctx.conn, "SELECT to_regclass('public.newer_table')::text") == [[nil]]

      # The table is the snapshot's; its rows are nobody's.
      assert rows(ctx.conn, "SELECT count(*) FROM tokens") == [[0]]

      assert rows(
               ctx.conn,
               "SELECT extname FROM pg_extension WHERE extname IN ('vector', 'pg_trgm') ORDER BY extname"
             ) == [["pg_trgm"], ["vector"]]

      assert rows(ctx.conn, "SELECT similarity('kiln', 'kiln')") == [[1.0]]
      assert rows(ctx.conn, "SELECT shout('golden')") == [["GOLDEN"]]
      assert rows(ctx.conn, "SELECT name FROM item_names") == [["golden"]]
      assert rows(ctx.conn, "SELECT 'ok'::mood::text") == [["ok"]]
    end

    test "a restore that fails partway changes nothing — the wipe rolls back with it", ctx do
      golden!(ctx)
      vandalize!(ctx.conn)

      {:ok, golden} = Restore.read_golden(ctx.golden)
      {:ok, work} = Restore.prepare(golden, ctx.work)
      failing_line = work.restore |> File.read!() |> String.split("\n") |> length()
      File.write!(work.restore, "SELECT 1/0;\n", [:append])

      assert Restore.run(work, ctx.url) ==
               {:error,
                {:restore_failed,
                 "psql exited 3: psql:#{work.restore}:#{failing_line}: ERROR:  division by zero"}}

      assert rows(ctx.conn, "SELECT id, name FROM items ORDER BY id") ==
               [[1, "vandalized"], [2, "visitor"]]

      assert rows(ctx.conn, "SELECT to_regclass('public.newer_table')::text") == [["newer_table"]]
      assert rows(ctx.conn, "SELECT count(*) FROM tokens") == [[2]]
    end

    test "dump/2 writes a private, verified snapshot and no partial", ctx do
      golden!(ctx)

      assert File.stat!(ctx.golden).mode |> Bitwise.band(0o777) == 0o600
      refute File.exists?(ctx.golden <> ".partial")
    end

    test "an unreadable snapshot is refused", ctx do
      File.write!(ctx.golden, "this is not an archive")

      assert {:error, {:golden_unreadable, "pg_restore exited 1: " <> _detail}} =
               Restore.read_golden(ctx.golden)
    end

    test "prepare/2 removes its working files with cleanup/1", ctx do
      golden!(ctx)
      {:ok, golden} = Restore.read_golden(ctx.golden)
      {:ok, work} = Restore.prepare(golden, ctx.work)

      assert File.ls!(ctx.work) |> Enum.sort() == ["restore.sql", "wipe.sql"]
      assert Restore.cleanup(work) == :ok
      refute File.exists?(ctx.work)
    end
  end

  # The golden state: the shapes a Kiln database actually has — an extension
  # type in a column, an extension-owned function, a routine, an enum, a view,
  # and a `tokens` table holding a captured session.
  defp golden!(ctx) do
    sql!(ctx.conn, [
      "CREATE EXTENSION IF NOT EXISTS vector",
      "CREATE EXTENSION IF NOT EXISTS pg_trgm",
      "CREATE TABLE items (id int PRIMARY KEY, name text NOT NULL, embedding vector(3))",
      "CREATE TABLE tokens (jti text PRIMARY KEY)",
      "CREATE FUNCTION shout(t text) RETURNS text LANGUAGE sql AS $$ SELECT upper(t) $$",
      "CREATE TYPE mood AS ENUM ('ok', 'meh')",
      "CREATE VIEW item_names AS SELECT name FROM items",
      "INSERT INTO items VALUES (1, 'golden', '[1,2,3]')",
      "INSERT INTO tokens VALUES ('captured-session')"
    ])

    assert Restore.dump(ctx.url, ctx.golden) == :ok
  end

  # What a demo session leaves behind, plus what an upgrade adds.
  defp vandalize!(conn) do
    sql!(conn, [
      "UPDATE items SET name = 'vandalized' WHERE id = 1",
      "INSERT INTO items VALUES (2, 'visitor', NULL)",
      "CREATE TABLE newer_table (id int)",
      "INSERT INTO tokens VALUES ('visitor-session')"
    ])
  end

  defp sql!(conn, statements), do: Enum.each(statements, &Postgrex.query!(conn, &1, []))

  defp rows(conn, sql), do: Postgrex.query!(conn, sql, []).rows

  defp admin!(fun) do
    {:ok, conn} = Postgrex.start_link(conn_opts("postgres"))

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

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
