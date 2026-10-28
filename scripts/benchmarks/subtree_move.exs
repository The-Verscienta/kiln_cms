# Subtree-move benchmark (#1903): what moving a section with a large subtree
# costs, on a type with many rows.
#
#   MIX_ENV=prod mix run scripts/benchmarks/subtree_move.exs
#
# Normally run by `subtree_move.sh`, against its OWN throwaway database (it
# refuses any database not named `kiln_cms_bench*`).
#
# Setup, per leg (one per BENCH_SUBTREES value):
#
#   * one dynamic type with `alias_pattern: "/[ancestors]/[slug]"` — the
#     pattern a move re-derives — holding BENCH_ROWS documents in all;
#   * a section whose subtree is BENCH_SUBTREE documents: children of 100
#     each, two levels deep below the section (a 1,000 subtree is the
#     section, 10 children and 990 grandchildren);
#   * every alias set to what the pattern derives for where it sits, so the
#     move finds a derived (not pinned) alias on every row and rewrites it.
#
# Bulk rows are cloned from one document created through the domain actions,
# with SQL, so a 50,000-row type takes seconds rather than an hour. They are
# drafts: a draft's rewrite records a redirect and a version but fires no
# artifact, so the numbers are the job's own and not the firing queue's.
#
# Then the section is re-parented under another root (SQL, as the move action
# would) and `KilnCMS.CMS.Workers.RegenerateSubtreeAliases.perform/1` runs
# in a task, as Oban would run it. Measured:
#
#   * job wall time;
#   * aliases rewritten and `Redirect` rows written;
#   * Repo queries the job's process issued, and their total time;
#   * the job process's peak memory (sampled every 2 ms) and the BEAM's;
#   * the subtree read alone, both ways: the whole-type `(id, parent_id,
#     slug)` read the job did before #1903, and the recursive CTE it does now.
#
# Environment (all optional):
#   BENCH_ROWS       documents of the type in all, per leg (50000)
#   BENCH_SUBTREES   comma list of subtree sizes, one leg each (100,1000,10000)
#   BENCH_OUT        results JSON path (subtree-move-results.json)

alias KilnCMS.Accounts
alias KilnCMS.Accounts.User
alias KilnCMS.CMS
alias KilnCMS.CMS.ContentTree
alias KilnCMS.CMS.Workers.RegenerateSubtreeAliases
alias KilnCMS.Repo

db = Repo.config()[:database] || ""

unless String.starts_with?(db, "kiln_cms_bench") do
  Mix.raise(
    "Refusing to run against #{inspect(db)}: the benchmark only writes to kiln_cms_bench*"
  )
end

