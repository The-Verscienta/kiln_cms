defmodule KilnCMS.CMS.SearchFacetsTest do
  @moduledoc """
  Phase B: `:search` supports optional facets (category, tags, author, state),
  each skipped when nil, and a `highlight` calculation that wraps matched terms
  in `<mark>`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "facet-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "facet-#{uniq()}"

  defp search(params, actor) do
    KilnCMS.CMS.Page
    |> Ash.Query.for_read(:search, params)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  test "filters by category" do
    admin = admin()
    term = "quokka#{uniq()}"
    cat = CMS.create_category!(%{name: "Cat #{uniq()}", slug: slug()}, actor: admin)

    in_cat =
      CMS.create_page!(%{title: term, slug: slug(), category_id: cat.id}, actor: admin)

    _no_cat = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)

    ids = search(%{query: term, category_id: cat.id}, admin)
    assert ids == [in_cat.id]
  end

  test "filters by tag (content carrying any of the given tags)" do
    admin = admin()
    term = "narwhal#{uniq()}"
    tag = CMS.create_tag!(%{name: "Tag #{uniq()}", slug: slug()}, actor: admin)

    tagged =
      CMS.create_page!(%{title: term, slug: slug(), tag_ids: [tag.id]}, actor: admin)

    _untagged = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)

    ids = search(%{query: term, tag_ids: [tag.id]}, admin)
    assert ids == [tagged.id]
  end

  test "filters by author" do
    admin = admin()
    other = admin()
    term = "axolotl#{uniq()}"

    mine = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)
    _theirs = CMS.create_page!(%{title: term, slug: slug()}, actor: other)

    ids = search(%{query: term, author_id: admin.id}, admin)
    assert ids == [mine.id]
  end

  test "filters by workflow state" do
    admin = admin()
    term = "tapir#{uniq()}"

    draft = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)
    published = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)
    CMS.publish_page!(published, %{}, actor: admin)

    assert search(%{query: term, state: :published}, admin) == [published.id]
    assert search(%{query: term, state: :draft}, admin) == [draft.id]
  end

  test "no facets returns all matches" do
    admin = admin()
    term = "lemur#{uniq()}"
    a = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)
    b = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)

    ids = search(%{query: term}, admin)
    assert a.id in ids and b.id in ids
  end

  test "highlight wraps matched terms in <mark>" do
    admin = admin()
    term = "capybara#{uniq()}"
    CMS.create_page!(%{title: "The mighty #{term} swims", slug: slug()}, actor: admin)

    [page] =
      KilnCMS.CMS.Page
      |> Ash.Query.for_read(:search, %{query: term})
      |> Ash.Query.load(highlight: %{query: term, locale: "en"})
      |> Ash.read!(actor: admin)

    assert page.highlight =~ "<mark>#{term}</mark>"
  end
end
