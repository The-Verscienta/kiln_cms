defmodule KilnCMS.Search.MeasureFloorTaskTest do
  @moduledoc """
  `mix kiln.search.measure_floor` reads the eval golden set, measures each
  query against the corpus by raw cosine distance through the semantic leg
  hybrid search runs, and proposes a floor between the expected records'
  band and the junk queries' band. Uses the deterministic stub embedder, so a
  query equal to a record's title lands at distance 0 and every other pairing
  at a fixed, non-zero distance.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias Mix.Tasks.Kiln.Search.MeasureFloor

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(Keyword.merge(KilnCMS.StubEmbedder.search_env(), semantic: true))
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "floor-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "floor-#{System.unique_integer([:positive])}"

  defp published_page(admin, attrs) do
    page = CMS.create_page!(attrs, actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
  end

  defp published_post(admin, attrs) do
    post = CMS.create_post!(attrs, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)
  end

  # The golden set is JSON; a row is `{query, expected, class, type?, locale?}`.
  defp golden(dir, rows) do
    path = Path.join(dir, "golden.json")
    File.write!(path, Jason.encode!(rows))
    path
  end

  defp expects(query, slugs, class, extra \\ %{}),
    do: Map.merge(%{"query" => query, "expected" => List.wrap(slugs), "class" => class}, extra)

  defp junk(query), do: %{"query" => query, "expected" => [], "class" => "junk"}

  defp distance(type, query, opts) do
    {:ok, [%{distance: distance} | _]} = KilnCMS.Search.semantic_neighbours(type, query, opts)
    distance
  end

  @tag :tmp_dir
  test "reports expected records against their competitors, junk, and a cutoff", %{
    tmp_dir: dir
  } do
    admin = admin()
    alpha = published_page(admin, %{title: "Alpha", slug: slug()})
    beta = published_page(admin, %{title: "Beta", slug: slug()})
    KilnCMS.DataCase.drain_oban()

    # The configured floor must be ignored by the measurement.
    put_search_env(semantic_max_distance: 0.0)

    set =
      golden(dir, [
        expects("Alpha", alpha.slug, "single_entity"),
        junk("nothing like this exists")
      ])

    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page"]) end)

    assert output =~ ~s|"Alpha"  [single_entity]  → expects #{alpha.slug}|
    assert output =~ ~r/expected\s+page\s+#{alpha.slug}\s+0\.0000\s+\(rank 1 of its type\)/
    assert output =~ ~r/nearest ≠\s+page\s+#{beta.slug}\s+\d\.\d{4}/
    assert output =~ ~s|"nothing like this exists"  [junk]  → expects nothing|
    assert output =~ ~r/nearest\s+page\s+(#{alpha.slug}|#{beta.slug})\s+\d\.\d{4}/
    assert output =~ "configured floor: 0.0 (ignored here)"
    # The bands come out per class as well as overall.
    assert output =~ ~r/single_entity\s+0\.0000 – 0\.0000\s+\(n=1\)/

    # "Alpha" sits at 0; the junk query's nearest neighbour is some way off,
    # so the bands separate and the midpoint is proposed.
    assert [_, midpoint] = Regex.run(~r/Suggested semantic_max_distance: (\d\.\d{4})/, output)
    junk_nearest = distance(:page, "nothing like this exists", published: true)
    assert_in_delta String.to_float(midpoint), junk_nearest / 2, 1.0e-3
    assert output =~ "keeps every expected record and rejects every junk query on both surfaces"
  end

  @tag :tmp_dir
  test "says when the bands overlap, what each edge costs, and which surface wants which", %{
    tmp_dir: dir
  } do
    admin = admin()
    # Expected under a query that is NOT its title: a real, non-zero distance,
    # while a junk query's nearest neighbour is the same kind of distance —
    # under the stub embedder, no single cutoff separates the two.
    far = published_page(admin, %{title: "Far Away Record", slug: slug()})
    KilnCMS.DataCase.drain_oban()

    set =
      golden(dir, [
        expects("a paraphrase of it", far.slug, "paraphrase"),
        junk("asdfghjkl zzqqxx")
      ])

    output = capture_io(fn -> MeasureFloor.run([set]) end)

    expected_distance = distance(:page, "a paraphrase of it", published: true)
    junk_distance = distance(:page, "asdfghjkl zzqqxx", published: true)

    if expected_distance < junk_distance do
      assert output =~ "keeps every expected record and rejects every junk query"
    else
      assert output =~ "no single value separates the bands"
      assert output =~ "keeps every expected record and admits 1 of 1 junk queries"
      # The floor drops `distance > max`, so rejecting the nearest junk hit
      # takes a floor strictly below it — and at that floor the expected
      # record, which sits at or beyond it, is dropped: 1 of 1, not 0 of 1.
      assert output =~ ~r/just below \d\.\d{4} rejects every junk query and drops 1 of 1 expected/
    end

    assert output =~ "Hybrid search (the search page, /api/search, /api/ask) floors only hits no"
    assert output =~ "The per-type semantic-search routes exempt only a title match"
  end

  @tag :tmp_dir
  test "bands that touch: the reject edge is 'just below', and it drops the record at it", %{
    tmp_dir: dir
  } do
    admin = admin()
    record = published_page(admin, %{title: "Touching Record", slug: slug()})
    KilnCMS.DataCase.drain_oban()

    # Both rows ARE the record's title, so the expected record and the junk
    # query's nearest neighbour sit at the same distance, 0.0: no value
    # separates the bands. The floor drops `distance > max`, so a floor AT
    # the nearest junk distance admits it — rejecting it takes a floor just
    # below, and that floor drops the expected record sitting at 0.0 too.
    set =
      golden(dir, [
        expects("Touching Record", record.slug, "single_entity"),
        junk("Touching Record")
      ])

    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page"]) end)

    assert output =~ "no single value separates the bands"
    assert output =~ "0.0000 keeps every expected record and admits 1 of 1 junk queries"

    assert output =~
             "just below 0.0000 rejects every junk query and drops 1 of 1 expected records"
  end

  @tag :tmp_dir
  test "an expected record beyond the nearest --limit is still measured", %{tmp_dir: dir} do
    admin = admin()
    target = published_page(admin, %{title: "Target", slug: slug()})
    published_page(admin, %{title: "Decoy", slug: slug()})
    KilnCMS.DataCase.drain_oban()

    set = golden(dir, [expects("Decoy", target.slug, "paraphrase")])
    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page", "--limit", "1"]) end)

    assert output =~ ~r/expected\s+page\s+#{target.slug}\s+\d\.\d{4}\s+\(beyond the nearest rows/
    assert output =~ "No junk queries in the set"
  end

  @tag :tmp_dir
  test "measures the leg hybrid search runs: the query's locale, published rows only", %{
    tmp_dir: dir
  } do
    admin = admin()
    shared = slug()
    # The same slug in two locales (a translation): the `fr` row IS the query
    # (distance 0) but the default-locale leg never sees it, so the report
    # must measure the `en` row's real distance — or the operator sets a floor
    # from a distance the leg never computes and drops the record it fuses.
    en = published_page(admin, %{title: "English text", slug: shared})
    published_page(admin, %{title: "Bonjour", slug: shared, locale: "fr"})
    # A draft with the query as its title: distance 0, but not published.
    CMS.create_page!(%{title: "Bonjour", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    set = golden(dir, [expects("Bonjour", shared, "paraphrase")])

    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page"]) end)
    en_distance = distance(:page, "Bonjour", slug: shared, published: true)
    assert en_distance > 0.0

    assert output =~
             ~r/expected\s+page\s+#{en.slug}\s+#{Float.to_string(Float.round(en_distance, 4))}/

    refute output =~ "0.0000"

    # Told the row is about `fr`, it measures the French leg: distance 0.
    set = golden(dir, [expects("Bonjour", shared, "single_entity", %{"locale" => "fr"})])
    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page"]) end)
    assert output =~ ~r/expected\s+page\s+#{shared}\s+0\.0000\s+\(rank 1 of its type\)/

    # And `--locale` sets the default for rows that say nothing.
    set = golden(dir, [expects("Bonjour", shared, "single_entity")])
    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page", "--locale", "fr"]) end)
    assert output =~ ~r/expected\s+page\s+#{shared}\s+0\.0000/
  end

  @tag :tmp_dir
  test "a slug shared by two types is measured in the type the row names", %{tmp_dir: dir} do
    admin = admin()
    shared = slug()
    # A page and a post with one slug. The POST is the query's title (distance
    # 0); the row is about the page, whose distance is real.
    published_page(admin, %{title: "About us", slug: shared})
    published_post(admin, %{title: "Shared", slug: shared})
    KilnCMS.DataCase.drain_oban()

    set = golden(dir, [expects("Shared", shared, "single_entity", %{"type" => "page"})])
    output = capture_io(fn -> MeasureFloor.run([set]) end)

    assert output =~ ~r/expected\s+page\s+#{shared}\s+\d\.\d{4}/
    # The row's type narrows what is measured, the way the eval harness
    # narrows hits: the post is neither the answer nor a competitor.
    refute output =~ ~r/\bpost\s+#{shared}/
    assert output =~ "nearest ≠  (none)"

    # A row naming a type that is not being measured is an error, not silence.
    set = golden(dir, [expects("Shared", shared, "single_entity", %{"type" => "page"})])

    assert_raise Mix.Error, ~r/names type "page", which is not being measured/, fn ->
      capture_io(fn -> MeasureFloor.run([set, "--type", "post"]) end)
    end
  end

  @tag :tmp_dir
  test "a dynamic type is measured within its own definition, not the whole entry tier", %{
    tmp_dir: dir
  } do
    admin = admin()
    shared = slug()

    ingredient =
      CMS.create_type_definition!(
        %{name: "ingredient#{System.unique_integer([:positive])}", label: "Ingredient"},
        actor: admin
      )

    recipe =
      CMS.create_type_definition!(
        %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
        actor: admin
      )

    # Two entries share a slug across two dynamic types; the RECIPE is the
    # query's title. Measuring the ingredient must neither find the recipe under
    # the ingredient label nor look the slug up in the wrong type.
    ingredient_entry =
      KilnCMS.CMS.ContentTypes.create!(ingredient.name, %{title: "Lemon zest", slug: shared},
        actor: admin
      )

    CMS.publish_entry!(ingredient_entry, %{}, actor: admin)

    recipe_entry =
      KilnCMS.CMS.ContentTypes.create!(recipe.name, %{title: "Lemon", slug: shared}, actor: admin)

    CMS.publish_entry!(recipe_entry, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    set = golden(dir, [expects("Lemon", shared, "single_entity")])

    output =
      capture_io(fn -> MeasureFloor.run([set, "--type", ingredient.name, "--limit", "1"]) end)

    assert output =~ ~r/expected\s+#{ingredient.name}\s+#{shared}\s+\d\.\d{4}/
    refute output =~ ~r/#{shared}\s+0\.0000/
    refute output =~ recipe.name

    # Swept without `--type`, both are labelled with their own type.
    set = golden(dir, [expects("Lemon", shared, "single_entity", %{"type" => recipe.name})])
    output = capture_io(fn -> MeasureFloor.run([set]) end)
    assert output =~ ~r/expected\s+#{String.slice(recipe.name, 0, 8)}\S*\s+#{shared}\s+0\.0000/
  end

  @tag :tmp_dir
  test "a multi-entity row measures every expected slug; the other answer is not a competitor", %{
    tmp_dir: dir
  } do
    admin = admin()
    pad_thai = published_page(admin, %{title: "Pad Thai", slug: slug()})
    tom_yum = published_page(admin, %{title: "Tom Yum", slug: slug()})
    other = published_page(admin, %{title: "Something else", slug: slug()})
    KilnCMS.DataCase.drain_oban()

    set = golden(dir, [expects("Pad Thai", [pad_thai.slug, tom_yum.slug], "multi_entity")])
    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page"]) end)

    assert output =~ ~r/expected\s+page\s+#{pad_thai.slug}\s+0\.0000/
    assert output =~ ~r/expected\s+page\s+#{tom_yum.slug}\s+\d\.\d{4}/
    assert output =~ ~r/nearest ≠\s+page\s+#{other.slug}/
    refute output =~ ~r/nearest ≠\s+page\s+#{tom_yum.slug}/
  end

  @tag :tmp_dir
  test "an expected slug that does not exist is reported, not crashed on", %{tmp_dir: dir} do
    admin = admin()
    published_page(admin, %{title: "Alpha", slug: slug()})
    KilnCMS.DataCase.drain_oban()

    set = golden(dir, [expects("Alpha", "no-such-slug-anywhere", "single_entity")])
    output = capture_io(fn -> MeasureFloor.run([set, "--type", "page"]) end)

    assert output =~ "expected   NOT FOUND — no no-such-slug-anywhere"
    assert output =~ "Nothing to suggest"
  end

  @tag :tmp_dir
  test "refuses an unknown type, an invalid or empty set, an unknown org, a disabled embedder",
       %{tmp_dir: dir} do
    set = golden(dir, [expects("Alpha", "alpha", "single_entity")])

    assert_raise Mix.Error, ~r/Unknown content type "nope"/, fn ->
      capture_io(fn -> MeasureFloor.run([set, "--type", "nope"]) end)
    end

    assert_raise Mix.Error, ~r/no organization with slug "nope"/, fn ->
      capture_io(fn -> MeasureFloor.run([set, "--org", "nope"]) end)
    end

    # The eval harness's validation, naming the row: a junk row with slugs.
    bad = Path.join(dir, "bad.json")
    File.write!(bad, ~s|[{"query": "x", "expected": ["y"], "class": "junk"}]|)

    assert_raise Mix.Error, ~r/row 0: a junk row must expect nothing/, fn ->
      capture_io(fn -> MeasureFloor.run([bad]) end)
    end

    File.write!(bad, "[]")

    assert_raise Mix.Error, ~r/has no rows/, fn ->
      capture_io(fn -> MeasureFloor.run([bad]) end)
    end

    assert_raise Mix.Error, ~r/Cannot read/, fn ->
      capture_io(fn -> MeasureFloor.run([Path.join(dir, "missing.json")]) end)
    end

    assert_raise Mix.Error, ~r/Usage:/, fn -> MeasureFloor.run([]) end

    put_search_env(semantic: false)

    assert_raise Mix.Error, ~r/Semantic search is disabled/, fn ->
      MeasureFloor.run([set])
    end
  end
end
