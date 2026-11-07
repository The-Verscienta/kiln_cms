# Custom-field filters and sorts at scale (#2291): what a GIN index on
# `custom_fields` buys `custom_filter` / `custom_sort`, and what it costs.
#
#     MIX_ENV=test MIX_TEST_PARTITION=_bench_cf mix ash.setup
#     CF_VARIANT=a MIX_ENV=test MIX_TEST_PARTITION=_bench_cf mix run --no-start scripts/benchmarks/custom_fields_index.exs
#     CF_VARIANT=b MIX_ENV=test MIX_TEST_PARTITION=_bench_cf mix run --no-start scripts/benchmarks/custom_fields_index.exs
#     dropdb kiln_cms_test_bench_cf   # when done
#
# Variants (the index is created or dropped by the script, in the bench
# database only; the predicate is whatever `custom_field_query.ex` builds):
#
#   a  no index on `custom_fields`
#   b  GIN `jsonb_path_ops` index present
#
# Run b on the old `->` predicate (before #2291) and on the containment
# predicate to get the issue's three variants. Refuses any database whose name
# does not contain "bench".
#
# Seeds N pages and N entries (CF_ROWS, default 100_000) in SQL, cloned from a
# row the domain created, over 5 tenants (one holds 80%), with 5% of rows
# carrying the wrong types / lacking the keys. Knobs: CF_ROWS, CF_RUNS (200),
# CF_WRITE_ROWS (20_000), CF_WRITE_UPDATES (200).

# The test config pools through the SQL sandbox, which drops a connection its
# owner has held for 120 s: a long bench would die mid-run. Start the app on a
# plain pool instead (hence `--no-start`).
repo_config = Application.fetch_env!(:kiln_cms, KilnCMS.Repo)

Application.put_env(
  :kiln_cms,
  KilnCMS.Repo,
  repo_config |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 10)
)

{:ok, _} = Application.ensure_all_started(:kiln_cms)
Logger.configure(level: :warning)

alias KilnCMS.CMS
alias KilnCMS.Repo

env_int = fn name, default -> String.to_integer(System.get_env(name, to_string(default))) end

rows_n = env_int.("CF_ROWS", 100_000)
runs = env_int.("CF_RUNS", 200)
write_rows = env_int.("CF_WRITE_ROWS", 20_000)
write_updates = env_int.("CF_WRITE_UPDATES", 200)
variant = System.get_env("CF_VARIANT", "a")

database = Repo.config()[:database]
String.contains?(database, "bench") || raise "refusing to seed #{database}: not a bench database"

admin =
  Ash.Seed.seed!(KilnCMS.Accounts.User, %{
    email: "cf-bench-#{System.unique_integer([:positive])}@example.com",
    hashed_password: Bcrypt.hash_pwd_salt("password123456"),
    confirmed_at: DateTime.utc_now(),
    role: :admin
  })

q = fn sql, params -> Repo.query!(sql, params, timeout: :infinity) end

# --- seed ---------------------------------------------------------------------

[[seeded]] = q.("SELECT count(*) FROM pages WHERE slug LIKE 'cfb-%'", []).rows

existing = q.("SELECT id::text FROM organizations WHERE slug LIKE 'cfb-%' ORDER BY slug", []).rows

orgs =
  if existing != [] do
    List.flatten(existing)
  else
    for n <- 1..5 do
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "CF bench #{n}",
        slug: "cfb-#{n}",
        status: :active
      }).id
    end
  end

[big, small | rest_orgs] = orgs

fields = [
  {"sku", :string, %{}},
  {"grade", :string, %{}},
  {"featured", :boolean, %{}},
  {"price", :integer, %{}},
  {"released", :date, %{}},
  {"color", :string, %{}},
  {"props", :select, %{multiple: true, options: Enum.map(0..11, &"p#{&1}") ++ ["rare"]}},
  {"hero", :media, %{}}
]

type_for = fn org ->
  CMS.create_type_definition!(%{name: "cfbench", label: "CF bench"}, actor: admin, tenant: org)
end

