defmodule KilnCMS.Search.CoverageTest do
  @moduledoc """
  Phase D (#7): media is searchable (filename/alt/caption), taxonomy is
  searchable (category/tag names, typo-tolerant), and
  `KilnCMS.Search.global/2` returns sectioned results across pages, posts,
  media, and taxonomy.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cov-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "cov-#{uniq()}"

  test "media is searchable by alt text" do
    admin = admin()
    term = "waterfall#{uniq()}"

    match =
      CMS.create_media_item!(
        %{filename: "img-#{uniq()}.png", alt: "A #{term} in the forest", url: "/u/#{uniq()}"},
        actor: admin
      )

    _other =
      CMS.create_media_item!(%{filename: "other.png", url: "/u/#{uniq()}"}, actor: admin)

    ids = CMS.search_media!(term, actor: admin) |> Enum.map(& &1.id)
    assert ids == [match.id]
  end

  test "global/2 returns sectioned results across pages, posts, and media" do
    admin = admin()
    term = "meridian#{uniq()}"

    page = CMS.create_page!(%{title: "#{term} page", slug: slug()}, actor: admin)
    post = CMS.create_post!(%{title: "#{term} post", slug: slug()}, actor: admin)

    media =
      CMS.create_media_item!(
        %{filename: "#{term}.png", alt: "#{term} shot", url: "/u/#{uniq()}"},
        actor: admin
      )

    results = Search.global(term, actor: admin)

    assert page.id in Enum.map(results.pages, & &1.id)
    assert post.id in Enum.map(results.posts, & &1.id)
    assert media.id in Enum.map(results.media, & &1.id)
  end

  test "global/2 covers taxonomy: categories and tags match by name" do
    admin = admin()
    term = "orchard#{uniq()}"

    category =
      CMS.create_category!(
        %{name: "#{term} ideas", slug: slug(), description: "Seasonal"},
        actor: admin
      )

    tag = CMS.create_tag!(%{name: "#{term}-tag", slug: slug()}, actor: admin)

    results = Search.global(term, actor: admin)

    assert category.id in Enum.map(results.categories, & &1.id)
    assert tag.id in Enum.map(results.tags, & &1.id)
  end

  test "category search matches descriptions and tolerates typos in names" do
    admin = admin()

    by_description =
      CMS.create_category!(
        %{name: "Misc #{uniq()}", slug: slug(), description: "All about viticulture"},
        actor: admin
      )

    # Same stemmer-proof typo pair as the suggestion tests: "fermentaton" is
    # trigram-close to "fermentation" but no keyword/substring match.
    by_typo =
      CMS.create_category!(%{name: "Fermentation #{uniq()}", slug: slug()}, actor: admin)

    assert by_description.id in ids(CMS.search_categories!("viticulture", actor: admin))
    assert by_typo.id in ids(CMS.search_categories!("fermentaton", actor: admin))
  end

  defp ids(records), do: Enum.map(records, & &1.id)
end
