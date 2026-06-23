defmodule KilnCMS.Search.CoverageTest do
  @moduledoc """
  Phase D (#7): media is searchable (filename/alt/caption) and
  `KilnCMS.Search.global/2` returns sectioned results across pages, posts, and
  media.
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
end