defmodule SubtreeBench do
  def int(name, default), do: name |> System.get_env("#{default}") |> String.to_integer()

  def list(name, default),
    do:
      name
      |> System.get_env(default)
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))

  def ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  def timed(fun) do
    t0 = System.monotonic_time()
    result = fun.()
    {ms(System.monotonic_time() - t0), result}
  end

  # Every column of `entries` but the ones a clone sets itself.
  def clone_columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_name = 'entries' AND is_generated = 'NEVER'
      ORDER BY ordinal_position
      """)

    rows
    |> List.flatten()
    |> Enum.reject(&(&1 in ~w(id slug title path_alias parent_id position)))
    |> Enum.map_join(", ", &~s("#{&1}"))
  end

  # `count` clones of `template`, slugs `<prefix>-1..count`, each under
  # `parent_sql` (an SQL expression over `g`, the series index) with the alias
  # `alias_sql` would derive. Returns nothing; read back by slug prefix.
  def clone!(template_id, prefix, count, parent_sql, alias_sql, extra \\ []) do
    cols = clone_columns()

    Repo.query!(
      """
      INSERT INTO entries (id, slug, title, path_alias, parent_id, position, #{cols})
      SELECT gen_random_uuid(), $2 || '-' || g, $2 || ' ' || g, #{alias_sql}, #{parent_sql}, g, #{cols}
      FROM entries, generate_series(1, $3) AS g
      WHERE entries.id = $1
      """,
      [Ecto.UUID.dump!(template_id), prefix, count | extra],
      timeout: :infinity
    )
  end

  def ids_by_prefix(prefix) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM entries WHERE slug LIKE $1 ORDER BY position", [prefix <> "-%"])

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  def count(sql, params \\ []) do
    %{rows: [[n]]} = Repo.query!(sql, params)
    n
  end
end

defmodule SubtreeBench.Queries do
  @handler "subtree-bench-repo"

  def attach do
    :ets.new(:sb_repo, [:named_table, :public, :set])

    :telemetry.attach(@handler, [:kiln_cms, :repo, :query], &__MODULE__.handle/4, nil)
  end

  def handle(_event, measurements, _meta, _config) do
    key = self()
    total = Map.get(measurements, :total_time, 0)
    :ets.update_counter(:sb_repo, key, [{2, 1}, {3, total}], {key, 0, 0})
  end

  def for_pid(pid) do
    case :ets.lookup(:sb_repo, pid) do
      [{_, n, time}] -> {n, SubtreeBench.ms(time)}
      [] -> {0, 0.0}
    end
  end
end

alias SubtreeBench, as: B

Code.ensure_loaded!(ContentTree)

rows_total = B.int("BENCH_ROWS", 50_000)
subtrees = B.list("BENCH_SUBTREES", "100,1000,10000")
out = System.get_env("BENCH_OUT", "subtree-move-results.json")

tenant = Accounts.default_org_id()

admin =
  Ash.Seed.seed!(User, %{
    email: "subtree-bench-#{System.unique_integer([:positive])}@kiln.test",
    name: "Bench Admin",
    hashed_password: Bcrypt.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(24))),
    confirmed_at: DateTime.utc_now(),
    role: :admin
  })

SubtreeBench.Queries.attach()

results =
  for {size, leg} <- Enum.with_index(subtrees, 1) do
    type =
      CMS.create_type_definition!(
        %{name: "tree#{leg}", label: "Tree #{leg}", alias_pattern: "/[ancestors]/[slug]"},
        actor: admin,
        tenant: tenant
      )

    template =
      CMS.create_entry!(
        %{type_definition_id: type.id, title: "Template", slug: "template-#{leg}"},
        actor: admin,
        tenant: tenant
      )

    p = "l#{leg}"

    # Two roots: where the section is now and where it moves to.
    B.clone!(template.id, "#{p}from", 1, "NULL", "'/' || $2 || '-' || g")
    B.clone!(template.id, "#{p}to", 1, "NULL", "'/' || $2 || '-' || g")
    [from] = B.ids_by_prefix("#{p}from")
    [to] = B.ids_by_prefix("#{p}to")

    # The section, under `from`.
    B.clone!(template.id, "#{p}sec", 1, "'#{from}'::uuid", "'/#{p}from-1/' || $2 || '-' || g")
    [section] = B.ids_by_prefix("#{p}sec")

    # Children of 100 each: `size - 1` documents below the section.
    below = size - 1
    children = min(div(below + 100, 101), below)
    grandchildren = below - children

    B.clone!(
      template.id,
      "#{p}c",
      children,
      "'#{section}'::uuid",
      "'/#{p}from-1/#{p}sec-1/' || $2 || '-' || g"
    )

    child_ids = B.ids_by_prefix("#{p}c")

    if grandchildren > 0 do
      # Grandchild g sits under child ((g - 1) % children) + 1.
      B.clone!(
        template.id,
        "#{p}g",
        grandchildren,
        "($4::uuid[])[((g - 1) % #{children}) + 1]",
        "'/#{p}from-1/#{p}sec-1/#{p}c-' || (((g - 1) % #{children}) + 1) || '/' || $2 || '-' || g",
        [Enum.map(child_ids, &Ecto.UUID.dump!/1)]
      )
    end

    # Pad the type to `rows_total` with unrelated roots.
    padding = max(rows_total - size - 3, 0)
    if padding > 0, do: B.clone!(template.id, "#{p}bg", padding, "NULL", "'/' || $2 || '-' || g")

    # The roots and the subtree are published, as a live docs section is: a
    # published record's path change records a 301 and re-fires its artifact.
    # The padding stays draft.
    Repo.query!(
      "UPDATE entries SET state = 'published', published_at = now() WHERE slug ~ $1",
      ["^#{p}(from|to|sec|c|g)-"],
      timeout: :infinity
    )

    Repo.query!("ANALYZE entries")

    type_rows =
      B.count("SELECT count(*) FROM entries WHERE type_definition_id = $1", [
        Ecto.UUID.dump!(type.id)
      ])

    # The read alone, both ways.
    {whole_ms, whole} =
      B.timed(fn ->
        KilnCMS.CMS.Entry
        |> Ash.Query.select([:id, :parent_id, :slug])
        |> Ash.read!(authorize?: false, tenant: tenant, timeout: :infinity)
      end)

    # `ContentTree.subtree/3` is #1903's; before it there is no CTE to time,
    # which is how this script measures a build from before the change.
    {cte_ms, _cte} =
      if function_exported?(ContentTree, :subtree, 3) do
        B.timed(fn -> ContentTree.subtree(KilnCMS.CMS.Entry, section, tenant) end)
      else
        {nil, nil}
      end

    # The move itself, as the action would write it, then the job.
    Repo.query!("UPDATE entries SET parent_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(to),
      Ecto.UUID.dump!(section)
    ])

    redirects_before = B.count("SELECT count(*) FROM redirects")
    beam_before = :erlang.memory(:total)

    job = %Oban.Job{
      args: %{
        "kind" => type.name,
        "id" => section,
        "org_id" => tenant,
        "old_parent_id" => from
      }
    }

    t0 = System.monotonic_time()
    task = Task.async(fn -> RegenerateSubtreeAliases.perform(job) end)

    peak =
      Stream.repeatedly(fn ->
        case Process.info(task.pid, :memory) do
          {:memory, bytes} ->
            Process.sleep(2)
            {bytes, :erlang.memory(:total)}

          nil ->
            nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.reduce({0, 0}, fn {p, b}, {mp, mb} -> {max(p, mp), max(b, mb)} end)

    :ok = Task.await(task, :infinity)
    wall_ms = B.ms(System.monotonic_time() - t0)
    {queries, query_ms} = SubtreeBench.Queries.for_pid(task.pid)

    rewritten =
      B.count("SELECT count(*) FROM entries WHERE path_alias LIKE $1", ["/#{p}to-1/#{p}sec-1%"])

    redirects = B.count("SELECT count(*) FROM redirects") - redirects_before

    # The re-fires and index updates the rewrites enqueued, which run after the
    # job in Oban: how long until every queue is idle again.
    drain_ms =
      Stream.repeatedly(fn ->
        Process.sleep(100)

        B.count("SELECT count(*) FROM oban_jobs WHERE state IN ('available', 'executing')")
      end)
      # Ten minutes at most; a queue that never empties is reported as that.
      |> Stream.take(6_000)
      |> Enum.find(&(&1 == 0))
      |> then(fn _ -> B.ms(System.monotonic_time() - t0) end)

    {proc_peak, beam_peak} = peak

    result = %{
      subtree: size,
      type_rows: type_rows,
      whole_type_read_ms: whole_ms,
      whole_type_rows: length(whole),
      cte_read_ms: cte_ms,
      job_ms: wall_ms,
      drained_ms: drain_ms,
      aliases_rewritten: rewritten,
      redirects: redirects,
      queries: queries,
      query_ms: query_ms,
      job_peak_mb: proc_peak / 1_048_576,
      beam_growth_mb: max(beam_peak - beam_before, 0) / 1_048_576,
      per_row_ms: wall_ms / size,
      commit: System.get_env("BENCH_COMMIT")
    }

    # The padding goes, so the next leg's type is `rows_total` again rather
    # than stacking on this one's: before #1903 the job read every row of the
    # `entries` table, every dynamic type's, so leftovers would inflate it.
    # The clones were never versioned or redirected, so nothing points at them.
    Repo.query!("DELETE FROM entries WHERE slug LIKE $1", ["#{p}bg-%"], timeout: :infinity)

    IO.puts(:stderr, "leg #{leg}: #{inspect(result)}")
    result
  end

File.write!(out, Jason.encode!(results, pretty: true))

f = fn
  nil -> "–"
  v when is_float(v) -> :erlang.float_to_binary(v, decimals: 1)
  v -> to_string(v)
end

IO.puts("""
| Subtree | Type rows | Whole-type read (rows / ms) | Subtree CTE (ms) | Job (ms) | Per row (ms) | Queues idle (ms) | Aliases rewritten | Redirects | Queries | Query ms | Job peak (MB) | BEAM growth (MB) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|\
""")

for r <- results do
  IO.puts(
    "| #{r.subtree} | #{r.type_rows} | #{r.whole_type_rows} / #{f.(r.whole_type_read_ms)} | #{f.(r.cte_read_ms)} | #{f.(r.job_ms)} | #{f.(r.per_row_ms)} | #{f.(r.drained_ms)} | #{r.aliases_rewritten} | #{r.redirects} | #{r.queries} | #{f.(r.query_ms)} | #{f.(r.job_peak_mb)} | #{f.(r.beam_growth_mb)} |"
  )
end
