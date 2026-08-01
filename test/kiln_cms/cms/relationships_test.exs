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

  defp tag_ids(record), do: MapSet.new(record.tags, & &1.id)

  defp current_tags(post, actor),
    do: post.id |> CMS.get_post!(actor: actor, load: [:tags]) |> tag_ids()

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

      assert tag_ids(post) == MapSet.new([t1.id, t2.id])

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

  # #521: `tag_ids` is the complete set, so every partial-update caller
  # (REST/GraphQL/MCP) detaches by omission. These two merge instead.
  describe "add_tag_ids / remove_tag_ids (merge semantics, #521)" do
    setup do
      editor = user(:editor)
      a = CMS.create_tag!(%{name: "a", slug: slug()}, actor: editor)
      b = CMS.create_tag!(%{name: "b", slug: slug()}, actor: editor)
      c = CMS.create_tag!(%{name: "c", slug: slug()}, actor: editor)

      post =
        CMS.create_post!(%{title: "P", slug: slug(), tag_ids: [a.id, b.id]}, actor: editor)

      %{editor: editor, a: a, b: b, c: c, post: post}
    end

    test "add_tag_ids attaches without detaching the rest", ctx do
      updated =
        CMS.update_post!(ctx.post, %{add_tag_ids: [ctx.c.id]},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id, ctx.c.id])
    end

    test "add_tag_ids is idempotent for an already-attached tag", ctx do
      updated =
        CMS.update_post!(ctx.post, %{add_tag_ids: [ctx.a.id]},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    test "add_tag_ids rejects an unknown id rather than silently dropping it", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_post(ctx.post, %{add_tag_ids: [Ash.UUID.generate()]}, actor: ctx.editor)
    end

    test "remove_tag_ids detaches only what is listed", ctx do
      updated =
        CMS.update_post!(ctx.post, %{remove_tag_ids: [ctx.a.id]},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.b.id])
    end

    test "remove_tag_ids is a no-op for a tag that is not attached", ctx do
      updated =
        CMS.update_post!(ctx.post, %{remove_tag_ids: [ctx.c.id]},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    # The load-bearing version of the two idempotency tests above: a mixed list
    # has to detach the attached id and skip the rest, which an implementation
    # that simply ignored the argument could not fake.
    test "remove_tag_ids applies the attached ids and skips the rest", ctx do
      updated =
        CMS.update_post!(
          ctx.post,
          %{remove_tag_ids: [ctx.a.id, ctx.c.id, Ash.UUID.generate()]},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.b.id])
    end

    test "a repeated id in one list is de-duplicated, not a constraint error", ctx do
      updated =
        CMS.update_post!(ctx.post, %{add_tag_ids: [ctx.c.id, ctx.c.id]},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id, ctx.c.id])
    end

    test "add and remove apply together in one write", ctx do
      updated =
        CMS.update_post!(ctx.post, %{add_tag_ids: [ctx.c.id], remove_tag_ids: [ctx.a.id]},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.b.id, ctx.c.id])
    end

    test "a metadata-only update still leaves tags untouched", ctx do
      updated =
        CMS.update_post!(ctx.post, %{title: "Retitled"}, actor: ctx.editor, load: [:tags])

      assert tag_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    test "combining tag_ids with a merge verb is refused", ctx do
      for params <- [
            %{tag_ids: [ctx.a.id], add_tag_ids: [ctx.c.id]},
            %{tag_ids: [ctx.a.id], remove_tag_ids: [ctx.b.id]},
            %{tag_ids: [], add_tag_ids: [ctx.c.id]}
          ] do
        assert {:error, error} = CMS.update_post(ctx.post, params, actor: ctx.editor)
        assert Exception.message(error) =~ "cannot be combined", inspect(params)
      end

      # Still attached — the refusal is a validation, not a partial write.
      assert current_tags(ctx.post, ctx.editor) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    # The regression this whole describe exists for. `tag_ids: nil` is NOT
    # "omitted": Ash `List.wrap`s it to `[]` and `:append_and_remove` clears
    # the set — so reading null as absent would let the guard pass and detach
    # everything, which is exactly the #521 bug arriving through its own fix.
    # A generated client that serializes unset fields as null sends this shape.
    test "an explicit tag_ids: nil counts as combining, and changes nothing", ctx do
      assert {:error, error} =
               CMS.update_post(ctx.post, %{tag_ids: nil, add_tag_ids: [ctx.c.id]},
                 actor: ctx.editor
               )

      assert Exception.message(error) =~ "cannot be combined"
      assert current_tags(ctx.post, ctx.editor) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    # The mirror of the above: empty merge lists carry no intent, so a client
    # that always serializes all three keys must still reach the replace path.
    test "empty merge lists do not conflict with tag_ids", ctx do
      updated =
        CMS.update_post!(
          ctx.post,
          %{tag_ids: [ctx.c.id], add_tag_ids: [], remove_tag_ids: []},
          actor: ctx.editor,
          load: [:tags]
        )

      assert tag_ids(updated) == MapSet.new([ctx.c.id])
    end

    test "listing the same id in both verbs is refused", ctx do
      assert {:error, error} =
               CMS.update_post(ctx.post, %{add_tag_ids: [ctx.c.id], remove_tag_ids: [ctx.c.id]},
                 actor: ctx.editor
               )

      assert Exception.message(error) =~ "same tag"
      assert current_tags(ctx.post, ctx.editor) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    # `Exception.message/1` is what AshAi hands back to a model on a rejected
    # MCP tool call, so a stray `nil` from an unset `value:` lands in the LLM's
    # context as if it were part of the explanation.
    test "the refusal message carries no stray inspect output", ctx do
      assert {:error, error} =
               CMS.update_post(ctx.post, %{tag_ids: [ctx.a.id], add_tag_ids: [ctx.c.id]},
                 actor: ctx.editor
               )

      refute Exception.message(error) =~ ~r/\bnil\b/
    end

    test "the merge verbs are on pages too, not just posts", ctx do
      page =
        CMS.create_page!(%{title: "Pg", slug: slug(), tag_ids: [ctx.a.id]}, actor: ctx.editor)

      updated =
        CMS.update_page!(page, %{add_tag_ids: [ctx.b.id]}, actor: ctx.editor, load: [:tags])

      assert tag_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    # The dynamic tier (D17) shares the macro but has its own generic API and
    # MCP surface, and `cms.ex` advertises `update_entry`'s merge verbs — so it
    # needs its own assertion rather than riding on the compiled types'.
    test "the merge verbs reach the dynamic entry tier", ctx do
      admin = user(:admin)

      type =
        CMS.create_type_definition!(
          %{name: "recipe_#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      entry =
        CMS.create_entry!(
          %{title: "E", slug: slug(), type_definition_id: type.id, tag_ids: [ctx.a.id]},
          actor: admin
        )

      updated = CMS.update_entry!(entry, %{add_tag_ids: [ctx.b.id]}, actor: admin, load: [:tags])
      assert tag_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id])
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
