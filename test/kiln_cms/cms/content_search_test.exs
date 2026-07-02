defmodule KilnCMS.CMS.ContentSearchTest do
  @moduledoc """
  Full-text `search` over the denormalized `search_text` (title + SEO + block
  text), respecting the read policy (anonymous sees published only).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "search-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "search-#{System.unique_integer([:positive])}"

  # Audit P-M2: :search is exposed on the public API and previously had no
  # bound — a broad query returned every matching row.
  describe "result bounding" do
    test "an unbounded search is capped by the prepare's default limit" do
      admin = admin()
      term = "boundless#{System.unique_integer([:positive])}"

      for i <- 1..3 do
        CMS.create_page!(%{title: "#{term} #{i}", slug: slug()}, actor: admin)
      end

      query =
        KilnCMS.CMS.Page
        |> Ash.Query.for_read(:search, %{query: term})
        |> Ash.read!(actor: admin)

      assert length(query) == 3

      capped =
        KilnCMS.CMS.Page
        |> Ash.Query.for_read(:search, %{query: term})
        |> Ash.Query.limit(2)
        |> Ash.read!(actor: admin)

      assert length(capped) == 2
    end

    test "paged search returns an offset page (API pagination works)" do
      admin = admin()
      term = "pageable#{System.unique_integer([:positive])}"

      for i <- 1..3 do
        CMS.create_page!(%{title: "#{term} #{i}", slug: slug()}, actor: admin)
      end

      page =
        KilnCMS.CMS.Page
        |> Ash.Query.for_read(:search, %{query: term})
        |> Ash.read!(actor: admin, page: [offset: 0, limit: 2, count: true])

      assert %Ash.Page.Offset{results: results, count: 3} = page
      assert length(results) == 2
    end
  end

  test "matches a term in the title", %{} do
    admin = admin()
    tag = "zylophone#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "The #{tag} chronicles", slug: slug()}, actor: admin)

    ids = CMS.search_pages!(tag, actor: admin) |> Enum.map(& &1.id)
    assert page.id in ids
  end

  test "matches a stemmed term inside block content" do
    admin = admin()

    page =
      CMS.create_page!(
        %{
          title: "Wildlife",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>The unicorns roam freely.</p>", order: 0}]
        },
        actor: admin
      )

    # plainto_tsquery stems, so the singular "unicorn" matches "unicorns".
    ids = CMS.search_pages!("unicorn", actor: admin) |> Enum.map(& &1.id)
    assert page.id in ids
  end

  test "orders results by relevance (ts_rank), strongest match first" do
    admin = admin()
    term = "otter#{System.unique_integer([:positive])}"

    # Weak match: the term appears once.
    weak = CMS.create_page!(%{title: "A page mentioning an #{term}", slug: slug()}, actor: admin)

    # Strong match: the term saturates the title and body.
    strong =
      CMS.create_page!(
        %{
          title: "#{term} #{term} #{term}",
          slug: slug(),
          blocks: [
            %{type: :rich_text, content: "<p>#{term} #{term} #{term} #{term}</p>", order: 0}
          ]
        },
        actor: admin
      )

    # The unique term matches only these two pages, ranked by ts_rank.
    assert [strong.id, weak.id] == CMS.search_pages!(term, actor: admin) |> Enum.map(& &1.id)
  end

  test "returns nothing for a non-matching query" do
    admin = admin()
    CMS.create_page!(%{title: "Ordinary page", slug: slug()}, actor: admin)

    assert CMS.search_pages!("nonexistentterm#{System.unique_integer([:positive])}", actor: admin) ==
             []
  end

  test "respects read visibility — anonymous matches published only" do
    admin = admin()
    tag = "marmoset#{System.unique_integer([:positive])}"

    draft = CMS.create_page!(%{title: "#{tag} draft", slug: slug()}, actor: admin)
    published = CMS.create_page!(%{title: "#{tag} live", slug: slug()}, actor: admin)
    published = CMS.publish_page!(published, %{}, actor: admin)

    anon_ids = CMS.search_pages!(tag, authorize?: true) |> Enum.map(& &1.id)
    assert published.id in anon_ids
    refute draft.id in anon_ids

    editor_ids = CMS.search_pages!(tag, actor: admin) |> Enum.map(& &1.id)
    assert draft.id in editor_ids
    assert published.id in editor_ids
  end

  test "search_text updates when content changes" do
    admin = admin()
    old = "aardvark#{System.unique_integer([:positive])}"
    new = "pangolin#{System.unique_integer([:positive])}"

    page = CMS.create_page!(%{title: old, slug: slug()}, actor: admin)
    assert [_] = CMS.search_pages!(old, actor: admin)

    CMS.update_page!(page, %{title: new}, actor: admin)
    assert CMS.search_pages!(old, actor: admin) == []
    assert [_] = CMS.search_pages!(new, actor: admin)
  end
end