if seeded == 0 do
  t0 = System.monotonic_time(:millisecond)

  # The registry is what `custom_filter` resolves names against, so the two
  # measured tenants each get a definition per field, on pages and on entries.
  types =
    for org <- [big, small], into: %{} do
      type = type_for.(org)
      opts = [actor: admin, tenant: org]

      for {name, field_type, extra} <- fields do
        base = %{label: name, name: name, field_type: field_type}
        CMS.create_field_definition!(Map.merge(base, Map.put(extra, :content_type, :page)), opts)

        CMS.create_field_definition!(
          Map.merge(base, Map.put(extra, :type_definition_id, type.id)),
          opts
        )
      end

      page = CMS.create_page!(%{title: "T", slug: "cfb-template-#{org}"}, opts)
      CMS.publish_page!(page, %{}, opts)

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          type.name,
          %{title: "T", slug: "cfb-template-#{org}"},
          opts
        )

      CMS.publish_entry!(entry, %{}, opts)
      {org, %{type: type.id, page: page.id, entry: entry.id}}
    end

  columns = fn table ->
    q.(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND is_generated = 'NEVER'
      ORDER BY ordinal_position
      """,
      [table]
    ).rows
    |> List.flatten()
  end

  props =
    "jsonb_build_array('p' || (g % 12), 'p' || ((g / 12) % 12)" <>
      " || CASE WHEN g % 5000 = 0 THEN ',rare' ELSE '' END)"

  props =
    "(CASE WHEN g % 5000 = 0 THEN jsonb_build_array('rare', 'p' || (g % 12)) ELSE #{props} END)"

  colors = Enum.map_join(~w(red green blue cyan teal plum gold rose lime sand navy mint
                            ruby jade onyx fawn pink grey amber coal), ",", &"'#{&1}'")

  good = """
  jsonb_build_object(
    'sku', 'sku-' || g,
    'grade', CASE WHEN g % 10 < 3 THEN 'A' WHEN g % 10 < 6 THEN 'B' ELSE 'C' || (g % 7) END,
    'featured', (g % 2 = 0),
    'price', (g * 7919) % 10000,
    'released', to_char(date '2020-01-01' + (g % 2000), 'YYYY-MM-DD'),
    'color', (ARRAY[#{colors}])[1 + g % 20],
    'props', #{props},
    'hero', jsonb_build_object('id', md5(g::text)::uuid, 'filename', 'x.png'))
  """

  # 5% of rows: wrong types, most keys absent.
  bad = "jsonb_build_object('price', 'n/a', 'sku', g, 'featured', 'yes')"
  custom = "CASE WHEN g % 20 = 0 THEN #{bad} ELSE #{good} END"

  # 80% big tenant, the rest spread over the others.
  org_pick = fn small_ids ->
    others = Enum.map_join(small_ids, ",", &"'#{&1}'::uuid")

    "CASE WHEN g % 100 < 80 THEN '#{big}'::uuid ELSE (ARRAY[#{others}])[1 + g % #{length(small_ids)}] END"
  end

  for {table, kind} <- [{"pages", :page}, {"entries", :entry}] do
    cols = columns.(table)

    # Entries need a type definition of their own org; the filler tenants
    # borrow the big one's (the column has no cross-org check).
    {tpl, type} = {types[big][kind], types[big].type}

    exprs =
      Enum.map(cols, fn
        "id" -> "gen_random_uuid()"
        "slug" -> "'cfb-' || g"
        "title" -> "'Row ' || g"
        "custom_fields" -> custom
        "org_id" -> org_pick.([small | rest_orgs])
        "type_definition_id" -> "'#{type}'::uuid"
        col -> "t.#{col}"
      end)

    q.(
      """
      INSERT INTO #{table} (#{Enum.join(cols, ", ")})
      SELECT #{Enum.join(exprs, ", ")} FROM #{table} t, generate_series(1, $2) g
      WHERE t.id = $1::uuid
      """,
      [Ecto.UUID.dump!(tpl), rows_n]
    )
  end

  # The small tenant's rows belong to its own type, where the entry tier needs one.
  q.(
    "UPDATE entries SET type_definition_id = $1::uuid WHERE org_id = $2::uuid AND slug LIKE 'cfb-%'",
    [Ecto.UUID.dump!(types[small].type), Ecto.UUID.dump!(small)]
  )

  for table <- ~w(pages entries), do: q.("ANALYZE #{table}", [])
  IO.puts("seeded in #{System.monotonic_time(:millisecond) - t0} ms")
end

type_ids =
  Map.new([big, small], fn org ->
    [[id]] =
      q.(
        "SELECT id::text FROM type_definitions WHERE org_id = $1::uuid AND name = 'cfbench'",
        [Ecto.UUID.dump!(org)]
      ).rows

    {org, id}
  end)

# --- variant ---------------------------------------------------------------------

index_sql = fn table ->
  "CREATE INDEX IF NOT EXISTS bench_cf_gin_#{table} ON #{table} USING gin (custom_fields jsonb_path_ops)"
end

set_index = fn on? ->
  for table <- ~w(pages entries) do
    q.("DROP INDEX IF EXISTS bench_cf_gin_#{table}", [])
    if on?, do: q.(index_sql.(table), [])
    q.("ANALYZE #{table}", [])
  end
end

# The write phase below leaves dead tuples behind; start every run from a
# compact heap so the variants compare like with like.
for table <- ~w(pages entries), do: q.("VACUUM FULL #{table}", [])

set_index.(variant != "a")

size = fn rel ->
  q.("SELECT pg_relation_size(to_regclass($1::text))", [rel]).rows |> hd() |> hd()
end

mb = fn bytes -> Float.round(bytes / 1_048_576, 1) end

[[pages_total, entries_total]] =
  q.("SELECT (SELECT count(*) FROM pages), (SELECT count(*) FROM entries)", []).rows

IO.puts("variant #{variant}: #{pages_total} pages, #{entries_total} entries")

IO.puts(
  "table sizes (heap only): pages #{mb.(size.("pages"))} MB, entries #{mb.(size.("entries"))} MB"
)

if variant != "a" do
  IO.puts(
    "GIN index sizes: pages #{mb.(size.("bench_cf_gin_pages"))} MB, " <>
      "entries #{mb.(size.("bench_cf_gin_entries"))} MB"
  )
end

# --- reads -----------------------------------------------------------------------

:telemetry.attach(
  "cf-capture",
  [:kiln_cms, :repo, :query],
  fn _event, _measurements, %{query: query, params: params}, _config ->
    if String.contains?(query, "custom_fields"), do: Process.put(:cf_sql, {query, params})
  end,
  nil
)

[[hero_rare]] =
  q.("SELECT custom_fields -> 'hero' ->> 'id' FROM pages WHERE slug = 'cfb-777'", []).rows

cases = [
  {"eq rare (sku, 1 row)", %{"sku" => "sku-777"}, nil},
  {"eq 30% (grade)", %{"grade" => "A"}, nil},
  {"eq boolean 50%", %{"featured" => "true"}, nil},
  {"in 3 colors (15%)", %{"color" => %{"in" => ~w(red green blue)}}, nil},
  {"list-has rare", %{"props" => "rare"}, nil},
  {"list-has 16%", %{"props" => "p3"}, nil},
  {"media eq rare", %{"hero" => hero_rare}, nil},
  {"range price > 9900 (1%)", %{"price" => %{"gt" => "9900"}}, nil},
  {"not_eq grade A", %{"grade" => %{"not_eq" => "A"}}, nil},
  {"sort -price, limit 20", %{}, "-price"},
  {"eq 30% + sort -price", %{"grade" => "A"}, "-price"}
]

percentile = fn sorted, p ->
  Enum.at(sorted, min(length(sorted) - 1, trunc(p * length(sorted))))
end

fmt = fn x -> :erlang.float_to_binary(x * 1.0, decimals: 1) end

# Scan nodes of a plan, as `Seq Scan pages` / `Bitmap Index Scan bench_cf_gin_pages`.
nodes = fn plan ->
  walk = fn walk, node ->
    own =
      case node["Node Type"] do
        "Seq Scan" ->
          ["Seq Scan"]

        t when t in ["Index Scan", "Index Only Scan", "Bitmap Index Scan"] ->
          ["#{t} #{node["Index Name"]}"]

        _ ->
          []
      end

    own ++ Enum.flat_map(node["Plans"] || [], &walk.(walk, &1))
  end

  walk.(walk, plan) |> Enum.uniq() |> Enum.join(", ")
end

explain = fn sql, params ->
  Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params, timeout: :infinity).rows
  |> hd()
  |> hd()
  |> hd()
end

run_case = fn label, tier, filter, sort, org ->
  read = fn ->
    inputs = %{custom_filter: filter, custom_sort: sort || ""}

    case tier do
      :page ->
        CMS.list_published_pages!(inputs,
          actor: nil,
          tenant: org,
          authorize?: false,
          page: [limit: 20]
        )

      :entry ->
        CMS.list_published_entries!(inputs,
          actor: nil,
          tenant: org,
          authorize?: false,
          page: [limit: 20],
          query: [filter: [type_definition_id: type_ids[org]]]
        )
    end
  end

  count = length(read.().results)

  times =
    for _ <- 1..runs do
      {us, _} = :timer.tc(read)
      us / 1000
    end
    |> Enum.sort()

  {sql, params} = Process.get(:cf_sql)
  custom = explain.(sql, params)

  # Generic plan: what the 6th+ execution of a prepared statement can switch to.
  generic =
    Repo.checkout(fn ->
      Repo.query!("SET plan_cache_mode = force_generic_plan")
      plan = explain.(sql, params)
      Repo.query!("RESET plan_cache_mode")
      plan
    end)

  ms = fn plan -> fmt.(plan["Execution Time"]) end

  IO.puts(
    "| #{label} | #{tier} | #{if org == big, do: "big", else: "small"} | #{count} | " <>
      "#{fmt.(percentile.(times, 0.5))} | #{fmt.(percentile.(times, 0.95))} | " <>
      "#{ms.(custom)} (#{nodes.(custom["Plan"])}) | #{ms.(generic)} (#{nodes.(generic["Plan"])}) |"
  )
end

predicate =
  case Process.get(:cf_sql) do
    _ ->
      CMS.list_published_pages!(%{custom_filter: %{"sku" => "sku-1"}},
        actor: nil,
        tenant: big,
        authorize?: false,
        page: [limit: 1]
      )

      {sql, _} = Process.get(:cf_sql)

      if String.contains?(sql, "jsonb_build_object"),
        do: "containment (@>)",
        else: "equality (->)"
  end

IO.puts("predicate: #{predicate}\n")

IO.puts(
  "| Query | Tier | Tenant | Rows (page of 20) | p50 ms | p95 ms | Exec ms, custom plan | Exec ms, forced generic plan |"
)

IO.puts("|---|---|---|---|---|---|---|---|")

for {label, filter, sort} <- cases, tier <- [:page, :entry] do
  run_case.(label, tier, filter, sort, big)
end

for {label, filter, sort} <- Enum.take(cases, 3), tier <- [:page, :entry] do
  run_case.(label <> " [small tenant]", tier, filter, sort, small)
end

# --- writes ----------------------------------------------------------------------

# `custom_fields` is rewritten on every save, so no update is HOT once it is
# indexed. Bulk SQL (no Ash) first, then real saves through the domain.
[[page_tpl]] = q.("SELECT id::text FROM pages WHERE slug = 'cfb-1'", []).rows

page_cols =
  q.(
    """
    SELECT column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pages' AND is_generated = 'NEVER'
    ORDER BY ordinal_position
    """,
    []
  ).rows
  |> List.flatten()

timed = fn fun ->
  {us, result} = :timer.tc(fun)
  {us / 1000, result}
end

IO.puts("\n| Write (#{write_rows} rows / #{write_updates} saves) | Index | ms |")
IO.puts("|---|---|---|")

for on? <- [false, true], round <- 1..3 do
  set_index.(on?)

  exprs =
    Enum.map(page_cols, fn
      "id" -> "gen_random_uuid()"
      "slug" -> "'cfw-' || g"
      "custom_fields" -> "t.custom_fields"
      col -> "t.#{col}"
    end)

  {insert_ms, _} =
    timed.(fn ->
      q.(
        """
        INSERT INTO pages (#{Enum.join(page_cols, ", ")})
        SELECT #{Enum.join(exprs, ", ")} FROM pages t, generate_series(1, $2) g WHERE t.id = $1::uuid
        """,
        [Ecto.UUID.dump!(page_tpl), write_rows]
      )
    end)

  {update_ms, _} =
    timed.(fn ->
      q.(
        "UPDATE pages SET custom_fields = jsonb_set(custom_fields, '{price}', to_jsonb(random()::numeric)) WHERE slug LIKE 'cfw-%'",
        []
      )
    end)

  slugs = Enum.map(1..write_updates, &"cfw-#{&1}")

  saves =
    q.("SELECT id::text, org_id::text FROM pages WHERE slug = ANY($1) LIMIT $2", [
      slugs,
      write_updates
    ]).rows

  {save_ms, _} =
    timed.(fn ->
      for {[id, org], n} <- Enum.with_index(saves) do
        id
        |> CMS.get_page!(actor: admin, tenant: org, authorize?: false)
        |> CMS.update_page!(%{custom_fields: %{"price" => n, "sku" => "w#{n}"}},
          actor: admin,
          tenant: org,
          authorize?: false
        )
      end
    end)

  q.("DELETE FROM pages WHERE slug LIKE 'cfw-%'", [])
  label = if on?, do: "GIN", else: "none"
  IO.puts("| bulk insert, round #{round} | #{label} | #{fmt.(insert_ms)} |")
  IO.puts("| bulk update of custom_fields, round #{round} | #{label} | #{fmt.(update_ms)} |")

  IO.puts(
    "| #{length(saves)} saves through update_page, round #{round} | #{label} | #{fmt.(save_ms)} |"
  )
end

set_index.(variant != "a")
IO.puts("\ndone")
