defmodule KilnCMS.CMS.CustomSortTargetKeyBenchmarkTest do
  @moduledoc """
  What a `custom_sort` on a reference field costs at 100,000 referrers
  (#2444 follow-up): one target type, two compiled types, two plus a dynamic
  type (which probes the whole `entries` table), and the `all_resources()`
  fallback a field takes when its `target_type` no longer resolves — for an
  editor and an anonymous reader, over the whole table and behind a
  narrowing filter. Prints each read's `EXPLAIN (ANALYZE)` execution time and
  keeps every plan; set `KILN_BENCH_OUT` to a file to have them written there.

  Excluded by default (`:benchmark`, `test/test_helper.exs`):

      mix test --only benchmark test/kiln_cms/cms/custom_sort_target_key_benchmark_test.exs

  Asserts only that each read answered.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo

  @moduletag :benchmark
  @moduletag timeout: :timer.minutes(20)

  @referrers 100_000
  @narrow 1_000
  @targets 5_000

  @shapes [
    {"one type", %{target_type: "page"}},
    {"two types", %{target_types: ["page", "post"]}},
    {"two + dynamic", :dynamic},
    {"all (unresolved)", :ghost}
  ]

  test "reference sort at 100k referrers" do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "cstkb-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    org_id = KilnCMS.Accounts.default_org_id()
    org = Ecto.UUID.dump!(org_id)

    type =
      CMS.create_type_definition!(%{name: "cb#{System.unique_integer([:positive])}", label: "B"},
        actor: admin
      )

    fields =
      for {label, spec} <- @shapes, into: %{} do
        name = "bench_" <> String.replace(label, ~r/\W+/, "_")

        attrs =
          case spec do
            :dynamic -> %{target_types: ["page", "post", type.name]}
            :ghost -> %{target_types: ["page", "post"]}
            map -> map
          end

        CMS.create_field_definition!(
          Map.merge(
            %{content_type: :page, label: label, name: name, field_type: :reference},
            attrs
          ),
          actor: admin
        )

        # A type that no longer resolves: the field falls back to every
        # content resource.
        if spec == :ghost do
          Repo.query!(
            "UPDATE field_definitions SET target_types = ARRAY['ghost_type'] WHERE name = $1",
            [name]
          )
        end

        {label, name}
      end

    for table <- ["pages", "posts"] do
      Repo.query!(
        """
        INSERT INTO #{table} (id, title, slug, org_id, locale, state, custom_fields)
        SELECT gen_random_uuid(), 'cstkb target ' || lpad(i::text, 5, '0'), 'cstkb-#{table}-' || i, $1, 'en',
               CASE WHEN i % 10 = 0 THEN 'draft' ELSE 'published' END, '{}'::jsonb
        FROM generate_series(1, $2) AS i
        """,
        [org, @targets]
      )
    end

    Repo.query!(
      """
      INSERT INTO entries (id, title, slug, org_id, locale, state, type_definition_id, custom_fields)
      SELECT gen_random_uuid(), 'cstkb target ' || lpad(i::text, 5, '0'), 'cstkb-entries-' || i, $1, 'en',
             CASE WHEN i % 10 = 0 THEN 'draft' ELSE 'published' END, $3, '{}'::jsonb
      FROM generate_series(1, $2) AS i
      """,
      [org, @targets, Ecto.UUID.dump!(type.id)]
    )

    # Numbered targets of each table, to point referrers at by position.
    Repo.query!(
      """
      CREATE TEMP TABLE cstkb_t AS
      SELECT 'pages' AS tbl, row_number() OVER (ORDER BY slug) AS n, id, title FROM pages WHERE slug LIKE 'cstkb-pages-%'
      UNION ALL SELECT 'posts', row_number() OVER (ORDER BY slug), id, title FROM posts WHERE slug LIKE 'cstkb-posts-%'
      UNION ALL SELECT 'entries', row_number() OVER (ORDER BY slug), id, title FROM entries WHERE slug LIKE 'cstkb-entries-%'
      """,
      []
    )

    Repo.query!("CREATE UNIQUE INDEX ON cstkb_t (tbl, n)")
    Repo.query!("ANALYZE cstkb_t")
    [one, two, dyn, all] = for {label, _} <- @shapes, do: fields[label]

    # Each referrer points `one` at a page; `two` at a page or post; `dyn` and
    # `all` at a page, post or entry — so a probe misses in the other tables.
    Repo.query!(
      """
      INSERT INTO pages (id, title, slug, org_id, locale, state, custom_fields)
      SELECT gen_random_uuid(),
             CASE WHEN i <= $2 THEN 'cstkb narrow' ELSE 'cstkb referrer' END,
             'cstkb-r-' || i, $1, 'en', 'published',
             jsonb_build_object(
               $3::text, jsonb_build_object('id', a.id, 'type', 'page', 'title', a.title),
               $4::text, jsonb_build_object('id', b.id, 'type', 'page', 'title', b.title),
               $5::text, jsonb_build_object('id', c.id, 'type', 'page', 'title', c.title),
               $6::text, jsonb_build_object('id', c.id, 'type', 'page', 'title', c.title))
      FROM generate_series(1, $7) AS i
      JOIN cstkb_t a ON a.tbl = 'pages' AND a.n = i % $8 + 1
      JOIN cstkb_t b ON b.tbl = CASE i % 2 WHEN 0 THEN 'pages' ELSE 'posts' END AND b.n = (i * 7) % $8 + 1
      JOIN cstkb_t c ON c.tbl = CASE i % 3 WHEN 0 THEN 'pages' WHEN 1 THEN 'posts' ELSE 'entries' END
                    AND c.n = (i * 13) % $8 + 1
      """,
      [org, @narrow, one, two, dyn, all, @referrers, @targets],
      timeout: :infinity
    )

    Repo.query!("ANALYZE pages")
    Repo.query!("ANALYZE posts")
    Repo.query!("ANALYZE entries")
    Repo.query!("ANALYZE content_links")

    edge_ms = edge_alternative(all, org)

    rows =
      for {label, _} <- @shapes,
          {who, actor} <- [{"editor", admin}, {"anonymous", nil}],
          {scope, title} <- [{"whole table", "cstkb"}, {"narrowed to #{@narrow}", "cstkb narrow"}] do
        field = fields[label]
        {sql, params} = capture(fn -> read(field, actor, org_id, title) end)
        run = fn -> explain(sql, params) end
        # Warm once; the cache is the same for every shape.
        run.()
        {ms, plan} = run.()

        IO.puts(
          "#{String.pad_trailing(label, 17)} #{String.pad_trailing(who, 10)} #{String.pad_trailing(scope, 24)} #{ms} ms"
        )

        {label, who, scope, ms, plan}
      end

    if out = System.get_env("KILN_BENCH_OUT") do
      body =
        Enum.map_join(rows, "\n\n", fn {label, who, scope, ms, plan} ->
          "## #{label} / #{who} / #{scope}: #{ms} ms\n#{plan}"
        end)

      File.write!(out, body)
    end

    IO.puts("edge-based key, 3 types, anonymous, whole table   #{edge_ms} ms")
    assert length(rows) == length(@shapes) * 4
  end

  # The rejected alternative: one `content_links` lookup per referrer (the
  # `(org_id, source_id, ...)` identity index) gives the target id, then a
  # primary-key probe per type — a left join each, readable-anonymous filter
  # spelled out for the published public case. Raw SQL, for the numbers only.
  defp edge_alternative(field, org) do
    Repo.query!(
      """
      INSERT INTO content_links (id, source_id, target_id, kind, org_id, field)
      SELECT gen_random_uuid(), p.id, (p.custom_fields -> $2 ->> 'id')::uuid, 'reference', $1, $2
      FROM pages p WHERE p.slug LIKE 'cstkb-r-%'
      """,
      [org, field],
      timeout: :infinity
    )

    Repo.query!("ANALYZE content_links")

    sql = """
    EXPLAIN (ANALYZE, FORMAT TEXT)
    SELECT p.id FROM pages p
    LEFT JOIN LATERAL (SELECT l.target_id FROM content_links l
                        WHERE l.org_id = $1 AND l.source_id = p.id AND l.kind = 'reference' AND l.field = $2
                        LIMIT 1) e ON true
    LEFT JOIN pages t1 ON t1.id = e.target_id AND t1.org_id = $1 AND t1.state = 'published' AND t1.audience = 'public'
    LEFT JOIN posts t2 ON t2.id = e.target_id AND t2.org_id = $1 AND t2.state = 'published' AND t2.audience = 'public'
    LEFT JOIN entries t3 ON t3.id = e.target_id AND t3.org_id = $1 AND t3.state = 'published' AND t3.audience = 'public'
    WHERE p.org_id = $1 AND p.state = 'published' AND p.audience = 'public' AND p.title LIKE '%cstkb%'
    ORDER BY coalesce(t1.title, t2.title, t3.title), p.id LIMIT 21
    """

    run = fn ->
      plan =
        Repo.query!(sql, [Ecto.UUID.dump!(KilnCMS.Accounts.default_org_id()), field]).rows
        |> Enum.map_join("\n", &hd/1)

      [_, ms] = Regex.run(~r/Execution Time: ([\d.]+) ms/, plan)
      ms
    end

    run.()
    run.()
  end

  defp read(field, actor, org_id, title) do
    # `ilike` through the title filter keeps the narrowing a plain column
    # predicate; the sort is the reference key.
    CMS.list_pages!(%{custom_sort: field},
      actor: actor,
      tenant: org_id,
      page: [limit: 20],
      query: [filter: [title: [contains: title]]]
    )
  end

  defp explain(sql, params) do
    plan =
      Repo.query!("EXPLAIN (ANALYZE, FORMAT TEXT) " <> sql, params).rows
      |> Enum.map_join("\n", &hd/1)

    [_, ms] = Regex.run(~r/Execution Time: ([\d.]+) ms/, plan)
    {ms, plan}
  end

  defp capture(fun) do
    test = self()
    handler = "cstkb-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _m, meta, _c ->
        if self() == test and meta[:source] == "pages" and meta[:query] =~ "ORDER BY",
          do: send(test, {:captured, meta[:query], meta[:params]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    receive_last(nil)
  end

  defp receive_last(last) do
    receive do
      {:captured, sql, params} -> receive_last({sql, params})
    after
      0 -> last || flunk("no query captured")
    end
  end
end
