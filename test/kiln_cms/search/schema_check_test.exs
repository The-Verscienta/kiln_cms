defmodule KilnCMS.Search.SchemaCheckTest do
  @moduledoc """
  The gate for the trap #295 described: a content type's table needs its own
  `search_vector` migration, nothing generates it, and the omission is
  invisible until a query — any query, on any type, since a global search
  sweeps them all.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureIO

  alias KilnCMS.Repo
  alias KilnCMS.Search.SchemaCheck

  # The check's own passing case, and the one that matters: run against the
  # migrated database the rest of the suite uses, so a content type that ships
  # without its migration fails here rather than in production.
  test "every registered content table is fully set up" do
    assert SchemaCheck.report() == []
  end

  describe "inspect_table/1" do
    setup do
      table = "schema_check_probe_#{System.unique_integer([:positive])}"

      Repo.query!("""
      CREATE TABLE #{table} (
        id uuid PRIMARY KEY,
        title text,
        search_text text,
        locale text
      )
      """)

      %{table: table}
    end

    test "a table with none of it reports all three", %{table: table} do
      assert SchemaCheck.inspect_table(table) == [:column, :trigger, :index]
    end

    test "the column alone is not enough — an unfired trigger goes stale", %{table: table} do
      Repo.query!("ALTER TABLE #{table} ADD COLUMN search_vector tsvector")

      assert SchemaCheck.inspect_table(table) == [:trigger, :index]
    end

    test "a missing index is still reported (it seq-scans, it doesn't fail)", %{table: table} do
      Repo.query!("ALTER TABLE #{table} ADD COLUMN search_vector tsvector")
      create_trigger(table)

      assert SchemaCheck.inspect_table(table) == [:index]
    end

    test "all three present is clean", %{table: table} do
      Repo.query!("ALTER TABLE #{table} ADD COLUMN search_vector tsvector")
      create_trigger(table)

      Repo.query!("CREATE INDEX #{table}_search_vector_gin ON #{table} USING gin (search_vector)")

      assert SchemaCheck.inspect_table(table) == []
    end

    test "a table that does not exist reports :table, not three gaps" do
      assert SchemaCheck.inspect_table("no_such_table_at_all") == [:table]
    end
  end

  # The gate itself, on the passing side. Its failing side needs a table with
  # the column removed, which takes a lock the rest of the suite cannot run
  # alongside — see `KilnCMS.Search.MissingSearchVectorTest` (`:table_lock`).
  test "the mix task passes on a migrated database" do
    output = capture_io(fn -> Mix.Tasks.Kiln.Search.Check.run([]) end)

    assert output =~ "every content table carries its search_vector"
  end

  test "the migration it prints calls the helper for that table" do
    migration =
      SchemaCheck.migration(%{resource: KilnCMS.CMS.Page, table: "products", missing: []})

    assert migration =~ "defmodule KilnCMS.Repo.Migrations.AddProductsSearchVector"
    assert migration =~ ~s|def up, do: add_search_vector("products")|
    assert migration =~ ~s|def down, do: drop_search_vector("products")|
  end

  # The shared trigger function the core migration installed.
  defp create_trigger(table) do
    Repo.query!("""
    CREATE TRIGGER #{table}_search_vector_trg
      BEFORE INSERT OR UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION kiln_search_vector_refresh()
    """)
  end
end
