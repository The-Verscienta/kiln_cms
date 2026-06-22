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
