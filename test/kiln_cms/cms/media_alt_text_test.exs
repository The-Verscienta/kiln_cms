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
