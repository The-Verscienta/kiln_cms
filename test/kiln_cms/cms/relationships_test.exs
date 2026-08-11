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

      assert Exception.message(error) =~ "cannot list the same id as add_tag_ids"
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

  # The same non-destructive merge verbs the tags got in #521, generalized to
  # the related-content arrays (#637). Before this, a partial writer sending
  # `related_post_ids: ["<one>"]` detached every other related link by omission,
  # with no verb to add or remove one link in isolation.
  describe "add_related_*_ids / remove_related_*_ids (merge semantics, #637)" do
    setup do
      editor = user(:editor)
      post = CMS.create_post!(%{title: "Src", slug: slug()}, actor: editor)
      a = CMS.create_post!(%{title: "A", slug: slug()}, actor: editor)
      b = CMS.create_post!(%{title: "B", slug: slug()}, actor: editor)
      c = CMS.create_post!(%{title: "C", slug: slug()}, actor: editor)

      post =
        CMS.update_post!(post, %{related_post_ids: [a.id, b.id]},
          actor: editor,
          load: [:related_posts]
        )

      %{editor: editor, post: post, a: a, b: b, c: c}
    end

    defp related_ids(record), do: MapSet.new(record.related_posts, & &1.id)

    defp current_related(post, actor),
      do: post.id |> CMS.get_post!(actor: actor, load: [:related_posts]) |> related_ids()

    test "add relates the listed link and leaves the rest attached", ctx do
      updated =
        CMS.update_post!(ctx.post, %{add_related_post_ids: [ctx.c.id]},
          actor: ctx.editor,
          load: [:related_posts]
        )

      assert related_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id, ctx.c.id])
    end

    test "remove unrelates the listed link and is idempotent", ctx do
      once =
        CMS.update_post!(ctx.post, %{remove_related_post_ids: [ctx.a.id]},
          actor: ctx.editor,
          load: [:related_posts]
        )

      assert related_ids(once) == MapSet.new([ctx.b.id])

      # Removing an already-detached link is a no-op, not an error.
      twice =
        CMS.update_post!(once, %{remove_related_post_ids: [ctx.a.id]},
          actor: ctx.editor,
          load: [:related_posts]
        )

      assert related_ids(twice) == MapSet.new([ctx.b.id])
    end

    test "a metadata-only update leaves the related links untouched", ctx do
      updated =
        CMS.update_post!(ctx.post, %{title: "Retitled"},
          actor: ctx.editor,
          load: [:related_posts]
        )

      assert related_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    test "combining related_post_ids with a merge verb is refused", ctx do
      for params <- [
            %{related_post_ids: [ctx.a.id], add_related_post_ids: [ctx.c.id]},
            %{related_post_ids: [ctx.a.id], remove_related_post_ids: [ctx.b.id]},
            # An explicit null still counts as replacing — the #521 SDK shape.
            %{related_post_ids: nil, add_related_post_ids: [ctx.c.id]}
          ] do
        assert {:error, error} = CMS.update_post(ctx.post, params, actor: ctx.editor)
        assert Exception.message(error) =~ "cannot be combined", inspect(params)
      end

      assert current_related(ctx.post, ctx.editor) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    test "listing the same id in both verbs is refused", ctx do
      assert {:error, error} =
               CMS.update_post(
                 ctx.post,
                 %{add_related_post_ids: [ctx.c.id], remove_related_post_ids: [ctx.c.id]},
                 actor: ctx.editor
               )

      assert Exception.message(error) =~ "cannot list the same id as add_related_post_ids"
      assert current_related(ctx.post, ctx.editor) == MapSet.new([ctx.a.id, ctx.b.id])
    end

    test "a repeated id within one verb is de-duplicated, not rejected", ctx do
      updated =
        CMS.update_post!(ctx.post, %{add_related_post_ids: [ctx.c.id, ctx.c.id]},
          actor: ctx.editor,
          load: [:related_posts]
        )

      assert related_ids(updated) == MapSet.new([ctx.a.id, ctx.b.id, ctx.c.id])
    end

    test "the verbs are on pages too, keyed to the page relationship", ctx do
      p1 = CMS.create_page!(%{title: "P1", slug: slug()}, actor: ctx.editor)
      p2 = CMS.create_page!(%{title: "P2", slug: slug()}, actor: ctx.editor)

      p1 =
        CMS.update_page!(p1, %{related_page_ids: [p2.id]},
          actor: ctx.editor,
          load: [:related_pages]
        )

      p3 = CMS.create_page!(%{title: "P3", slug: slug()}, actor: ctx.editor)

      updated =
        CMS.update_page!(p1, %{add_related_page_ids: [p3.id]},
          actor: ctx.editor,
          load: [:related_pages]
        )

      assert MapSet.new(updated.related_pages, & &1.id) == MapSet.new([p2.id, p3.id])
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

  # #639: the merge machinery is emitted from one `mergeable` list in
  # `KilnCMS.CMS.Content`, rather than hand-written per relationship per action.
  # These assert the properties that hand-writing could break — and did come
  # close to: `:update` and `:autosave` previously declared the same six
  # arguments in two different orders, which is the same drift one step short of
  # a missing one.
  describe "the merge machinery is generated, not hand-written (#639)" do
    # `Entry` too, and it is the one that matters most: it backs every
    # admin-defined content type, so a shape that drifts there drifts for types
    # nobody wrote a test for.
    @content_resources [KilnCMS.CMS.Page, KilnCMS.CMS.Post, KilnCMS.CMS.Entry]

    defp merge_arguments(resource, action) do
      resource
      |> Ash.Resource.Info.action(action)
      |> Map.fetch!(:arguments)
      |> Enum.map(& &1.name)
      |> Enum.filter(&(to_string(&1) =~ ~r/_ids$/))
    end

    defp merge_entities(resource, action) do
      resource
      |> Ash.Resource.Info.action(action)
      |> Map.fetch!(:changes)
      |> Enum.flat_map(fn
        %Ash.Resource.Change{change: {Ash.Resource.Change.ManageRelationship, opts}} ->
          [{:manage, opts[:argument], opts[:relationship], opts[:opts]}]

        %Ash.Resource.Change{change: {KilnCMS.CMS.Changes.NormalizeManagedArguments, opts}} ->
          [{:normalize, opts[:arguments]}]

        %Ash.Resource.Validation{validation: {KilnCMS.CMS.Validations.MergeArguments, opts}} ->
          [{:merge_validation, opts[:complete], opts[:add], opts[:remove]}]

        _other ->
          []
      end)
    end

    # The asymmetry that mattered: `ContentEditorLive` feeds `:autosave` the
    # params it collected for the `:update` form, so a merge argument on one and
    # not the other fails every debounce with `NoSuchInput` while explicit Save
    # keeps working.
    test ":update and :autosave accept the same merge arguments" do
      for resource <- @content_resources do
        assert merge_arguments(resource, :update) == merge_arguments(resource, :autosave),
               "#{inspect(resource)}: :update and :autosave disagree on merge arguments"
      end
    end

    # `:create` takes the complete-set arguments but none of the verbs — there
    # are no existing links to merge against. What it must NOT do is miss a
    # relationship the other two accept: a headless create passing `author_ids`
    # would fail with `NoSuchInput` while the equivalent update succeeded.
    test ":create accepts every complete-set argument, and no verbs" do
      for resource <- @content_resources do
        completes =
          resource
          |> merge_arguments(:update)
          |> Enum.reject(&(to_string(&1) =~ ~r/^(add|remove)_/))

        assert merge_arguments(resource, :create) == completes,
               "#{inspect(resource)}: :create's merge arguments are not the complete-set " <>
                 "half of :update's"
      end
    end

    test ":update and :autosave manage those relationships identically" do
      for resource <- @content_resources do
        assert merge_entities(resource, :update) == merge_entities(resource, :autosave),
               "#{inspect(resource)}: :update and :autosave disagree on merge changes"
      end
    end

    # Every complete-set argument gets all three changes and a validation, and
    # every verb is derived from its own complete argument — the property that
    # makes adding a relationship one list entry rather than eight edits.
    test "each mergeable relationship gets the full quartet, with derived verbs" do
      for resource <- @content_resources, action <- [:update, :autosave] do
        entities = merge_entities(resource, action)

        completes =
          for {:merge_validation, complete, _add, _remove} <- entities, do: complete

        assert length(completes) >= 2, "#{inspect(resource)}.#{action}: no merge validations"

        for complete <- completes do
          add = :"add_#{complete}"
          remove = :"remove_#{complete}"

          assert {:merge_validation, complete, add, remove} in entities,
                 "#{inspect(resource)}.#{action}: #{complete}'s verbs are not derived from it"

          relationship =
            Enum.find_value(entities, fn
              {:manage, ^complete, rel, _opts} -> rel
              _ -> nil
            end)

          assert relationship, "#{inspect(resource)}.#{action}: #{complete} manages nothing"

          assert {:manage, complete, relationship, [type: :append_and_remove]} in entities
          assert {:manage, add, relationship, [type: :append]} in entities

          # Not `type: :remove` — its `on_no_match: :error` would make removing
          # an already-detached link a failure rather than a no-op.
          assert {:manage, remove, relationship,
                  [
                    on_lookup: :ignore,
                    on_match: :unrelate,
                    on_no_match: :ignore,
                    on_missing: :ignore
                  ]} in entities
        end
      end
    end

    # `NormalizeManagedArguments` snapshots the argument onto the changeset, so
    # a `manage_relationship` declared before it would read the raw value.
    test "normalization covers every merge argument, and precedes every manage" do
      for resource <- @content_resources, action <- [:update, :autosave] do
        entities = merge_entities(resource, action)

        normalize_at = Enum.find_index(entities, &match?({:normalize, _}, &1))
        assert normalize_at, "#{inspect(resource)}.#{action}: nothing normalizes the arguments"

        {:normalize, normalized} = Enum.at(entities, normalize_at)

        for {entity, index} <- Enum.with_index(entities),
            match?({:manage, _, _, _}, entity) do
          {:manage, argument, _rel, _opts} = entity

          assert index > normalize_at,
                 "#{inspect(resource)}.#{action}: #{argument} is managed before normalization"

          assert argument in normalized,
                 "#{inspect(resource)}.#{action}: #{argument} is managed but never normalized"
        end
      end
    end
  end
end
