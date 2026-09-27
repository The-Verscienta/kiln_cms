# Seeds an upgrade rehearsal's database at the OLD release (#1540), then writes
# a manifest of what is there for verify.exs to hold the candidate to.
#
#   mix run scripts/upgrade_rehearsal/seed.exs CORPUS_JSON MANIFEST_JSON
#
# Runs inside the old release's build, so it may only lean on what every
# release since 0.5.0 has: `KilnCMS.Repo`, the `pages`/`posts` tables that
# `priv/repo/seeds.exs` fills, and `KilnCMS.CMS.BlockUnion`. Everything else is
# plain SQL.
#
# What it adds on top of the release's own seeds:
#
#   * one published page per convertible entry of the legacy block corpus
#     (`KilnCMS.LegacyBlockCorpus`, exported from the candidate as JSON) —
#     every shape a stored block tree can still hold at rest: pre-flip
#     `KilnCMS.CMS.Block` maps, bare typed maps, stale-`_version` envelopes,
#     columns trees. Written straight into the column, the way a database
#     that has been through every earlier release holds them.
#   * one page and one post whose blocks this release's own `BlockUnion`
#     casts and dumps — every block type it knows, stored the way its own
#     save would store them.
#
# New rows are clones of the seeded `welcome` page and `hello-world` post, so
# every NOT NULL column this release added is already filled the way its own
# create action fills it.

[corpus_path, manifest_path] = System.argv()

