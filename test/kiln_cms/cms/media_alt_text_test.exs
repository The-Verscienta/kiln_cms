defmodule KilnCMS.CMS.MediaAltTextTest do
  @moduledoc """
  Alt-text enforcement and media usage tracking (#403).

  `alt` has always been optional, so it is missing on exactly the images nobody
  thought about — the ones a screen-reader user meets as "image" or as a
  filename read aloud one character at a time.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Firing.References

  setup do
    previous = Application.get_env(:kiln_cms, :media, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :media, previous) end)
    :ok
  end

  defp require_alt!, do: Application.put_env(:kiln_cms, :media, require_alt_text: true)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "alt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp image(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Ash.Seed.seed!(
      MediaItem,
      Map.merge(
        %{filename: "img-#{n}.png", url: "/uploads/img-#{n}.png", content_type: "image/png"},
        attrs
      )
    )
  end

  # The shape the editor stores: a typed block, not the legacy `%{type: ...}`
  # map, which does not carry `media_id` through the union cast.
  defp image_block(img, opts \\ []),
    do: %{
      "_type" => "image",
      "url" => img.url,
      "media_id" => img.id,
      "alt" => opts[:alt]
    }

  defp page(attrs, actor) do
    n = System.unique_integer([:positive])
    CMS.create_page!(Map.merge(%{title: "Page #{n}", slug: "alt-#{n}"}, attrs), actor: actor)
  end

  describe "the publish gate" do
    test "is off unless configured, so an existing library keeps publishing" do
      actor = admin()
      p = page(%{blocks: [image_block(image())]}, actor)

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "refuses a publish whose image block has no alt, naming the image" do
      require_alt!()
      actor = admin()
      img = image()
      p = page(%{blocks: [image_block(img)]}, actor)

      assert {:error, error} = CMS.publish_page(p, actor: actor)
      assert Exception.message(error) =~ img.url
      assert Exception.message(error) =~ "no alt text"
    end

    test "the BLOCK's alt is what counts, not the library item's" do
      require_alt!()
      actor = admin()
      # Library row blank, block described — this is what actually renders, and
      # an earlier version of this check refused it.
      p = page(%{blocks: [image_block(image(), alt: "A described chart")]}, actor)

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "a filled-in library row does not excuse a blank block alt" do
      require_alt!()
      actor = admin()
      img = image(%{alt: "library alt nobody sees"})
      p = page(%{blocks: [image_block(img)]}, actor)

      # `Blocks.Image.render/2` emits `block.alt`, so this page would ship
      # `alt=""` — the exact failure #403 exists to stop.
      assert {:error, _} = CMS.publish_page(p, actor: actor)
    end

    test "an image pasted by URL with no library item is checked too" do
      require_alt!()
      actor = admin()
      p = page(%{blocks: [%{"_type" => "image", "url" => "/pasted.png"}]}, actor)

      assert {:error, error} = CMS.publish_page(p, actor: actor)
      assert Exception.message(error) =~ "/pasted.png"
    end

    test "a decorative library item excuses a blank block alt" do
      require_alt!()
      actor = admin()
      p = page(%{blocks: [image_block(image(%{decorative: true}))]}, actor)

      # A divider or a texture correctly has no alt text — the point of the flag
      # is that "deliberately silent" is distinguishable from "not done yet".
      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "a whitespace-only block alt does not satisfy it" do
      require_alt!()
      actor = admin()
      p = page(%{blocks: [image_block(image(), alt: "   ")]}, actor)

      assert {:error, _} = CMS.publish_page(p, actor: actor)
    end

    test "a document with no images publishes" do
      require_alt!()
      actor = admin()
      p = page(%{blocks: [%{"_type" => "heading", "text" => "Just words"}]}, actor)

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "an image nested in a columns block is checked" do
      require_alt!()
      actor = admin()
      img = image()

      p =
        page(
          %{
            blocks: [
              %{
                "_type" => "columns",
                "columns" => [%{"blocks" => [image_block(img)]}]
              }
            ]
          },
          actor
        )

      # A hero beside text is the standard layout; escaping the check by being
      # one level down would make the gate close to useless.
      assert {:error, error} = CMS.publish_page(p, actor: actor)
      assert Exception.message(error) =~ img.url
    end

    test "every offending image is named, not just the first" do
      require_alt!()
      actor = admin()
      one = image()
      two = image()
      p = page(%{blocks: [image_block(one), image_block(two)]}, actor)

      assert {:error, error} = CMS.publish_page(p, actor: actor)

      # An editor should be able to fix them in one pass rather than
      # rediscovering the next one on every retry.
      message = Exception.message(error)
      assert message =~ one.url
      assert message =~ two.url
    end

    test "the scheduled publish path is gated too" do
      require_alt!()
      actor = admin()
      p = page(%{blocks: [image_block(image())]}, actor)

      # The unattended path is precisely where a refusal has no human to read
      # the error, so it must not be the one that silently bypasses the gate.
      assert {:error, _} =
               p
               |> Ash.Changeset.for_update(:publish_scheduled, %{}, actor: actor)
               |> Ash.update()
    end
  end

  # The publish gate was the whole story until #722: `:update` re-fires
  # artifacts for an already-published record, so editing a live page to show
  # an alt-less image shipped it with the gate never running. `:update` now
  # re-runs the check — but only when the record is published AND the body is
  # actually changing.
  describe "the update gate (#722)" do
    # A published page carrying an alt-less image, seeded past the publish gate
    # the way a page published before the feature was switched on would be.
    defp published_with_altless do
      Ash.Seed.seed!(
        KilnCMS.CMS.Page,
        %{
          title: "Live #{System.unique_integer([:positive])}",
          slug: "alt-live-#{System.unique_integer([:positive])}",
          state: :published,
          blocks: [image_block(image())]
        }
      )
    end

    test "editing a published page to show an alt-less image is refused" do
      require_alt!()
      actor = admin()
      # Publish clean, then swap in an image with no alt.
      published = page(%{blocks: [image_block(image(), alt: "described")]}, actor)
      {:ok, published} = CMS.publish_page(published, actor: actor)

      img = image()

      assert {:error, error} =
               CMS.update_page(published, %{blocks: [image_block(img)]}, actor: actor)

      assert Exception.message(error) =~ img.url
      assert Exception.message(error) =~ "no alt text"
    end

    test "a metadata-only update of a published page is not gated" do
      require_alt!()
      actor = admin()
      published = published_with_altless()

      # The body isn't changing, so the gate must not fire even though the live
      # page already carries an alt-less image.
      assert {:ok, _} = CMS.update_page(published, %{title: "Retitled"}, actor: actor)
    end

    # The editor's Save resubmits the WHOLE form — `blocks` included — on every
    # save, so the metadata-only exemption rests on `changing(:blocks)` seeing
    # an unchanged (re-cast) blocks value as not-a-change. A page published with
    # an alt-less image before the feature was switched on must stay editable
    # for a title-only save, not become permanently un-saveable.
    test "resubmitting identical blocks plus a title change is not gated" do
      actor = admin()

      # Publish the alt-less image while the gate is OFF — a pre-feature page —
      # so its blocks are stored canonically through the normal write path.
      page = page(%{blocks: [image_block(image())]}, actor)
      {:ok, published} = CMS.publish_page(page, actor: actor)
      published = CMS.get_page!(published.id, authorize?: false)

      require_alt!()

      # A title-only editor save resubmits the loaded (unchanged) blocks.
      assert {:ok, _} =
               CMS.update_page(
                 published,
                 %{title: "Retitled", blocks: published.blocks},
                 actor: actor
               )
    end

    test "editing a DRAFT with an alt-less image is allowed — no public claim yet" do
      require_alt!()
      actor = admin()
      draft = page(%{blocks: [image_block(image(), alt: "described")]}, actor)

      assert {:ok, _} =
               CMS.update_page(draft, %{blocks: [image_block(image())]}, actor: actor)
    end

    test "autosave is exempt, so an in-progress draft is never blocked" do
      require_alt!()
      actor = admin()
      draft = page(%{blocks: [image_block(image(), alt: "described")]}, actor)

      assert {:ok, _} =
               draft
               |> Ash.Changeset.for_update(:autosave, %{blocks: [image_block(image())]},
                 actor: actor
               )
               |> Ash.update()
    end

    # `:restore_version` force-changes blocks from a snapshot in a
    # `before_action`, so the ordinary publish/update `validate` never sees
    # them (#722) — the check is re-run by hand after the fold, gated on the
    # record being published (a draft restore makes no public claim).
    test "restoring a published page to an alt-less version is refused" do
      require_alt!()
      actor = admin()

      # v1 (create): an alt-less image, legal while a draft.
      bad = image()
      draft = page(%{blocks: [image_block(bad)]}, actor)

      # v2: fix it, then publish the good version.
      fixed =
        CMS.update_page!(draft, %{blocks: [image_block(image(), alt: "described")]}, actor: actor)

      {:ok, published} = CMS.publish_page(fixed, actor: actor)

      # Rolling back to v1 would put the alt-less image on the live page.
      [create_version | _] =
        CMS.list_page_versions!(actor: actor)
        |> Enum.filter(&(&1.version_source_id == published.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      assert {:error, error} =
               CMS.restore_page_version(published, %{version_id: create_version.id}, actor: actor)

      assert Exception.message(error) =~ bad.url
      assert Exception.message(error) =~ "no alt text"
    end
  end

  describe "usage tracking" do
    test "a published document's media shows up as a usage" do
      actor = admin()
      img = image(%{alt: "Hero"})
      p = page(%{featured_image_id: img.id}, actor)
      published = CMS.publish_page!(p, actor: actor)
      drain_oban()

      usages = References.usages(published.org_id, img.id)

      assert %{total: 1, items: [%{type: :page, id: id, title: title, kind: "page"}]} = usages
      assert id == published.id
      assert title == published.title
    end

    test "an image referenced only from a block is tracked too" do
      actor = admin()
      img = image(%{alt: "Inline"})

      p = page(%{blocks: [image_block(img)]}, actor)
      published = CMS.publish_page!(p, actor: actor)
      drain_oban()

      assert %{items: [%{id: id}]} = References.usages(published.org_id, img.id)
      assert id == published.id
    end

    test "a :media custom field counts as a usage, a :reference one does not" do
      # Both are stored as maps carrying an `"id"`; only the media snapshot has
      # a `"url"`. Matching on `"id"` alone recorded every content reference as
      # a media edge.
      img = image(%{alt: "Hero"})
      other = Ecto.UUID.generate()

      document = %{
        blocks: [],
        featured_image_id: nil,
        custom_fields: %{
          "hero" => %{"id" => img.id, "url" => img.url, "alt" => "Hero"},
          "related" => %{"id" => other, "type" => "page", "slug" => "x", "title" => "X"}
        }
      }

      refs = References.document_refs(document)

      assert {:media, img.id} in refs
      refute {:media, other} in refs
    end

    test "removing the reference removes the usage" do
      actor = admin()
      img = image(%{alt: "Hero"})
      p = page(%{featured_image_id: img.id}, actor)
      published = CMS.publish_page!(p, actor: actor)
      drain_oban()
      assert References.usages(published.org_id, img.id).total == 1

      _updated = CMS.update_page!(published, %{featured_image_id: nil}, actor: actor)
      drain_oban()

      # The edge set is rebuilt from scratch on every fire, so a dropped
      # reference must not linger and warn about a document that no longer
      # shows the image.
      assert References.usages(published.org_id, img.id).total == 0
    end
  end

  # #482: a gallery is one block holding N images, so both the publish gate and
  # the reference extractor have to look inside it. Neither did by default — the
  # gate tests a top-level `:alt` field and the extractor matches on field names
  # ending in `media_id`, and a gallery has neither.
  describe "galleries" do
    setup do
      require_alt!()
      :ok
    end

    defp gallery_block(images),
      do: %{"_type" => "gallery", "images" => images}

    test "an undescribed gallery image blocks publishing, like a lone image would" do
      actor = admin()
      img = image()

      p =
        page(
          %{blocks: [gallery_block([%{"url" => img.url, "media_id" => img.id, "alt" => ""}])]},
          actor
        )

      assert {:error, %Ash.Error.Invalid{} = error} = CMS.publish_page(p, actor: actor)
      assert Exception.message(error) =~ "no alt text"
    end

    test "one undescribed image among described ones is still caught" do
      actor = admin()
      [a, b] = [image(), image()]

      p =
        page(
          %{
            blocks: [
              gallery_block([
                %{"url" => a.url, "media_id" => a.id, "alt" => "Described"},
                %{"url" => b.url, "media_id" => b.id, "alt" => ""}
              ])
            ]
          },
          actor
        )

      assert {:error, %Ash.Error.Invalid{} = error} = CMS.publish_page(p, actor: actor)
      # The one named is the one at fault, not the whole gallery.
      assert Exception.message(error) =~ b.url
      refute Exception.message(error) =~ a.url
    end

    test "a described gallery publishes" do
      actor = admin()
      img = image()

      p =
        page(
          %{
            blocks: [
              gallery_block([%{"url" => img.url, "media_id" => img.id, "alt" => "A kiln"}])
            ]
          },
          actor
        )

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "a decorative library item excuses a blank gallery alt" do
      actor = admin()
      img = image(%{decorative: true})

      p =
        page(
          %{blocks: [gallery_block([%{"url" => img.url, "media_id" => img.id, "alt" => ""}])]},
          actor
        )

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "every gallery image becomes a media reference edge" do
      [a, b] = [image(), image()]

      blocks =
        KilnCMS.CMS.TypedBlocks.to_typed([
          gallery_block([
            %{"url" => a.url, "media_id" => a.id, "alt" => "A"},
            %{"url" => b.url, "media_id" => b.id, "alt" => "B"}
          ])
        ])

      # Without a dedicated clause this is `[]`, and a gallery silently loses
      # usage counts, re-fire on media change, and delivery cache busts.
      assert References.media_refs(blocks) == [{:media, a.id}, {:media, b.id}]
    end
  end

  describe "reference extraction" do
    test "a non-uuid media_id never becomes an edge" do
      # `media_id` is a free-text block field, so an importer can put anything
      # there — and `to_id` is a uuid column, so junk would fail the whole
      # rebuild rather than just being skipped.
      blocks =
        KilnCMS.CMS.TypedBlocks.to_typed([
          %{"_type" => "image", "url" => "/x.png", "media_id" => "not-a-uuid"}
        ])

      assert References.media_refs(blocks) == []
    end
  end
end
