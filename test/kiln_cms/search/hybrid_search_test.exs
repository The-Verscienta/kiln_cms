defmodule KilnCMS.Search.HybridTest do
  @moduledoc """
  `KilnCMS.Search.hybrid/3` fuses the keyword (`ts_rank`) and semantic (cosine)
  legs by Reciprocal Rank Fusion: a record matched by both legs outranks one
  matched by a single leg, results are deduplicated, and with semantic search
  disabled it degrades to keyword-only. Uses a deterministic stub embedder.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search

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
      email: "hyb-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "hyb-#{System.unique_integer([:positive])}"

  defp ids(records), do: Enum.map(records, & &1.id)

  test "a record matched by both legs ranks above a semantic-only match" do
    admin = admin()
    # Matches the keyword query "alpha" and embeds to the query's exact vector.
    both = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
    # Doesn't contain "alpha" (no keyword hit), but is still an embedded
    # candidate in the semantic leg.
    semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    results = Search.hybrid(:page, "alpha", actor: admin)
    result_ids = ids(results)

    assert hd(result_ids) == both.id
    assert semantic_only.id in result_ids
    # Deduplicated even though `both` appears in both legs.
    assert Enum.count(result_ids, &(&1 == both.id)) == 1
  end

  test "degrades to keyword-only when semantic search is disabled" do
    admin = admin()
    both = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
    semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    put_search_env(semantic: false)
    result_ids = Search.hybrid(:page, "alpha", actor: admin) |> ids()

    # Only the keyword match survives; the semantic-only candidate is gone.
    assert both.id in result_ids
    refute semantic_only.id in result_ids
  end

  test "respects the :limit option" do
    admin = admin()

    for n <- 1..5 do
      CMS.create_page!(%{title: "alpha #{n}", slug: slug()}, actor: admin)
    end

    KilnCMS.DataCase.drain_oban()

    assert length(Search.hybrid(:page, "alpha", actor: admin, limit: 3)) == 3
  end

  test "resolves dynamic types and the entry tier (not just :page/:post)" do
    admin = admin()

    definition =
      CMS.create_type_definition!(
        %{name: "hy#{System.unique_integer([:positive])}", label: "Hy"},
        actor: admin
      )

    entry =
      KilnCMS.CMS.ContentTypes.create!(definition.name, %{title: "alpha", slug: slug()},
        actor: admin
      )

    KilnCMS.DataCase.drain_oban()

    # By dynamic type name string and by the entry resource itself.
    assert entry.id in (Search.hybrid(definition.name, "alpha", actor: admin) |> ids())
    assert entry.id in (Search.hybrid(KilnCMS.CMS.Entry, "alpha", actor: admin) |> ids())
  end

  test "a typo is rescued by the fuzzy leg when the keyword leg comes up short" do
    admin = admin()
    # "fermentaton" survives stemming as its own token (no tsquery match) but
    # is trigram-close to "fermentation" — the keyword leg is empty, so the
    # fuzzy fallback fires and rescues the hit.
    page = CMS.create_page!(%{title: "Fermentation Guide", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    put_search_env(semantic: false)

    assert page.id in (Search.hybrid(:page, "fermentaton", actor: admin) |> ids())
  end

  test "the fuzzy leg stays out when the keyword leg has enough hits" do
    admin = admin()

    for n <- 1..3 do
      CMS.create_page!(%{title: "alpha #{n}", slug: slug()}, actor: admin)
    end

    # Matches the fuzzy leg (title ILIKE "alpha%") but not the keyword leg
    # ("alphaa" doesn't stem to "alpha") — it can only surface if the fallback
    # runs, which the three keyword hits keep switched off.
    near_miss = CMS.create_page!(%{title: "alphaa", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    put_search_env(semantic: false)

    refute near_miss.id in (Search.hybrid(:page, "alpha", actor: admin) |> ids())
  end

  test "global/2 sections are hybrid: semantic-only matches surface" do
    admin = admin()
    keyword_hit = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
    # No keyword overlap with the query — reachable only through the
    # semantic leg, which the old keyword-only global/2 never ran.
    semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    sections = Search.global("alpha", actor: admin)
    page_ids = ids(sections.pages)

    assert keyword_hit.id in page_ids
    assert semantic_only.id in page_ids
  end
end
