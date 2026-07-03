defmodule KilnCMS.Search.FacetsTest do
  @moduledoc """
  Facet counts (`KilnCMS.Search.facets/2`) and facet *filtering* through
  `hybrid/3`/`global/2` (`:filters`): counts are computed over the
  policy-respecting match set (anonymous callers only count published
  documents), and a category filter narrows every content section.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fac-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "fac-#{uniq()}"

  test "counts categories and tags over the match set, sorted by count" do
    admin = admin()
    term = "quasar#{uniq()}"

    news = CMS.create_category!(%{name: "News #{uniq()}", slug: slug()}, actor: admin)
    guides = CMS.create_category!(%{name: "Guides #{uniq()}", slug: slug()}, actor: admin)
    tag = CMS.create_tag!(%{name: "hot-#{uniq()}", slug: slug()}, actor: admin)

    for n <- 1..2 do
      CMS.create_page!(
        %{title: "#{term} news #{n}", slug: slug(), category_id: news.id},
        actor: admin
      )
    end

    CMS.create_page!(
      %{title: "#{term} guide", slug: slug(), category_id: guides.id, tag_ids: [tag.id]},
      actor: admin
    )

    # Same term, different category axis — posts count into the same facets.
    CMS.create_post!(%{title: "#{term} post", slug: slug(), category_id: news.id}, actor: admin)

    %{categories: categories, tags: tags} = Search.facets(term, actor: admin)

    assert [%{id: news_id, count: 3}, %{id: guides_id, count: 1}] =
             Enum.filter(categories, &(&1.id in [news.id, guides.id]))

    assert news_id == news.id
    assert guides_id == guides.id
    assert [%{count: 1, name: _, slug: _}] = Enum.filter(tags, &(&1.id == tag.id))
  end

  test "anonymous facet counts only see published documents" do
    admin = admin()
    term = "pulsar#{uniq()}"
    cat = CMS.create_category!(%{name: "Cat #{uniq()}", slug: slug()}, actor: admin)

    published =
      CMS.create_page!(%{title: "#{term} live", slug: slug(), category_id: cat.id}, actor: admin)

    CMS.publish_page!(published, %{}, actor: admin)

    _draft =
      CMS.create_page!(
        %{title: "#{term} draft", slug: slug(), category_id: cat.id},
        actor: admin
      )

    %{categories: categories} = Search.facets(term, authorize?: true)

    assert [%{count: 1}] = Enum.filter(categories, &(&1.id == cat.id))
  end

  test "hybrid/3 narrows both legs by :filters and benches the fuzzy leg" do
    admin = admin()
    term = "nebula#{uniq()}"
    cat = CMS.create_category!(%{name: "Cat #{uniq()}", slug: slug()}, actor: admin)

    inside =
      CMS.create_page!(%{title: "#{term} inside", slug: slug(), category_id: cat.id},
        actor: admin
      )

    outside = CMS.create_page!(%{title: "#{term} outside", slug: slug()}, actor: admin)

    ids =
      Search.hybrid(:page, term, actor: admin, filters: %{category_id: cat.id})
      |> Enum.map(& &1.id)

    assert inside.id in ids
    refute outside.id in ids
  end

  test "global/2 threads :filters into every content section" do
    admin = admin()
    term = "comet#{uniq()}"
    cat = CMS.create_category!(%{name: "Cat #{uniq()}", slug: slug()}, actor: admin)

    inside =
      CMS.create_post!(%{title: "#{term} inside", slug: slug(), category_id: cat.id},
        actor: admin
      )

    outside = CMS.create_post!(%{title: "#{term} outside", slug: slug()}, actor: admin)

    sections = Search.global(term, actor: admin, filters: %{category_id: cat.id})
    ids = Enum.map(sections.posts, & &1.id)

    assert inside.id in ids
    refute outside.id in ids
  end
end