defmodule Rehearsal.Seed do
  alias KilnCMS.Repo

  def q(sql, params \\ []), do: Repo.query!(sql, params, timeout: :infinity)

  def columns(table) do
    q(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND is_generated = 'NEVER'
      ORDER BY ordinal_position
      """,
      [table]
    ).rows
    |> List.flatten()
  end

  def template!(table, slug) do
    case q("SELECT id::text FROM #{table} WHERE slug = $1 ORDER BY inserted_at LIMIT 1", [slug]).rows do
      [[id]] ->
        id

      _ ->
        raise "no #{table} row with slug #{inspect(slug)} to clone: did priv/repo/seeds.exs run?"
    end
  end

  # Clone the template row with `overrides` (a column => value map), then write
  # the block columns as given. Returns the new id as text.
  def clone!(table, template, overrides, blocks, working_blocks \\ nil) do
    cols = columns(table)
    col_list = Enum.map_join(cols, ", ", &~s("#{&1}"))
    id = Ecto.UUID.generate()

    set =
      overrides
      |> Map.merge(%{"id" => id, "path_alias" => nil})
      |> Map.take(cols)

    q(
      """
      INSERT INTO #{table} (#{col_list})
      SELECT #{col_list} FROM jsonb_populate_record(
        NULL::#{table},
        (SELECT to_jsonb(t) FROM #{table} t WHERE t.id::text = $1) || $2::jsonb
      )
      """,
      [template, set]
    )

    q("UPDATE #{table} SET blocks = $1 WHERE id::text = $2", [blocks, id])

    if working_blocks != nil and "working_blocks" in cols do
      q("UPDATE #{table} SET working_blocks = $1 WHERE id::text = $2", [working_blocks, id])
    end

    id
  end

  # This release's own stored shape for each block it can cast; the ones it
  # has never heard of are reported and left out.
  def through_this_release(maps) do
    attr = Ash.Resource.Info.attribute(KilnCMS.CMS.Page, :blocks)

    Enum.reduce(maps, {[], []}, fn map, {kept, skipped} ->
      with {:ok, cast} <- Ash.Type.cast_input(attr.type, [map], attr.constraints),
           {:ok, [dumped]} <- Ash.Type.dump_to_native(attr.type, cast, attr.constraints) do
        {[json_safe(dumped) | kept], skipped}
      else
        other -> {kept, [{map["_type"], inspect(other, limit: 5)} | skipped]}
      end
    end)
    |> then(fn {kept, skipped} -> {Enum.reverse(kept), Enum.reverse(skipped)} end)
  end

  defp json_safe(value), do: value |> JSON.encode!() |> JSON.decode!()

  # Every row of every table holding a block tree, as it is stored right now.
  def snapshot do
    block_tables =
      q("""
      SELECT DISTINCT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'blocks' AND data_type = 'ARRAY'
        AND table_name NOT LIKE '%\\_versions'
      ORDER BY table_name
      """).rows
      |> List.flatten()

    rows =
      for table <- block_tables,
          cols = columns(table),
          row <- select_rows(table, cols),
          do: Map.put(row, "table", table)

    counts =
      for [table] <-
            q("""
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
              AND table_name <> 'schema_migrations'
            ORDER BY table_name
            """).rows,
          into: %{} do
        [[count]] = q(~s[SELECT count(*) FROM "#{table}"]).rows
        {table, count}
      end

    %{"rows" => rows, "counts" => counts}
  end

  defp select_rows(table, cols) do
    wanted =
      [
        {"id", "id::text"},
        {"org_id", "org_id::text"},
        {"slug", "slug"},
        {"title", "title"},
        {"locale", "locale"},
        # The workflow state; `status` on the few tables that name it so.
        {"state", "state::text"},
        {"status", "status::text"},
        {"blocks", "blocks"},
        {"working_blocks", "working_blocks"}
      ]
      |> Enum.filter(fn {col, _} -> col in cols end)

    select =
      Enum.map_join(wanted, ", ", fn
        {"state", expr} -> ~s(#{expr} AS "status")
        {col, expr} -> ~s(#{expr} AS "#{col}")
      end)

    result = q("SELECT #{select} FROM #{table} ORDER BY id")

    for row <- result.rows do
      result.columns |> Enum.zip(row) |> Map.new()
    end
  end
end

alias Rehearsal.Seed

corpus = corpus_path |> File.read!() |> JSON.decode!()

# Re-runnable: clear what an interrupted earlier run left.
for table <- ["pages", "posts"],
    do: Seed.q("DELETE FROM #{table} WHERE slug LIKE 'rehearsal-%'")

page_template = Seed.template!("pages", "welcome")
post_template = Seed.template!("posts", "hello-world")

# 1. The corpus, one page per convertible entry.
corpus_pages =
  for {%{"name" => name, "expectation" => expectation, "stored" => stored}, n} <-
        Enum.with_index(corpus, 1),
      expectation in [":rewrite", ":canonical"] do
    slug = "rehearsal-corpus-#{n}"

    # The first entry also sits in the working copy, where the editor keeps
    # unpublished changes — the backfill covers both columns.
    working = if n == 1, do: stored

    id =
      Seed.clone!(
        "pages",
        page_template,
        %{"slug" => slug, "title" => "Rehearsal corpus #{n}", "seo_title" => nil},
        stored,
        working
      )

    %{"id" => id, "slug" => slug, "corpus" => name}
  end

# 2. Every block type this release knows, stored by this release's own code.
typed_maps =
  corpus
  |> Enum.filter(
    &(&1["name"] in ["bare typed maps for every core block", "a plugin block as a bare typed map"])
  )
  |> Enum.flat_map(& &1["stored"])

{typed, skipped} = Seed.through_this_release(typed_maps)

typed_page =
  Seed.clone!(
    "pages",
    page_template,
    %{"slug" => "rehearsal-typed", "title" => "Rehearsal typed blocks", "seo_title" => nil},
    typed
  )

typed_post =
  Seed.clone!(
    "posts",
    post_template,
    %{"slug" => "rehearsal-typed-post", "title" => "Rehearsal typed post"},
    typed
  )

for {type, why} <- skipped,
    do: IO.puts("seed: this release cannot store a #{type} block (#{why})")

manifest =
  Seed.snapshot()
  |> Map.merge(%{
    "release" => to_string(Application.spec(:kiln_cms, :vsn)),
    "corpus_pages" => corpus_pages,
    "typed" => %{"page" => typed_page, "post" => typed_post, "count" => length(typed)},
    "skipped_types" => Enum.map(skipped, &elem(&1, 0))
  })

File.write!(manifest_path, JSON.encode!(manifest))

IO.puts(
  "seed: #{length(corpus_pages)} corpus pages, #{length(typed)} typed blocks " <>
    "(#{length(skipped)} types unknown here), #{length(manifest["rows"])} block-tree rows in all"
)
