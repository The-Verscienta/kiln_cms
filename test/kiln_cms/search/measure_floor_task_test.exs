defmodule KilnCMS.Search.MeasureFloorTaskTest do
  @moduledoc """
  `mix kiln.search.measure_floor` reads a query sheet, measures each query
  against the corpus by raw cosine distance, and proposes a floor between
  the expected records' band and the junk queries' band. Uses the
  deterministic stub embedder, so a query equal to a record's title lands at
  distance 0 and every other pairing at a fixed, non-zero distance.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias Mix.Tasks.Kiln.Search.MeasureFloor

  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(semantic: true, embedder: StubEmbedder)
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

  @tag :tmp_dir
  test "reports expected records against their competitors, junk, and a cutoff", %{
    tmp_dir: dir
  } do
    admin = admin()
    alpha = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
    beta = CMS.create_page!(%{title: "Beta", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    # The configured floor must be ignored by the measurement.
    put_search_env(semantic_max_distance: 0.0)

    sheet = Path.join(dir, "queries.tsv")

    File.write!(sheet, """
    # a comment, and a blank line

    Alpha\t#{alpha.slug}
    nothing like this exists
    """)

    output = capture_io(fn -> MeasureFloor.run([sheet, "--type", "page"]) end)

    assert output =~ ~s|"Alpha"  → expects #{alpha.slug}|
    assert output =~ ~r/expected\s+page\s+#{alpha.slug}\s+0\.0000\s+\(rank 1 of its type\)/
    assert output =~ ~r/nearest ≠\s+page\s+#{beta.slug}\s+\d\.\d{4}/
    assert output =~ ~s|"nothing like this exists"  → expects nothing|
    assert output =~ ~r/nearest\s+page\s+(#{alpha.slug}|#{beta.slug})\s+\d\.\d{4}/
    assert output =~ "configured floor: 0.0 (ignored here)"

    # "Alpha" sits at 0; the junk query's nearest neighbour is some way off,
    # so the bands separate and the midpoint is proposed.
    assert [_, midpoint] = Regex.run(~r/Suggested semantic_max_distance: (\d\.\d{4})/, output)

    {:ok, [{_title, junk_nearest} | _]} =
      KilnCMS.Search.semantic_distances(:page, "nothing like this exists", actor: admin)

    assert_in_delta String.to_float(midpoint), junk_nearest / 2, 1.0e-3
    assert output =~ "keeps every expected record and rejects every junk query"
  end

  @tag :tmp_dir
  test "says when the bands overlap and what each edge costs", %{tmp_dir: dir} do
    admin = admin()
    # Expected under a query that is NOT its title: a real, non-zero distance,
    # while a junk query's nearest neighbour is the same kind of distance —
    # under the stub embedder, no single cutoff separates the two.
    far = CMS.create_page!(%{title: "Far Away Record", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    sheet = Path.join(dir, "queries.tsv")
    File.write!(sheet, "a paraphrase of it\t#{far.slug}\nasdfghjkl zzqqxx\n")

    output = capture_io(fn -> MeasureFloor.run([sheet]) end)

    {:ok, [{_, expected_distance}]} =
      KilnCMS.Search.semantic_distances(:page, "a paraphrase of it", actor: admin)

    {:ok, [{_, junk_distance}]} =
      KilnCMS.Search.semantic_distances(:page, "asdfghjkl zzqqxx", actor: admin)

    if expected_distance < junk_distance do
      assert output =~ "keeps every expected record and rejects every junk query"
    else
      assert output =~ "no single value separates the bands"
      assert output =~ "keeps every expected record and admits 1 of 1 junk queries"
      assert output =~ "rejects every junk query and drops 1 of 1 expected records"
    end
  end

  @tag :tmp_dir
  test "an expected record beyond the nearest --limit is still measured", %{tmp_dir: dir} do
    admin = admin()
    target = CMS.create_page!(%{title: "Target", slug: slug()}, actor: admin)
    CMS.create_page!(%{title: "Decoy", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    sheet = Path.join(dir, "queries.tsv")
    File.write!(sheet, "Decoy\t#{target.slug}\n")

    output = capture_io(fn -> MeasureFloor.run([sheet, "--type", "page", "--limit", "1"]) end)

    assert output =~ ~r/expected\s+page\s+#{target.slug}\s+\d\.\d{4}\s+\(beyond the nearest rows/
    assert output =~ "No junk queries in the sheet"
  end

  @tag :tmp_dir
  test "an expected slug that does not exist is reported, not crashed on", %{tmp_dir: dir} do
    admin = admin()
    CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    sheet = Path.join(dir, "queries.tsv")
    File.write!(sheet, "Alpha\tno-such-slug-anywhere\n")

    output = capture_io(fn -> MeasureFloor.run([sheet, "--type", "page"]) end)

    assert output =~ "expected   NOT FOUND — no no-such-slug-anywhere"
    assert output =~ "Nothing to suggest"
  end

  @tag :tmp_dir
  test "refuses an unknown content type, an empty sheet, and a disabled embedder", %{
    tmp_dir: dir
  } do
    sheet = Path.join(dir, "queries.tsv")
    File.write!(sheet, "Alpha\n")

    assert_raise Mix.Error, ~r/Unknown content type "nope"/, fn ->
      capture_io(fn -> MeasureFloor.run([sheet, "--type", "nope"]) end)
    end

    File.write!(sheet, "# only a comment\n\n")

    assert_raise Mix.Error, ~r/holds no queries/, fn ->
      capture_io(fn -> MeasureFloor.run([sheet]) end)
    end

    assert_raise Mix.Error, ~r/Cannot read/, fn ->
      capture_io(fn -> MeasureFloor.run([Path.join(dir, "missing.tsv")]) end)
    end

    assert_raise Mix.Error, ~r/Usage:/, fn -> MeasureFloor.run([]) end

    put_search_env(semantic: false)

    assert_raise Mix.Error, ~r/Semantic search is disabled/, fn ->
      MeasureFloor.run([sheet])
    end
  end
end
