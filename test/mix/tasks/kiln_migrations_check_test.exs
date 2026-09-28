defmodule Mix.Tasks.Kiln.Migrations.CheckTest do
  @moduledoc """
  The expand/contract migration gate (#1716).

  Every rule is asserted RED against a fixture that carries exactly that one
  defect, and GREEN against the additive shapes Ash codegen writes every day,
  so a rule that stops firing — or starts firing on ordinary migrations —
  fails here. The override marker is pinned both ways: it silences only the
  statement it sits on, and a malformed, unshipped or idle marker is itself a
  finding. `run/1` is driven against a real git repository, because "which
  files are new" is the part a unit test of the parser cannot see.
  """
  # `run/1` changes the working directory and swaps `Mix.shell/1`, both
  # process-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kiln.Migrations.Check

  @version Version.parse!("0.12.0")

  defp rules(source, opts \\ []) do
    source
    |> Check.check_source(Keyword.put_new(opts, :version, @version))
    |> Enum.map(& &1.rule)
  end

  defp migration(up, extra \\ "") do
    """
    defmodule KilnCMS.Repo.Migrations.Fixture do
      use Ecto.Migration
    #{extra}
      def up do
    #{up}
      end

      def down do
        drop table(:whatever)
        alter table(:posts) do
          remove :anything
          modify :title, :integer, null: false
        end
      end
    end
    """
  end

  describe "red — each contract pattern, alone" do
    test "drop table" do
      assert [:drop_table] == rules(migration("drop table(:posts)"))
    end

    test "drop_if_exists table" do
      assert [:drop_table] == rules(migration("drop_if_exists table(:posts)"))
    end

    test "rename table" do
      assert [:rename] == rules(migration("rename table(:posts), to: table(:articles)"))
    end

    test "rename column" do
      assert [:rename] == rules(migration("rename table(:posts), :title, to: :headline"))
    end

    test "remove a column" do
      assert [:remove_column] ==
               rules(migration("alter table(:posts) do\n  remove :title\nend"))
    end

    test "remove_if_exists a column" do
      assert [:remove_column] ==
               rules(migration("alter table(:posts) do\n  remove_if_exists :title, :text\nend"))
    end

    test "modify changing the type, per `from:`" do
      up = "alter table(:posts) do\n  modify :views, :bigint, from: :integer\nend"
      assert [:type_change] == rules(migration(up))
    end

    test "modify changing the type, per the migration history" do
      up = "alter table(:posts) do\n  modify :views, :bigint\nend"
      assert [:type_change] == rules(migration(up), columns: %{{"posts", "views"} => ":integer"})
    end

    test "modify whose previous type is unknown" do
      up = "alter table(:posts) do\n  modify :views, :bigint\nend"
      assert [:type_change] == rules(migration(up))
    end

    test "modify to null: false" do
      up = "alter table(:posts) do\n  modify :title, :text, null: false\nend"
      assert [:set_not_null] == rules(migration(up), columns: %{{"posts", "title"} => ":text"})
    end

    test "add null: false without a default, on an existing table" do
      up = "alter table(:posts) do\n  add :kind, :text, null: false\nend"
      assert [:add_not_null] == rules(migration(up))
    end

    for {sql, label} <- [
          {"ALTER TABLE posts DROP COLUMN title", "DROP COLUMN"},
          {"DROP TABLE posts", "DROP TABLE"},
          {"drop view post_summaries", "DROP VIEW (lowercase)"},
          {"ALTER TABLE posts RENAME COLUMN title TO headline", "RENAME"},
          {"ALTER TABLE posts ALTER COLUMN views TYPE bigint", "ALTER COLUMN TYPE"},
          {"ALTER TABLE posts ALTER COLUMN views SET DATA TYPE bigint", "SET DATA TYPE"},
          {"ALTER TABLE posts ALTER COLUMN title SET NOT NULL", "SET NOT NULL"}
        ] do
      test "execute with #{label}" do
        assert [:raw_sql] == rules(migration(~s|execute("#{unquote(sql)}")|))
      end
    end

    test "execute with a heredoc, interpolated" do
      up = ~S'''
      execute """
      ALTER TABLE #{@table}
        DROP COLUMN title
      """
      '''

      assert [:raw_sql] == rules(migration(up))
    end

    test "execute/2 reads only the forward SQL" do
      assert [] == rules(migration(~s|execute("SELECT 1", "DROP TABLE posts")|))
      assert [:raw_sql] == rules(migration(~s|execute("DROP TABLE posts", "SELECT 1")|))
    end

    test "a non-concurrent index on a large table" do
      assert [:index_on_large_table] ==
               rules(migration(~s|create index(:posts, [:org_id], name: "posts_org_id_index")|))
    end

    test "a non-concurrent unique_index on a large table" do
      assert [:index_on_large_table] ==
               rules(migration(~s|create unique_index(:entries, [:slug])|))
    end

    test "concurrently: true without @disable_ddl_transaction" do
      assert [:concurrent_in_transaction] ==
               rules(migration(~s|create index(:posts, [:org_id], concurrently: true)|))
    end

    test "change/0 is the forward direction too" do
      source = """
      defmodule M do
        use Ecto.Migration
        def change do
          alter table(:posts) do
            remove :title
          end
        end
      end
      """

      assert [:remove_column] == rules(source)
    end

    test "a statement inside a `for` over table names is still checked" do
      up = """
      for t <- [:posts, :pages] do
        alter table(t) do
          remove :legacy
        end
      end
      """

      assert [:remove_column] == rules(migration(up))
    end

    test "every statement of a multi-op block is its own finding" do
      up = """
      alter table(:webhook_endpoints) do
        remove :secret
        modify :secret_encrypted, :binary, null: false
      end
      """

      assert [:remove_column, :set_not_null] ==
               rules(migration(up),
                 columns: %{{"webhook_endpoints", "secret_encrypted"} => ":binary"}
               )
    end
  end

  describe "the migration #1716 names" do
    test "20260919191545_drop_webhook_plaintext_secret would have been red" do
      path = "priv/repo/migrations/20260919191545_drop_webhook_plaintext_secret.exs"

      assert [:remove_column, :set_not_null] ==
               path
               |> File.read!()
               |> rules(file: path, columns: Check.columns_before_file(path))
    end
  end

  describe "green — additive shapes" do
    test "adding nullable and defaulted columns" do
      up = """
      alter table(:posts) do
        add :subtitle, :text
        add :kind, :text, null: false, default: "article"
        add :org_id, references(:organizations, type: :uuid, column: :id), null: true
      end
      """

      assert [] == rules(migration(up))
    end

    test "creating a table with NOT NULL columns and indexing it, even if its name is 'large'" do
      up = """
      create table(:posts, primary_key: false) do
        add :id, :uuid, null: false, primary_key: true
        add :title, :text, null: false
      end

      alter table(:posts) do
        add :org_id, :uuid, null: false
        modify :title, :citext, null: false
      end

      create index(:posts, [:org_id])
      """

      assert [] == rules(migration(up))
    end

    test "a concurrent index with the transaction disabled" do
      source =
        migration(
          ~s|create index(:posts, [:org_id], concurrently: true)|,
          "  @disable_ddl_transaction true\n  @disable_migration_lock true\n"
        )

      assert [] == rules(source)
    end

    test "a non-concurrent index on a table not listed as large" do
      assert [] == rules(migration(~s|create index(:menus, [:org_id])|))
    end

    test "modify keeping the type (a references change), per history and per `from:`" do
      up = """
      alter table(:posts) do
        modify :category_id, references(:categories, column: :id, type: :uuid)
        modify :views, :integer, from: {:integer, null: false}, null: false
        modify :title, :text, null: true
      end
      """

      assert [] ==
               rules(migration(up),
                 columns: %{
                   {"posts", "category_id"} => ":uuid",
                   {"posts", "title"} => ":text"
                 }
               )
    end

    test "a type the same migration added earlier is known" do
      up = """
      alter table(:posts) do
        add :views, :integer
      end

      alter table(:posts) do
        modify :views, :integer, default: 0
      end
      """

      assert [] == rules(migration(up))
    end

    test "dropping indexes, constraints and functions" do
      up = """
      drop_if_exists index(:posts, [:title])
      drop constraint(:posts, "posts_category_id_fkey")
      execute("DROP FUNCTION IF EXISTS kiln_touch() CASCADE")
      execute("DROP TRIGGER IF EXISTS posts_touch ON posts")
      """

      assert [] == rules(migration(up))
    end

    test "the down direction is never read" do
      assert [] == rules(migration(""))
    end

    test "the words in a string or a doc are not operations" do
      source = """
      defmodule M do
        @moduledoc "we remove :title and drop table(:posts) later"
        use Ecto.Migration
        def up do
          IO.puts("remove :title")
        end
      end
      """

      assert [] == rules(source)
    end
  end

  describe "the override marker" do
    @marker "# kiln:contract-ok since v0.11.0 — nothing reads posts.legacy after 0.11"

    test "above an alter block, covers every op in it" do
      up = """
      #{@marker}
      alter table(:posts) do
        remove :legacy
        remove :older
      end
      """

      assert [] == rules(migration(up))
    end

    test "above a single op inside a block" do
      up = """
      alter table(:posts) do
        #{@marker}
        remove :legacy
      end
      """

      assert [] == rules(migration(up))
    end

    test "trailing on the statement's line" do
      up = "alter table(:posts) do\n  remove :legacy #{@marker}\nend"
      assert [] == rules(migration(up))
    end

    test "covers only the statement it sits on" do
      up = """
      alter table(:posts) do
        #{@marker}
        remove :legacy
        remove :other
      end
      """

      assert [%{rule: :remove_column, line: line}] =
               Check.check_source(migration(up), version: @version)

      assert migration(up) |> String.split("\n") |> Enum.at(line - 1) =~ "remove :other"
    end

    test "a marker two statements up does not reach" do
      up = """
      #{@marker}
      drop table(:unrelated)
      drop table(:posts)
      """

      assert [:drop_table] == rules(migration(up))
    end

    test "the release it names may equal the current version" do
      up = """
      # kiln:contract-ok since v0.12.0 — 0.12.0 stopped reading it
      drop table(:posts)
      """

      assert [] == rules(migration(up))
    end

    test "accepts an ASCII dash" do
      up = """
      # kiln:contract-ok since v0.11.0 -- 0.11.0 stopped reading it
      drop table(:posts)
      """

      assert [] == rules(migration(up))
    end

    test "a contract marker does not excuse a lock on a large table" do
      up = """
      #{@marker}
      create index(:posts, [:org_id])
      """

      assert Enum.sort([:index_on_large_table, :unused_marker]) ==
               Enum.sort(rules(migration(up)))
    end

    test "kiln:lock-ok excuses the index build" do
      up = """
      # kiln:lock-ok — posts is at most a few thousand rows on every known site
      create index(:posts, [:org_id])
      """

      assert [] == rules(migration(up))
    end

    test "kiln:lock-ok does not excuse a contract step" do
      up = """
      # kiln:lock-ok — this is the wrong marker
      drop table(:posts)
      """

      assert Enum.sort([:drop_table, :unused_marker]) == Enum.sort(rules(migration(up)))
    end

    for {bad, why} <- [
          {"# kiln:contract-ok — no release named", "no since"},
          {"# kiln:contract-ok since v0.11.0", "no reason"},
          {"# kiln:contract-ok since 0.11.0 — no v", "no v prefix"},
          {"# kiln:contract-ok since vbanana — not a version", "unparseable version"},
          {"# kiln:lock-ok", "lock marker with no reason"}
        ] do
      test "a malformed marker is red (#{why}), and does not excuse the statement" do
        up = """
        #{unquote(bad)}
        drop table(:posts)
        """

        assert Enum.sort([:drop_table, :malformed_marker]) == Enum.sort(rules(migration(up)))
      end
    end

    test "a marker naming a release that has not shipped" do
      up = """
      # kiln:contract-ok since v1.0.0 — stops reading it in this same release
      drop table(:posts)
      """

      assert Enum.sort([:drop_table, :marker_unshipped]) == Enum.sort(rules(migration(up)))
    end

    test "a marker that excuses nothing" do
      up = """
      #{@marker}
      alter table(:posts) do
        add :subtitle, :text
      end
      """

      assert [:unused_marker] == rules(migration(up))
    end

    test "the marker text inside a string is not a marker" do
      up = """
      IO.puts("#{@marker}")
      drop table(:posts)
      """

      assert [:drop_table] == rules(migration(up))
    end
  end

  describe "large_tables/0" do
    test "names tables the core actually has" do
      snapshots = File.ls!("priv/resource_snapshots/repo")
      tables = Check.large_tables()

      assert length(tables) > 10

      for table <- tables, table != "oban_jobs" do
        assert table in snapshots, "#{table} is listed as large but has no resource snapshot"
      end
    end
  end

  describe "run/1 against a git repository" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "kiln-migrations-check-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(dir, "priv/repo/migrations"))
      File.mkdir_p!(Path.join(dir, "projects/demo/priv/repo/migrations"))

      File.write!(
        Path.join(dir, "mix.exs"),
        ~s|defmodule X.MixProject do\n  @version "0.12.0"\nend\n|
      )

      # Historical: breaks the policy, but predates the base, so it is exempt.
      File.write!(
        Path.join(dir, "priv/repo/migrations/20200101000000_old.exs"),
        migration("drop table(:ancient)")
      )

      git!(dir, ["init", "-q", "-b", "main"])
      git!(dir, ["add", "-A"])
      git!(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])

      previous_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Mix.shell(previous_shell)
        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    defp git!(dir, args) do
      {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      out
    end

    defp run_in(dir, args), do: File.cd!(dir, fn -> Check.run(args) end)

    test "no new migrations is green, and the history is not re-judged", %{dir: dir} do
      run_in(dir, ["--base", "main"])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "0 new migration(s)"
    end

    test "an added core migration is red", %{dir: dir} do
      File.write!(
        Path.join(dir, "priv/repo/migrations/20300101000000_new.exs"),
        migration("alter table(:posts) do\n  remove :title\nend")
      )

      assert_raise Mix.Error, ~r/1 problem\(s\) in 1 migration/, fn ->
        run_in(dir, ["--base", "main"])
      end

      assert_received {:mix_shell, :error, [line]}
      assert line =~ "20300101000000_new.exs"
      assert line =~ "[remove_column]"
    end

    test "an added overlay migration is red, committed or not", %{dir: dir} do
      path = "projects/demo/priv/repo/migrations/20300101000001_overlay.exs"
      File.write!(Path.join(dir, path), migration("drop table(:example_things)"))

      assert_raise Mix.Error, fn -> run_in(dir, ["--base", "main"]) end
      assert_received {:mix_shell, :error, [line]}
      assert line =~ path

      git!(dir, ["add", "-A"])
      git!(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "overlay"])

      assert_raise Mix.Error, fn -> run_in(dir, ["--base", "main~1"]) end
    end

    test "an edit to a migration already on the base is not 'added'", %{dir: dir} do
      File.write!(
        Path.join(dir, "priv/repo/migrations/20200101000000_old.exs"),
        migration("drop table(:ancient)\ndrop table(:another)")
      )

      run_in(dir, ["--base", "main"])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "0 new migration(s)"
    end

    test "a column's previous type comes from the history", %{dir: dir} do
      File.write!(
        Path.join(dir, "priv/repo/migrations/20200101000001_add.exs"),
        migration("alter table(:posts) do\n  add :views, :integer\nend")
      )

      git!(dir, ["add", "-A"])
      git!(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "add"])

      File.write!(
        Path.join(dir, "priv/repo/migrations/20300101000000_same_type.exs"),
        migration("alter table(:posts) do\n  modify :views, :integer, default: 0\nend")
      )

      run_in(dir, ["--base", "main"])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "1 new migration(s), none breaks"

      File.write!(
        Path.join(dir, "priv/repo/migrations/20300101000000_same_type.exs"),
        migration("alter table(:posts) do\n  modify :views, :bigint\nend")
      )

      assert_raise Mix.Error, fn -> run_in(dir, ["--base", "main"]) end
      assert_received {:mix_shell, :error, [line]}
      assert line =~ "from :integer to :bigint"
    end

    test "--all judges the whole history", %{dir: dir} do
      assert_raise Mix.Error, fn -> run_in(dir, ["--all"]) end
      assert_received {:mix_shell, :error, [line]}
      assert line =~ "20200101000000_old.exs"
    end

    test "a base that does not resolve is an error, not a pass", %{dir: dir} do
      assert_raise Mix.Error, ~r/does not resolve/, fn ->
        run_in(dir, ["--base", "origin/nope"])
      end
    end
  end
end
