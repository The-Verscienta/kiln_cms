defmodule KilnCMS.CMS.RestoreVersionTest do
  @moduledoc """
  `restore_version` reverts a Page/Post's content to a prior PaperTrail
  version (reconstructed by replaying changes_only versions), captured as a new
  version, leaving workflow state untouched.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.VersionDiff
  alias KilnCMS.CMS.VersionFields

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rv-#{System.unique_integer([:positive])}"

  defp versions(page, admin) do
    CMS.list_page_versions!(actor: admin)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  test "restores title and blocks to a previous version" do
    admin = admin()

    page =
      CMS.create_page!(
        %{
          title: "Alpha",
          slug: slug(),
          blocks: [%{type: :heading, content: "Original", order: 0}]
        },
        actor: admin
      )

    page =
      CMS.update_page!(
        page,
        %{title: "Beta", blocks: [%{type: :heading, content: "Changed", order: 0}]},
        actor: admin
      )

    page = CMS.update_page!(page, %{title: "Gamma"}, actor: admin)
    assert page.title == "Gamma"

    [create_version | _] = versions(page, admin)

    restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

    assert restored.title == "Alpha"

    # Blocks are stored as the typed union (Kiln v2); read back as legacy maps.
    assert [%{content: "Original"}] =
             restored.blocks
             |> KilnCMS.CMS.TypedBlocks.to_typed()
             |> KilnCMS.CMS.TypedBlocks.to_legacy()
  end

  test "restoring to an intermediate version reconstructs that state" do
    admin = admin()
    page = CMS.create_page!(%{title: "One", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "Two"}, actor: admin)
    page = CMS.update_page!(page, %{title: "Three"}, actor: admin)

    [_create, second, _third] = versions(page, admin)

    restored = CMS.restore_page_version!(page, %{version_id: second.id}, actor: admin)
    assert restored.title == "Two"
  end

  test "the restore is itself recorded as a new version" do
    admin = admin()
    page = CMS.create_page!(%{title: "First", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "Second"}, actor: admin)

    [create_version | _] = versions(page, admin)
    CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

    # create + update + restore = 3 versions
    assert length(versions(page, admin)) == 3
  end

  test "restoring a coalesced autosave version reconstructs the whole run" do
    admin = admin()
    page = CMS.create_page!(%{title: "Start", slug: slug()}, actor: admin)

    # A run of autosaves touching different fields collapses (issue #32) to a
    # single version — which must still carry the cumulative delta so a restore
    # reconstructs every field, not just the last one changed.
    page = Ash.update!(page, %{title: "Edited title"}, action: :autosave, actor: admin)
    page = Ash.update!(page, %{seo_title: "Edited SEO"}, action: :autosave, actor: admin)
    _page = Ash.update!(page, %{slug: "coalesced-slug"}, action: :autosave, actor: admin)

    autosaves = Enum.filter(versions(page, admin), &(&1.version_action_name == :autosave))
    assert length(autosaves) == 1
    [coalesced] = autosaves

    restored = CMS.restore_page_version!(page, %{version_id: coalesced.id}, actor: admin)

    assert restored.title == "Edited title"
    assert restored.seo_title == "Edited SEO"
    assert restored.slug == "coalesced-slug"
  end

  test "rejects a version belonging to a different record" do
    admin = admin()
    page = CMS.create_page!(%{title: "Mine", slug: slug()}, actor: admin)
    other = CMS.create_page!(%{title: "Theirs", slug: slug()}, actor: admin)
    [other_version | _] = versions(other, admin)

    assert {:error, _} =
             CMS.restore_page_version(page, %{version_id: other_version.id}, actor: admin)
  end

  describe "field coverage (#691)" do
    test "every field the compare view calls restorable actually round-trips" do
      admin = admin()
      define_price!(admin)

      original = %{
        title: "Original title",
        slug: slug(),
        path_alias: "/docs/original/path",
        locale: "en",
        audience: :public,
        seo_title: "Original SEO title",
        seo_description: "Original SEO description",
        seo_keywords: "original, keywords",
        seo_image: "/uploads/original.png",
        canonical_url: "https://example.com/original",
        custom_fields: %{"price" => "9"}
      }

      page = CMS.create_page!(Map.put(original, :blocks, block("Original")), actor: admin)
      [create_version | _] = versions(page, admin)

      _edited =
        CMS.update_page!(
          page,
          %{
            title: "Edited title",
            slug: slug(),
            path_alias: "/docs/edited/path",
            locale: "fr",
            audience: :member,
            seo_title: "Edited SEO title",
            seo_description: "Edited SEO description",
            seo_keywords: "edited, keywords",
            seo_image: "/uploads/edited.png",
            canonical_url: "https://example.com/edited",
            custom_fields: %{"price" => "19"},
            blocks: block("Edited")
          },
          actor: admin
        )

      restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      for {field, value} <- original do
        assert Map.fetch!(restored, field) == value,
               "#{field} was reported as restorable but did not move"
      end

      assert [%{content: "Original"}] =
               restored.blocks
               |> KilnCMS.CMS.TypedBlocks.to_typed()
               |> KilnCMS.CMS.TypedBlocks.to_legacy()

      # The drift guard the issue asks for: a new restorable attribute has to
      # fail here rather than quietly ship a restore that skips it. The two
      # reference fields have their own test — they need real records.
      covered = Map.keys(original) ++ [:blocks, :category_id, :featured_image_id]

      assert Enum.sort(VersionFields.restorable_fields(KilnCMS.CMS.Page)) == Enum.sort(covered)
    end

    test "the diff reports exactly the restorable fields plus the workflow ones it marks" do
      # Spelled out rather than derived: an assertion written in terms of the
      # same set algebra `VersionFields` uses holds for any value of
      # `@not_restorable` — including one that silently drops `audience` back
      # out of the restore, which is what #691 was filed about.
      assert VersionDiff.diffable_fields(KilnCMS.CMS.Post) ==
               ~w(title slug path_alias excerpt state audience locale
                  seo_title seo_description seo_keywords seo_image canonical_url
                  published_at scheduled_at unpublish_at
                  author_id category_id featured_image_id custom_fields)a

      assert VersionFields.restorable_fields(KilnCMS.CMS.Post) ==
               ~w(title slug path_alias excerpt audience locale
                  seo_title seo_description seo_keywords seo_image canonical_url
                  category_id featured_image_id custom_fields blocks)a
    end

    test "restorable? answers about the resource, not about a name in the abstract" do
      # A bare name test answered `true` for every bookkeeping column and for
      # names the resource has never heard of, so the compare modal would leave
      # a row unmarked that the restore never writes — #691 with the sign flipped.
      refute VersionFields.restorable?(KilnCMS.CMS.Page, :org_id)
      refute VersionFields.restorable?(KilnCMS.CMS.Page, :search_text)
      refute VersionFields.restorable?(KilnCMS.CMS.Page, :lock_version)
      refute VersionFields.restorable?(KilnCMS.CMS.Page, :not_an_attribute)
      # Page has no excerpt; Post does.
      refute VersionFields.restorable?(KilnCMS.CMS.Page, :excerpt)
      assert VersionFields.restorable?(KilnCMS.CMS.Post, :excerpt)
    end

    test "a Post's excerpt round-trips" do
      admin = admin()

      post =
        CMS.create_post!(%{title: "Piece", slug: slug(), excerpt: "Original blurb"}, actor: admin)

      [create_version | _] =
        CMS.list_post_versions!(actor: admin)
        |> Enum.filter(&(&1.version_source_id == post.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      post = CMS.update_post!(post, %{excerpt: "Edited blurb"}, actor: admin)

      restored = CMS.restore_post_version!(post, %{version_id: create_version.id}, actor: admin)
      assert restored.excerpt == "Original blurb"
    end

    test "a field first written AFTER the target version is reverted to its default" do
      admin = admin()
      page = CMS.create_page!(%{title: "Bare", slug: slug()}, actor: admin)
      [create_version | _] = versions(page, admin)

      # `:changes_only` records an attribute on the write that changed it, so
      # nothing below carries an `seo_title` key at all. Treating "absent from
      # the fold" as "leave it alone" is #691 verbatim: the compare view reports
      # the field as added and offers Restore, and the field does not move.
      page =
        CMS.update_page!(
          page,
          %{seo_title: "Added later", canonical_url: "https://late.test", audience: :member},
          actor: admin
        )

      restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      assert restored.seo_title == nil
      assert restored.canonical_url == nil
      # Not nil — `audience` is `allow_nil? false` with a default, and the
      # default is exactly what a record carried before the column was written.
      assert restored.audience == :public
    end

    test "custom_fields restore wholesale — a key added since the version is gone" do
      admin = admin()
      define_price!(admin)
      define_sale!(admin)

      page =
        CMS.create_page!(
          %{title: "Prices", slug: slug(), custom_fields: %{"price" => "9"}},
          actor: admin
        )

      [create_version | _] = versions(page, admin)
      at_create = page.custom_fields
      refute at_create["sale"] == true

      _page =
        CMS.update_page!(
          page,
          %{custom_fields: %{"price" => "19", "sale" => true}},
          actor: admin
        )

      restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      # The compare view reports `sale` as *added* between these two versions; a
      # key-wise merge would leave it behind and make that report a lie.
      assert restored.custom_fields == at_create
      assert restored.custom_fields["price"] == "9"
      refute restored.custom_fields["sale"] == true
    end

    test "category and featured image restore as references" do
      admin = admin()
      category = category!(admin)
      image = media!()

      page =
        CMS.create_page!(
          %{
            title: "Illustrated",
            slug: slug(),
            category_id: category.id,
            featured_image_id: image.id
          },
          actor: admin
        )

      [create_version | _] = versions(page, admin)
      _page = CMS.update_page!(page, %{category_id: nil, featured_image_id: nil}, actor: admin)

      restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      assert restored.category_id == category.id
      assert restored.featured_image_id == image.id
    end

    test "workflow state and attribution are deliberately left alone" do
      admin = admin()
      page = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)
      [create_version | _] = versions(page, admin)

      page = CMS.publish_page!(page, actor: admin)
      assert page.state == :published
      published_at = page.published_at

      restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      assert restored.state == :published
      assert restored.published_at == published_at
      assert restored.author_id == page.author_id
    end

    test "derived state moves with the content it is derived from" do
      admin = admin()
      page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
      [create_version | _] = versions(page, admin)

      page = CMS.update_page!(page, %{title: "Beta", seo_keywords: "beta"}, actor: admin)
      assert CMS.get_page!(page.id, actor: admin).search_text =~ "Beta"

      _restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      # `search_text` is denormalized, so a restore that leaves it alone keeps
      # the document findable only under the text the editor just reverted.
      fresh = CMS.get_page!(page.id, actor: admin)
      assert fresh.search_text =~ "Alpha"
      refute fresh.search_text =~ "Beta"
    end
  end

  describe "restored custom_fields run the FieldDefinition registry (#710)" do
    test "a key whose definition was deleted since is dropped, not resurrected" do
      admin = admin()
      definition = define_price!(admin)

      page =
        CMS.create_page!(
          %{title: "P", slug: slug(), custom_fields: %{"price" => "9"}},
          actor: admin
        )

      [create_version | _] = versions(page, admin)

      # Retire the definition, then restore the version that still carried its key.
      CMS.update_page!(page, %{title: "P2"}, actor: admin)
      CMS.destroy_field_definition!(definition, actor: admin)

      restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      # `custom_fields` is `public? true`; resurrecting the key would republish a
      # value an admin removed the definition for. The registry pass drops it.
      refute Map.has_key?(restored.custom_fields, "price")
    end

    test "a :select value outside a since-narrowed option list fails the restore" do
      admin = admin()

      size =
        define_field!(admin, %{
          name: "size",
          label: "Size",
          field_type: :select,
          options: ["s", "m", "l"]
        })

      page =
        CMS.create_page!(
          %{title: "P", slug: slug(), custom_fields: %{"size" => "l"}},
          actor: admin
        )

      [create_version | _] = versions(page, admin)

      CMS.update_page!(page, %{custom_fields: %{"size" => "m"}}, actor: admin)
      CMS.update_field_definition!(size, %{options: ["s", "m"]}, actor: admin)

      # Without the registry pass the stale "l" was written back unchecked and the
      # record could no longer be saved at all; now the restore refuses up front.
      assert_refuses(page, create_version, :custom_fields, admin)
    end

    test "a :media value pointing at since-trashed media fails the restore" do
      admin = admin()
      define_field!(admin, %{name: "hero", label: "Hero", field_type: :media})
      item = media!()

      page =
        CMS.create_page!(
          %{title: "P", slug: slug(), custom_fields: %{"hero" => item.id}},
          actor: admin
        )

      [create_version | _] = versions(page, admin)

      CMS.update_page!(page, %{title: "P2"}, actor: admin)
      CMS.destroy_media_item!(item, actor: admin)

      # The dangling-reference check PR #709 added for `featured_image_id` now
      # covers an identical trashed id inside `custom_fields` too.
      assert_refuses(page, create_version, :custom_fields, admin)
    end

    test "a :reference value pointing at a since-trashed record fails the restore" do
      admin = admin()
      target = CMS.create_page!(%{title: "Target", slug: slug()}, actor: admin)

      define_field!(admin, %{
        name: "related",
        label: "Related",
        field_type: :reference,
        target_type: "page"
      })

      page =
        CMS.create_page!(
          %{title: "P", slug: slug(), custom_fields: %{"related" => target.id}},
          actor: admin
        )

      [create_version | _] = versions(page, admin)

      CMS.update_page!(page, %{title: "P2"}, actor: admin)
      CMS.destroy_page!(target, actor: admin)

      assert_refuses(page, create_version, :custom_fields, admin)
    end

    test "computed fields refresh from the restored document, not the stored value" do
      admin = admin()
      # Created BEFORE the computed field exists, so the create version's folded
      # map carries no key for it.
      page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
      [create_version | _] = versions(page, admin)

      define_field!(admin, %{
        name: "echo",
        label: "Echo",
        field_type: :computed,
        compute: "{{ title }}"
      })

      CMS.update_page!(page, %{title: "Beta"}, actor: admin)

      restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

      # Recomputed from the restored title — not left absent (old behavior, the
      # folded map predates the field) and not the current "Beta".
      assert restored.custom_fields["echo"] == "Alpha"
    end
  end

  describe "re-validation (#691)" do
    test "refuses a path_alias another record has claimed since" do
      admin = admin()
      alias_path = "/docs/#{slug()}"

      page = CMS.create_page!(%{title: "Mover", slug: slug()}, actor: admin)
      page = CMS.update_page!(page, %{path_alias: alias_path}, actor: admin)
      [_create, aliased | _] = versions(page, admin)

      # Vacated, then claimed by someone else — legal at every step.
      page = CMS.update_page!(page, %{path_alias: "/docs/moved-on"}, actor: admin)

      _squatter =
        CMS.create_page!(%{title: "Squatter", slug: slug(), path_alias: alias_path}, actor: admin)

      # `restore_version` writes from a `before_action`, so the action's own
      # `validate` entries have already passed by the time the fold lands —
      # without re-running them the alias goes straight to Postgres, which has
      # no unique index on it, and two records answer the same public URL.
      assert_refuses(page, aliased, :path_alias, admin)
    end
  end

  describe "dangling references (#691)" do
    test "fails cleanly when the restored category has been deleted" do
      admin = admin()
      category = category!(admin)

      page =
        CMS.create_page!(
          %{title: "Filed", slug: slug(), category_id: category.id},
          actor: admin
        )

      [create_version | _] = versions(page, admin)
      page = CMS.update_page!(page, %{category_id: nil, title: "Unfiled"}, actor: admin)
      CMS.destroy_category!(category, actor: admin)

      assert_refuses(page, create_version, :category_id, admin)

      # Nothing was half-restored — the title did not move either.
      assert CMS.get_page!(page.id, actor: admin).title == "Unfiled"
    end

    test "fails cleanly when the restored featured image has been trashed" do
      admin = admin()
      image = media!()

      page =
        CMS.create_page!(
          %{title: "Illustrated", slug: slug(), featured_image_id: image.id},
          actor: admin
        )

      [create_version | _] = versions(page, admin)
      page = CMS.update_page!(page, %{featured_image_id: nil, title: "Plain"}, actor: admin)
      CMS.destroy_media_item!(image, actor: admin)

      assert_refuses(page, create_version, :featured_image_id, admin)
      assert CMS.get_page!(page.id, actor: admin).title == "Plain"
    end

    test "a reference the record already carries is checked too, not assumed intact" do
      admin = admin()
      image = media!()

      page =
        CMS.create_page!(
          %{title: "Illustrated", slug: slug(), featured_image_id: image.id},
          actor: admin
        )

      page = CMS.update_page!(page, %{title: "Renamed"}, actor: admin)
      [create_version | _] = versions(page, admin)
      CMS.destroy_media_item!(image, actor: admin)

      # The restore re-asserts the id the record already holds. Skipping the
      # check for those would read the current id off a caller-supplied struct
      # the editor LiveView holds for a whole session — so a reference another
      # editor moved and trashed meanwhile would sail past on a stale compare.
      assert_refuses(page, create_version, :featured_image_id, admin)
    end
  end

  defp block(content), do: [%{type: :heading, content: content, order: 0}]

  defp assert_refuses(page, version, field, admin) do
    assert {:error, error} =
             CMS.restore_page_version(page, %{version_id: version.id}, actor: admin)

    errors = Ash.Error.to_error_class(error).errors

    assert Enum.any?(errors, &(&1.field == field)),
           "expected an error on #{field}, got #{inspect(errors)}"
  end

  # `ApplyCustomFields` writes back only *defined* keys, so a custom-field test
  # without a definition asserts on an empty map and proves nothing.
  defp define_field!(admin, attrs) do
    CMS.create_field_definition!(Map.put(attrs, :content_type, :page), actor: admin)
  end

  defp define_price!(admin), do: define_field!(admin, %{name: "price", label: "Price"})

  defp define_sale!(admin),
    do: define_field!(admin, %{name: "sale", label: "On sale", field_type: :boolean})

  defp category!(admin) do
    CMS.create_category!(
      %{name: "Cat #{System.unique_integer([:positive])}", slug: slug()},
      actor: admin
    )
  end

  defp media! do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "hero-#{System.unique_integer([:positive])}.png",
      url: "/uploads/hero.png",
      alt: "A hero image"
    })
  end
end
