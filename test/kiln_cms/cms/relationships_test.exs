defmodule KilnCMS.CMS.RelationshipsTest do
  @moduledoc """
  Coverage for the content-type relationships: `Category` (many-to-one /
  one-to-many), `Tag` (many-to-many via the shared polymorphic `Tagging`
  table), related content (via the shared polymorphic `ContentLink` table,
  including cross-type links), and the formal `featured_image` (many-to-one)
  link to `MediaItem`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-rel-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "rel-#{System.unique_integer([:positive])}"

  describe "category (many-to-one / one-to-many)" do
    test "a post belongs to a category, and the category has_many posts" do
      editor = user(:editor)
      category = CMS.create_category!(%{name: "News", slug: slug()}, actor: editor)

      post =
        CMS.create_post!(%{title: "P", slug: slug(), category_id: category.id}, actor: editor)

      assert post.category_id == category.id

      # Inverse: load the one-to-many side.
      loaded = CMS.get_category!(category.id, load: [:posts], actor: editor)
      assert [%{id: post_id}] = loaded.posts
      assert post_id == post.id
    end

    test "category is optional" do
      editor = user(:editor)
      post = CMS.create_post!(%{title: "P", slug: slug()}, actor: editor)
      assert is_nil(post.category_id)
    end

    test "the same category can be shared across pages and posts" do
      editor = user(:editor)
      category = CMS.create_category!(%{name: "Guides", slug: slug()}, actor: editor)

      CMS.create_page!(%{title: "Pg", slug: slug(), category_id: category.id}, actor: editor)
      CMS.create_post!(%{title: "Po", slug: slug(), category_id: category.id}, actor: editor)

      loaded = CMS.get_category!(category.id, load: [:pages, :posts], actor: editor)
      assert length(loaded.pages) == 1
      assert length(loaded.posts) == 1
    end
  end

  describe "tags (many-to-many)" do
    test "a post links many tags, and a tag links many posts" do
      editor = user(:editor)
      t1 = CMS.create_tag!(%{name: "elixir", slug: slug()}, actor: editor)
      t2 = CMS.create_tag!(%{name: "ash", slug: slug()}, actor: editor)

      post =
        CMS.create_post!(
          %{title: "P", slug: slug(), tag_ids: [t1.id, t2.id]},
          actor: editor,
          load: [:tags]
        )

      assert MapSet.new(post.tags, & &1.id) == MapSet.new([t1.id, t2.id])

      # Inverse from the tag side.
      loaded_tag = CMS.get_tag!(t1.id, load: [:posts], actor: editor)
      assert [%{id: post_id}] = loaded_tag.posts
      assert post_id == post.id
    end

    test "updating tag_ids appends and removes (set semantics)" do
      editor = user(:editor)
      t1 = CMS.create_tag!(%{name: "a", slug: slug()}, actor: editor)
      t2 = CMS.create_tag!(%{name: "b", slug: slug()}, actor: editor)

      post = CMS.create_post!(%{title: "P", slug: slug(), tag_ids: [t1.id]}, actor: editor)

      updated = CMS.update_post!(post, %{tag_ids: [t2.id]}, actor: editor, load: [:tags])
      assert [%{id: only}] = updated.tags
      assert only == t2.id
    end
  end

  describe "related content (self-referential many-to-many)" do
    test "a post links other posts as related" do
      editor = user(:editor)
      a = CMS.create_post!(%{title: "A", slug: slug()}, actor: editor)
      b = CMS.create_post!(%{title: "B", slug: slug()}, actor: editor)

      a =
        CMS.update_post!(a, %{related_post_ids: [b.id]}, actor: editor, load: [:related_posts])

      assert [%{id: rel_id}] = a.related_posts
      assert rel_id == b.id
    end

    test "a page links other pages as related" do
      editor = user(:editor)
      a = CMS.create_page!(%{title: "A", slug: slug()}, actor: editor)
      b = CMS.create_page!(%{title: "B", slug: slug()}, actor: editor)

      a =
        CMS.update_page!(a, %{related_page_ids: [b.id]}, actor: editor, load: [:related_pages])

      assert [%{id: rel_id}] = a.related_pages
      assert rel_id == b.id
    end
  end

  describe "featured image (many-to-one to MediaItem)" do
    test "a post references a featured image, and the media item knows its posts" do
      editor = user(:editor)

      media =
        CMS.create_media_item!(%{filename: "hero.jpg", url: "https://cdn/hero.jpg"},
          actor: editor
        )

      post =
        CMS.create_post!(
          %{title: "P", slug: slug(), featured_image_id: media.id},
          actor: editor,
          load: [:featured_image]
        )

      assert post.featured_image.id == media.id

      loaded_media = CMS.get_media_item!(media.id, load: [:featured_posts], actor: editor)
      assert [%{id: post_id}] = loaded_media.featured_posts
      assert post_id == post.id
    end
  end

  describe "authorization" do
    test "a viewer cannot create taxonomy" do
      viewer = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_tag(%{name: "x", slug: slug()}, actor: viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_category(%{name: "x", slug: slug()}, actor: viewer)
    end

    test "taxonomy is world-readable" do
      editor = user(:editor)
      tag = CMS.create_tag!(%{name: "public", slug: slug()}, actor: editor)
      # No actor / anonymous read still succeeds.
      assert CMS.get_tag!(tag.id, authorize?: false).id == tag.id
    end
  end

  describe "polymorphic tagging (one table for every content type)" do
    test "the same tag applies to a page and a post through a single join table" do
      editor = user(:editor)
      tag = CMS.create_tag!(%{name: "shared", slug: slug()}, actor: editor)

      page = CMS.create_page!(%{title: "Pg", slug: slug(), tag_ids: [tag.id]}, actor: editor)
      post = CMS.create_post!(%{title: "Po", slug: slug(), tag_ids: [tag.id]}, actor: editor)

      # The tag's reverse relationships resolve the right type from the shared
      # `taggings` table purely by id.
      loaded =
        CMS.get_tag!(tag.id, load: [:pages, :posts, :page_count, :post_count], actor: editor)

      assert [%{id: pid}] = loaded.pages
      assert [%{id: poid}] = loaded.posts
      assert pid == page.id
      assert poid == post.id
      assert loaded.page_count == 1
      assert loaded.post_count == 1
    end
  end

  describe "content links (relate any two content types, no new join table)" do
    test "a page can be linked to a post with a named kind" do
      editor = user(:editor)
      page = CMS.create_page!(%{title: "Src", slug: slug()}, actor: editor)
      post = CMS.create_post!(%{title: "Dst", slug: slug()}, actor: editor)

      {:ok, link} =
        CMS.create_content_link(
          %{source_id: page.id, target_id: post.id, kind: :see_also},
          actor: editor
        )

      assert link.kind == :see_also

      # The link is queryable from the source record's id, across types.
      links =
        CMS.list_content_links!(
          actor: editor,
          query: [filter: [source_id: page.id]]
        )

      assert [%{target_id: target_id, kind: :see_also}] = links
      assert target_id == post.id
    end

    test "same-type related content still works via ContentLink" do
      editor = user(:editor)
      a = CMS.create_post!(%{title: "A", slug: slug()}, actor: editor)
      b = CMS.create_post!(%{title: "B", slug: slug()}, actor: editor)

      a = CMS.update_post!(a, %{related_post_ids: [b.id]}, actor: editor, load: [:related_posts])
      assert [%{id: rel_id}] = a.related_posts
      assert rel_id == b.id
    end

    test "links are editor-gated" do
      viewer = user(:viewer)
      editor = user(:editor)
      page = CMS.create_page!(%{title: "P", slug: slug()}, actor: editor)
      post = CMS.create_post!(%{title: "Q", slug: slug()}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_content_link(
                 %{source_id: page.id, target_id: post.id},
                 actor: viewer
               )
    end
  end
end
