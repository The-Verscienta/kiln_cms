defmodule Mix.Tasks.Kiln.Migrations.Check do
  @moduledoc """
  Fails when a new migration would break the release still running during a
  rolling deploy (#1716).

  During a rolling deploy the new release migrates the database while nodes of
  the *old* release are still serving. A migration is only safe if the old code
  keeps working against the new schema. Kiln's policy is **expand → migrate →
  contract across releases**, and it is written out in `docs/releasing.md`
  ("Migrations: expand, migrate, contract"). This task enforces the mechanical
  half of it.

  It reads every migration **added** relative to a base ref (default
  `origin/main`) under `priv/repo/migrations`, `priv/repo/tenant_migrations`
  and the same directories of every overlay under `projects/*/`. Historical
  migrations are never re-judged: only what the diff adds is checked. Ash
  codegen writes the migrations, so this reads the generated files, not the
  resources.

  ## What it flags

  Only the forward direction (`def up` or `def change`) is read; `def down` is
  a rollback and is expected to undo things.

    * `drop table(...)` / `drop_if_exists table(...)` — the old release still
      reads the table.
    * `rename table(...)`, `rename table(...), :col, to: :new` — a rename is a
      drop as far as the old release is concerned.
    * `remove :col` inside `alter table` — the old release still selects it.
    * `modify :col, type` that **changes the type** — the previous type comes
      from `from:` when present, else from the column's last `add`/`modify` in
      the migration history. A column whose previous type cannot be found is
      flagged too, so a human looks.
    * `modify ... null: false` — the old release may still insert `NULL`
      (unless `from:` says the column was already `null: false`).
    * `add ... null: false` without `default:` on an existing table — the old
      release's inserts do not set the column. (Columns of a table created in
      the same statement are fine.)
    * `execute` raw SQL (heuristic, for review) mentioning `DROP TABLE`,
      `DROP COLUMN`, `DROP VIEW`, `DROP SCHEMA`, `DROP TYPE`, `RENAME`,
      `ALTER COLUMN ... TYPE` or `SET NOT NULL`. Dropping and re-creating a
      function or trigger is not flagged.
    * A non-concurrent `create index` / `create unique_index` on a table in
      `large_tables/0` — a plain `CREATE INDEX` blocks writes to the table for
      the whole build.
    * `concurrently: true` in a migration without
      `@disable_ddl_transaction true` — Postgres refuses `CREATE INDEX
      CONCURRENTLY` inside a transaction, so the deploy would fail at boot.
      Not overridable.

  ## Overrides

  An override is explicit, lives in the migration, and names *why* it is safe.
  Put the marker comment on the line directly above the statement it excuses
  (an `alter table` block, an `execute`, a single `remove`), or at the end of
  that statement's first line:

      # kiln:contract-ok since v0.12.0 — nothing reads webhook_endpoints.secret after 0.12.0

  The version is the **release that stopped reading** the old shape. It must
  parse and must not be newer than the project's current version in `mix.exs`
  (that is, it must have shipped), and the reason after the dash must be
  present. A marker covers the flagged operations of the one statement it sits
  on or above — an `alter table` block with three `remove`s is one statement.

  An index build on a large table takes a different marker, since no release
  "stops reading" anything:

      # kiln:lock-ok — table is created empty in this same release

  A marker that is malformed, names an unshipped release, or excuses nothing is
  itself an error, so markers cannot be pasted around as boilerplate.

  ## Usage

      mix kiln.migrations.check                    # added vs origin/main
      mix kiln.migrations.check --base v0.12.0     # added vs another ref
      mix kiln.migrations.check path/to/migration.exs ...
      mix kiln.migrations.check --all              # every migration (history audit)

  `--all` judges the whole history, which predates the policy; it is a report,
  not a gate. The task uses only the standard library and `git`, so it runs
  in a checkout with no `deps/` or `_build/`.
  """
  @shortdoc "Fails on a new migration that breaks the running release (expand/contract)"

  use Mix.Task

  @switches [base: :string, all: :boolean]

  @migration_globs [
    "priv/repo/migrations",
    "priv/repo/tenant_migrations",
    "projects/*/priv/repo/migrations",
    "projects/*/priv/repo/tenant_migrations"
  ]

  # Tables that grow with content, traffic or time. A non-concurrent index
  # build takes a SHARE lock that blocks writes for the length of the build,
  # which on these is long enough to stall editors and API writes mid-deploy.
  # Add a table here when it is expected to reach ~1M rows on a real site.
  @large_tables ~w(
    block_embeddings
    content_links
    content_view_days
    content_views
    document_events
    entries
    entries_versions
    federation_deliveries
    federation_seen_signatures
    form_submissions
    idempotent_requests
    media_derivatives
    media_items
    missed_paths
    notifications
    oban_jobs
    pages
    pages_versions
    posts
    posts_versions
    reference_edges
    referrer_days
    search_queries
    tag_embeddings
    taggings
    throttle_counters
    tokens
    webhook_deliveries
  )

  @contract_marker "kiln:contract-ok"
  @lock_marker "kiln:lock-ok"
  @dash ~S"(?:—|–|--|-)"
  @contract_re Regex.compile!(
                 "^#\\s*kiln:contract-ok\\s+since\\s+v(?<version>\\S+)\\s+#{@dash}\\s+(?<reason>\\S.*?)\\s*$",
                 "u"
               )
  @lock_re Regex.compile!("^#\\s*kiln:lock-ok\\s+#{@dash}\\s+(?<reason>\\S.*?)\\s*$", "u")

  @contract_rules [
    :drop_table,
    :rename,
    :remove_column,
    :type_change,
    :set_not_null,
    :add_not_null,
    :raw_sql
  ]

  @sql_patterns [
    {~r/\bDROP\s+(?:MATERIALIZED\s+)?(?:TABLE|COLUMN|VIEW|SCHEMA|TYPE)\b/i, "DROP"},
    {~r/\bRENAME\b/i, "RENAME"},
    {~r/\bALTER\s+COLUMN\s+\S+\s+(?:SET\s+DATA\s+)?TYPE\b/i, "ALTER COLUMN ... TYPE"},
    {~r/\bSET\s+NOT\s+NULL\b/i, "SET NOT NULL"}
  ]

  @typedoc "One problem in one migration."
  @type finding :: %{
          file: String.t(),
          line: pos_integer(),
          rule: atom(),
          message: String.t()
        }

  @impl Mix.Task
  def run(argv) do
    {opts, paths, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("kiln.migrations.check: unknown option(s) #{inspect(invalid)}")
    end

    all_files = migration_files()

    files =
      cond do
        paths != [] -> Enum.flat_map(paths, &expand_path/1)
        opts[:all] -> all_files
        true -> added_files(opts[:base] || "origin/main")
      end

    version = project_version()
    history = history_index(Enum.uniq(all_files ++ files))

    findings =
      Enum.flat_map(files, fn file ->
        check_source(File.read!(file),
          file: file,
          version: version,
          columns: columns_before(history, file)
        )
      end)

    report(findings, files)
  end

  defp report([], files) do
    Mix.shell().info(
      "kiln.migrations.check: #{length(files)} new migration(s), none breaks the running release."
    )
  end

  defp report(findings, files) do
    shell = Mix.shell()

    Enum.each(findings, fn f ->
      shell.error("#{f.file}:#{f.line}: [#{f.rule}] #{f.message}")
    end)

    Mix.raise("""
    kiln.migrations.check: #{length(findings)} problem(s) in #{length(files)} migration(s).

    A migration must keep the release that is still running working (expand,
    then migrate, then contract in a LATER release). See docs/releasing.md,
    "Migrations: expand, migrate, contract". If the contract step is deliberate
    and the old shape has not been read since a shipped release, say so above
    the statement:

        # kiln:contract-ok since vX.Y.Z — <what stopped reading it, and why it is safe>
    """)
  end

  @doc "Tables whose non-concurrent index builds are flagged."
  @spec large_tables() :: [String.t()]
  def large_tables, do: @large_tables

  ## Discovery

  @doc """
  Every migration file in the checked directories, oldest first (by the
  timestamp prefix, across directories).
  """
  @spec migration_files() :: [String.t()]
  def migration_files do
    @migration_globs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.exs")))
    |> Enum.sort_by(&{Path.basename(&1), &1})
  end

  @doc """
  Migration files added relative to `base`: tracked additions in the working
  tree (committed or not) plus untracked new files.

  A file present on the base and edited here is not "added" — a migration
  that has already run is never re-run, so editing it changes nothing on a
  deployed database.
  """
  @spec added_files(String.t()) :: [String.t()]
  def added_files(base) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", base <> "^{commit}"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        Mix.raise(
          "kiln.migrations.check: base ref #{inspect(base)} does not resolve. " <>
            "Fetch it (git fetch origin main) or pass --base <ref>."
        )
    end

    pathspecs = Enum.map(@migration_globs, &Path.join(&1, "*.exs"))

    {diff, 0} =
      System.cmd(
        "git",
        ["diff", "--name-only", "--no-renames", "--diff-filter=A", base, "--" | pathspecs]
      )

    {untracked, 0} =
      System.cmd("git", ["ls-files", "--others", "--exclude-standard", "--" | pathspecs])

    (String.split(diff, "\n", trim: true) ++ String.split(untracked, "\n", trim: true))
    |> Enum.filter(&migration_path?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{Path.basename(&1), &1})
  end

  defp migration_path?(path) do
    dir = Path.dirname(path)
    String.ends_with?(path, ".exs") and Enum.any?(@migration_globs, &glob_match?(&1, dir))
  end

  defp glob_match?(glob, dir) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*", "[^/]+")

    Regex.match?(~r/^#{pattern}$/, dir)
  end

  defp expand_path(path) do
    if File.dir?(path), do: Path.wildcard(Path.join(path, "*.exs")) |> Enum.sort(), else: [path]
  end

  @doc "The project's version from `mix.exs` in the current directory."
  @spec project_version() :: Version.t()
  def project_version do
    with {:ok, source} <- File.read("mix.exs"),
         [_, version] <- Regex.run(~r/(?:@version|version:)\s+"([^"]+)"/, source),
         {:ok, parsed} <- Version.parse(version) do
      parsed
    else
      _ -> Mix.raise("kiln.migrations.check: cannot read the project version from mix.exs")
    end
  end

  ## Column history (for type-change detection)

  # %{basename_sort_key => [{table, column, type_string}]}, in file order.
  defp history_index(files) do
    files
    |> Enum.sort_by(&{Path.basename(&1), &1})
    |> Enum.map(fn file -> {Path.basename(file), column_events(File.read!(file))} end)
  end

  @doc """
  The `%{{table, column} => type}` state the migrations in `files` leave
  behind before `file` runs (ordered by timestamp prefix across directories).
  """
  @spec columns_before_file(Path.t(), [Path.t()]) :: %{{String.t(), String.t()} => String.t()}
  def columns_before_file(file, files \\ migration_files()) do
    files |> Enum.concat([file]) |> Enum.uniq() |> history_index() |> columns_before(file)
  end

  defp columns_before(history, file) do
    base = Path.basename(file)

    history
    |> Enum.take_while(fn {name, _} -> name < base end)
    |> Enum.reduce(%{}, fn {_, events}, acc ->
      Enum.reduce(events, acc, fn
        {:set, table, column, type, _line}, acc -> Map.put(acc, {table, column}, type)
        {:drop_table, table, _line}, acc -> Map.reject(acc, fn {{t, _}, _} -> t == table end)
        {:create_table, _table, _line}, acc -> acc
      end)
    end)
  end

  @doc """
  The schema events a migration's forward direction declares, in source
  order: `{:create_table, table, line}`, `{:set, table, column, type, line}`
  (an `add` or `modify`) and `{:drop_table, table, line}`. Used to find a
  column's previous type, and which tables are new.
  """
  @spec column_events(String.t()) :: [tuple()]
  def column_events(source) do
    case parse(source) do
      {:ok, ast, _comments} -> ast |> forward_bodies() |> Enum.flat_map(&events(&1, nil))
      :error -> []
    end
  end

  defp events({op, meta, [table_ast, [{:do, block} | _]]}, _table)
       when op in [:create, :create_if_not_exists, :alter] do
    case table_name(table_ast) do
      nil ->
        []

      table when op == :alter ->
        events(block, table)

      table ->
        [{:create_table, table, meta[:line] || 0} | events(block, table)]
    end
  end

  defp events({op, meta, [{:table, _, _} = t | _]}, _) when op in [:drop, :drop_if_exists] do
    case table_name(t) do
      nil -> []
      table -> [{:drop_table, table, meta[:line] || 0}]
    end
  end

  defp events({op, meta, [col, type | _]}, table)
       when op in [:add, :add_if_not_exists, :modify] and is_binary(table) and is_atom(col) do
    [{:set, table, Atom.to_string(col), type_string(type), meta[:line] || 0}]
  end

  defp events({:__block__, _, stmts}, table), do: Enum.flat_map(stmts, &events(&1, table))
  defp events(_, _), do: []

  ## Checking one migration

  @doc """
  Every problem in one migration's source.

  Options: `:file` (for messages), `:version` (the project's current
  `Version`, bounding a marker's `since`), `:columns` (the
  `%{{table, column} => type}` state before this migration; unknown columns
  make a `modify` without `from:` suspicious), `:large_tables`.
  """
  @spec check_source(String.t(), keyword()) :: [finding()]
  def check_source(source, opts) do
    file = Keyword.get(opts, :file, "migration.exs")

    case parse(source) do
      {:ok, ast, comments} ->
        bodies = forward_bodies(ast)
        own = Enum.flat_map(bodies, &events(&1, nil))

        ctx = %{
          file: file,
          columns: Keyword.get(opts, :columns, %{}),
          own_events: own,
          new_tables: Map.new(for({:create_table, t, _} <- own, do: {t, true})),
          large: Keyword.get(opts, :large_tables, @large_tables),
          no_transaction?: disables_ddl_transaction?(ast)
        }

        raw = Enum.flat_map(bodies, &walk(&1, nil, ctx))
        units = Enum.flat_map(bodies, &units/1)

        {markers, marker_errors} =
          markers(comments, file, Keyword.get(opts, :version, Version.parse!("0.0.0")))

        apply_markers(raw, markers, units, file) ++ marker_errors

      :error ->
        [%{file: file, line: 1, rule: :unparseable, message: "the migration does not parse"}]
    end
    |> Enum.sort_by(&{&1.line, &1.rule})
  end

  defp parse(source) do
    case Code.string_to_quoted_with_comments(source,
           token_metadata: true,
           columns: false,
           emit_warnings: false
         ) do
      {:ok, ast, comments} -> {:ok, ast, comments}
      _ -> :error
    end
  end

  # The bodies of `def up` and `def change` — the forward direction.
  defp forward_bodies(ast) do
    {_, bodies} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{name, _, args}, [{:do, body} | _]]} = node, acc
        when name in [:up, :change] and (args == [] or is_nil(args)) ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(bodies)
  end

  defp disables_ddl_transaction?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{:disable_ddl_transaction, _, [true]}]} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  ## The walk

  # `table` is nil at the top level, `{:create, name}` inside `create table`
  # and `{:alter, name}` inside `alter table`.
  # A table whose name is not a literal (`alter table(name)` in a `for`) is
  # still checked, as "?".
  defp walk({op, _meta, [{:table, _, _} = table_ast, [{:do, block} | _]]}, _table, ctx)
       when op in [:create, :create_if_not_exists, :alter] do
    walk(block, {kind(op), table_name(table_ast) || "?"}, ctx)
  end

  defp walk({op, meta, [{index, _, [t | rest]}]}, _table, ctx)
       when op in [:create, :create_if_not_exists] and index in [:index, :unique_index] do
    index_findings(meta, table_name_value(t), List.last(rest), ctx)
  end

  defp walk({op, meta, [{:table, _, _} = t | _]}, _table, ctx)
       when op in [:drop, :drop_if_exists] do
    [
      finding(ctx, meta, :drop_table, "drops table #{inspect(table_name(t))}",
        hint: "the running release still reads it; drop it in a later release"
      )
    ]
  end

  defp walk({:rename, meta, [{:table, _, _} = t, [to: to]]}, _table, ctx) do
    [
      finding(
        ctx,
        meta,
        :rename,
        "renames table #{inspect(table_name(t))} to #{inspect(table_name(to))}",
        hint: "add the new table, backfill, and drop the old one a release later"
      )
    ]
  end

  defp walk({:rename, meta, [{:table, _, _} = t, col, [to: to]]}, _table, ctx) do
    [
      finding(
        ctx,
        meta,
        :rename,
        "renames column #{inspect(table_name(t))}.#{col} to #{to}",
        hint: "add the new column, backfill, and drop the old one a release later"
      )
    ]
  end

  defp walk({op, meta, [col | _]}, {:alter, table}, ctx)
       when op in [:remove, :remove_if_exists] do
    [
      finding(ctx, meta, :remove_column, "removes column #{table}.#{col}",
        hint: "the running release still selects it; remove it in a later release"
      )
    ]
  end

  # A table created in this same migration has no reader in the running
  # release, so adding to or reshaping it cannot break one. (Dropping or
  # renaming it is still reported: rare, and worth a look.)
  defp walk({op, _meta, _args}, {:alter, table}, ctx)
       when op in [:modify, :add, :add_if_not_exists] and is_map_key(ctx.new_tables, table),
       do: []

  defp walk({:modify, meta, [col, type | rest]}, {:alter, table}, ctx) do
    opts = keyword(List.first(rest))
    modify_findings(ctx, meta, table, col, type, opts)
  end

  defp walk({op, meta, [col, _type | rest]}, {:alter, table}, ctx)
       when op in [:add, :add_if_not_exists] do
    opts = keyword(List.first(rest))

    if Keyword.get(opts, :null) == false and not Keyword.has_key?(opts, :default) do
      [
        finding(ctx, meta, :add_not_null, "adds #{table}.#{col} as NOT NULL with no default",
          hint:
            "the running release's inserts do not set it; add a default, or add it " <>
              "nullable, backfill, and tighten it a release later"
        )
      ]
    else
      []
    end
  end

  defp walk({:execute, meta, [sql | _]}, _table, ctx) do
    sql
    |> sql_text()
    |> then(fn text ->
      for {re, label} <- @sql_patterns, Regex.match?(re, text) do
        finding(ctx, meta, :raw_sql, "raw SQL contains #{label} (heuristic — review it)",
          hint:
            "if it drops, renames or retypes something the running release reads, it " <>
              "belongs in a later release"
        )
      end
    end)
  end

  defp walk({:__block__, _, stmts}, table, ctx), do: Enum.flat_map(stmts, &walk(&1, table, ctx))

  defp walk({_, _, args}, table, ctx) when is_list(args),
    do: Enum.flat_map(args, &walk(&1, table, ctx))

  defp walk(list, table, ctx) when is_list(list), do: Enum.flat_map(list, &walk(&1, table, ctx))
  defp walk({a, b}, table, ctx), do: walk(a, table, ctx) ++ walk(b, table, ctx)
  defp walk(_, _, _), do: []

  defp kind(:alter), do: :alter
  defp kind(_), do: :create

  defp modify_findings(ctx, meta, table, col, type, opts) do
    {from_type, from_opts} =
      case Keyword.fetch(opts, :from) do
        {:ok, {t, from_opts}} when is_list(from_opts) -> {type_string(t), from_opts}
        {:ok, t} -> {type_string(t), []}
        :error -> {previous_type(ctx, table, to_string(col), meta[:line] || 0), []}
      end

    new_type = type_string(type)

    type_finding =
      cond do
        is_nil(from_type) ->
          [
            finding(
              ctx,
              meta,
              :type_change,
              "modifies #{table}.#{col} to #{new_type}, and its previous type is unknown",
              hint: "add `from:` or check it is not a type change the running release cannot read"
            )
          ]

        from_type != new_type ->
          [
            finding(
              ctx,
              meta,
              :type_change,
              "changes #{table}.#{col} from #{from_type} to #{new_type}",
              hint: "add a new column of the new type, backfill, and drop the old one later"
            )
          ]

        true ->
          []
      end

    null_finding =
      if Keyword.get(opts, :null) == false and Keyword.get(from_opts, :null) != false do
        [
          finding(ctx, meta, :set_not_null, "makes #{table}.#{col} NOT NULL",
            hint:
              "the running release may still write NULL; tighten it in the release " <>
                "after the one that always sets it (and backfill first)"
          )
        ]
      else
        []
      end

    type_finding ++ null_finding
  end

  defp previous_type(ctx, table, column, line) do
    own =
      for {:set, ^table, ^column, type, l} <- ctx.own_events, l < line, do: type

    List.last(own) || Map.get(ctx.columns, {table, column})
  end

  defp index_findings(meta, table, opts, ctx) do
    opts = keyword(opts)
    concurrent? = Keyword.get(opts, :concurrently) == true
    new_table? = Map.has_key?(ctx.new_tables, table)

    cond do
      concurrent? and not ctx.no_transaction? ->
        [
          finding(
            ctx,
            meta,
            :concurrent_in_transaction,
            "builds an index concurrently without `@disable_ddl_transaction true`",
            hint:
              "Postgres refuses CREATE INDEX CONCURRENTLY in a transaction; the deploy " <>
                "would fail at boot"
          )
        ]

      not concurrent? and not new_table? and table in ctx.large ->
        [
          finding(
            ctx,
            meta,
            :index_on_large_table,
            "builds an index on large table #{table} without `concurrently: true`",
            hint:
              "a plain CREATE INDEX blocks writes for the whole build; use " <>
                "`concurrently: true` in custom_indexes (or `mix ash.codegen <name> --concurrent-indexes`)"
          )
        ]

      true ->
        []
    end
  end

  defp finding(ctx, meta, rule, message, hint: hint) do
    %{file: ctx.file, line: meta[:line] || 1, rule: rule, message: "#{message} — #{hint}"}
  end

  ## Markers

  # A statement a marker can bind to: {start_line, end_line}.
  defp units(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          if meta[:line], do: {node, [{meta[:line], end_line(node)} | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp end_line(node) do
    {_, max} =
      Macro.prewalk(node, 0, fn
        {_, meta, _} = n, acc when is_list(meta) ->
          lines =
            [
              meta[:line],
              get_in(meta, [:end, :line]),
              get_in(meta, [:closing, :line]),
              get_in(meta, [:end_of_expression, :line])
            ]
            |> Enum.filter(&is_integer/1)

          {n, Enum.max([acc | lines])}

        n, acc ->
          {n, acc}
      end)

    max
  end

  defp markers(comments, file, version) do
    comments
    |> Enum.filter(&(&1.text =~ @contract_marker or &1.text =~ @lock_marker))
    |> Enum.map(&parse_marker(&1, file, version))
    |> Enum.split_with(&match?({:marker, _, _}, &1))
    |> then(fn {ok, errors} -> {ok, Enum.map(errors, fn {:error, f} -> f end)} end)
  end

  defp parse_marker(%{line: line, text: text}, file, version) do
    text = String.trim(text)

    cond do
      text =~ @contract_marker ->
        with %{"version" => v} <- Regex.named_captures(@contract_re, text),
             {:ok, since} <- Version.parse(v) do
          if Version.compare(since, version) == :gt do
            {:error,
             %{
               file: file,
               line: line,
               rule: :marker_unshipped,
               message:
                 "marker names v#{since}, which has not shipped (mix.exs is at #{version}) — " <>
                   "name the release that stopped reading the old shape"
             }}
          else
            {:marker, :contract, line}
          end
        else
          _ -> {:error, malformed(file, line, "# kiln:contract-ok since vX.Y.Z — <reason>")}
        end

      Regex.match?(@lock_re, text) ->
        {:marker, :lock, line}

      true ->
        {:error, malformed(file, line, "# kiln:lock-ok — <reason>")}
    end
  end

  defp malformed(file, line, shape) do
    %{
      file: file,
      line: line,
      rule: :malformed_marker,
      message: "malformed override marker — the shape is `#{shape}`"
    }
  end

  defp apply_markers(findings, markers, units, file) do
    bound =
      Enum.map(markers, fn {:marker, kind, line} ->
        unit =
          units
          |> Enum.filter(fn {start, _} -> start >= line end)
          |> Enum.sort_by(fn {start, stop} -> {start, -stop} end)
          |> List.first()

        {kind, line, unit}
      end)

    remaining =
      Enum.reject(findings, fn f ->
        Enum.any?(bound, fn {kind, _line, unit} -> covers?(kind, unit, f) end)
      end)

    unused =
      for {kind, line, unit} <- bound, not Enum.any?(findings, &covers?(kind, unit, &1)) do
        %{
          file: file,
          line: line,
          rule: :unused_marker,
          message:
            "override marker excuses nothing — put it directly above the statement it " <>
              "covers, or delete it"
        }
      end

    remaining ++ unused
  end

  defp covers?(_kind, nil, _finding), do: false

  defp covers?(:contract, {start, stop}, f),
    do: f.rule in @contract_rules and f.line >= start and f.line <= stop

  defp covers?(:lock, {start, stop}, f),
    do: f.rule == :index_on_large_table and f.line >= start and f.line <= stop

  ## AST helpers

  defp table_name({:table, _, [name | _]}), do: table_name_value(name)
  defp table_name(_), do: nil

  defp table_name_value(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp table_name_value(name) when is_binary(name), do: name
  defp table_name_value(_), do: nil

  defp keyword(list) when is_list(list) do
    if Enum.all?(list, &match?({k, _} when is_atom(k), &1)), do: list, else: []
  end

  defp keyword(_), do: []

  # `references(:t, type: :uuid)` is a :uuid column; the constraint is not the type.
  defp type_string({:references, _, [_table | rest]}) do
    rest |> List.first() |> keyword() |> Keyword.get(:type, :bigint) |> type_string()
  end

  defp type_string(type) when is_atom(type), do: inspect(type)
  defp type_string(type), do: Macro.to_string(type)

  # The literal text of an `execute` argument; interpolations contribute their
  # literal parts, and anything not a string contributes nothing.
  defp sql_text(sql) when is_binary(sql), do: sql

  defp sql_text({:<<>>, _, parts}),
    do: parts |> Enum.filter(&is_binary/1) |> Enum.join(" ")

  defp sql_text({sigil, _, [{:<<>>, _, parts}, _]}) when sigil in [:sigil_S, :sigil_s],
    do: parts |> Enum.filter(&is_binary/1) |> Enum.join(" ")

  defp sql_text(_), do: ""
end
