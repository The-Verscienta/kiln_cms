defmodule KilnCMS.CMS.MediaLibraryTest do
  @moduledoc """
  Media organisation (#1316): tags via the shared polymorphic `Tagging` join,
  the `uploaded_by` byline, the `kind` calculation, and the `:library` read
  action's facets (kind / tag / uploader / date range / unused).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "media-lib-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp media(attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.CMS.MediaItem,
      Map.merge(
        %{filename: "x.png", url: "/uploads/#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp tag!(actor, name) do
    CMS.create_tag!(%{name: name, slug: "#{name}-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  # A published-reference edge to a media item, as the fire path would write it.
  defp reference!(media_id) do
    Ash.Seed.seed!(KilnCMS.Firing.ReferenceEdge, %{
      from_type: :page,
      from_id: Ash.UUID.generate(),
      to_type: :media,
      to_id: media_id
    })
  end

  defp library!(args, opts \\ []) do
    CMS.library_media_items!(args, Keyword.put_new(opts, :actor, user(:editor)))
  end

  defp ids(items), do: items |> Enum.map(& &1.id) |> MapSet.new()

  describe "kind calculation" do
    test "mirrors MediaKind.of/1 bucket for bucket" do
      editor = user(:editor)

      # A blank string is a stored, meaningless value — document, not image
      # (`MediaKind.of/1`). Ash normalizes "" to nil on write, so plant it
      # with raw SQL the way only a pre-Ash or hand-edited row could hold it.
      blank = media()

      KilnCMS.Repo.query!("UPDATE media_items SET content_type = '' WHERE id = $1", [
        Ecto.UUID.dump!(blank.id)
      ])

      expected = %{
        media(%{content_type: nil}).id => :image,
        media(%{content_type: "image/png"}).id => :image,
        media(%{content_type: "IMAGE/JPEG"}).id => :image,
        media(%{content_type: "video/mp4"}).id => :video,
        media(%{content_type: "audio/mpeg"}).id => :audio,
        media(%{content_type: "text/vtt"}).id => :captions,
        media(%{content_type: "TEXT/VTT"}).id => :captions,
        media(%{content_type: "application/pdf"}).id => :document,
        blank.id => :document
      }

      for {id, kind} <- expected do
        loaded = CMS.get_media_item!(id, actor: editor, load: [:kind])

        assert loaded.kind == kind,
               "expected #{inspect(loaded.content_type)} to be #{kind}, got #{loaded.kind}"
      end
    end
  end

  describe "tags" do
    test "update with tag_ids replaces the set; verbs merge" do
      editor = user(:editor)
      item = media()
      a = tag!(editor, "a")
      b = tag!(editor, "b")
      c = tag!(editor, "c")

      item = CMS.update_media_item!(item, %{tag_ids: [a.id, b.id]}, actor: editor, load: [:tags])
      assert ids(item.tags) == MapSet.new([a.id, b.id])

      # add merges rather than replacing
      item = CMS.update_media_item!(item, %{add_tag_ids: [c.id]}, actor: editor, load: [:tags])
      assert ids(item.tags) == MapSet.new([a.id, b.id, c.id])

      # remove is idempotent — an already-detached id is a no-op
      item =
        CMS.update_media_item!(item, %{remove_tag_ids: [b.id, Ash.UUID.generate()]},
          actor: editor,
          load: [:tags]
        )

      assert ids(item.tags) == MapSet.new([a.id, c.id])
    end

    test "combining the complete set with a merge verb is refused" do
      editor = user(:editor)
      item = media()
      a = tag!(editor, "solo")

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_media_item(item, %{tag_ids: [a.id], add_tag_ids: [a.id]}, actor: editor)
    end

    test "the tag's media_count counts live items only" do
      editor = user(:editor)
      admin = user(:admin)
      tag = tag!(editor, "counted")

      kept = CMS.update_media_item!(media(), %{tag_ids: [tag.id]}, actor: editor)
      trashed = CMS.update_media_item!(media(), %{tag_ids: [tag.id]}, actor: editor)
      :ok = CMS.destroy_media_item!(trashed, actor: admin)

      assert CMS.get_tag!(tag.id, actor: editor, load: [:media_count]).media_count == 1

      # and the reverse relationship reaches the media item
      loaded = CMS.get_tag!(tag.id, actor: editor, load: [:media_items])
      assert ids(loaded.media_items) == MapSet.new([kept.id])
    end
  end

  describe "uploaded_by" do
    test "create stamps the actor; a system create without one is fine" do
      editor = user(:editor)

      mine =
        CMS.create_media_item!(%{filename: "mine.png", url: "/uploads/mine"}, actor: editor)

      assert mine.uploaded_by_id == editor.id

      nobody =
        CMS.create_media_item!(%{filename: "sys.png", url: "/uploads/sys"}, authorize?: false)

      assert nobody.uploaded_by_id == nil
    end
  end

  describe ":library facets" do
    test "kind narrows to one bucket" do
      png = media(%{content_type: "image/png"})
      pdf = media(%{content_type: "application/pdf"})

      images = library!(%{kind: :image}) |> ids()
      docs = library!(%{kind: :document}) |> ids()

      assert png.id in images
      refute pdf.id in images
      assert pdf.id in docs
      refute png.id in docs
    end

    test "tag_ids matches items carrying any listed tag" do
      editor = user(:editor)
      tag = tag!(editor, "facet")
      tagged = CMS.update_media_item!(media(), %{tag_ids: [tag.id]}, actor: editor)
      plain = media()

      found = library!(%{tag_ids: [tag.id, Ash.UUID.generate()]}) |> ids()
      assert tagged.id in found
      refute plain.id in found
    end

    test "uploaded_by_id narrows to one uploader" do
      editor = user(:editor)
      other = user(:editor)

      mine = CMS.create_media_item!(%{filename: "m.png", url: "/uploads/m"}, actor: editor)
      theirs = CMS.create_media_item!(%{filename: "t.png", url: "/uploads/t"}, actor: other)

      found = library!(%{uploaded_by_id: editor.id}) |> ids()
      assert mine.id in found
      refute theirs.id in found
    end

    test "date bounds are inclusive of the named day" do
      item = media()
      today = DateTime.to_date(item.inserted_at)

      assert item.id in ids(library!(%{uploaded_after: today, uploaded_before: today}))
      refute item.id in ids(library!(%{uploaded_after: Date.add(today, 1)}))
      refute item.id in ids(library!(%{uploaded_before: Date.add(today, -1)}))
    end

    test "unused splits on the reference-edge graph" do
      used = media()
      idle = media()
      reference!(used.id)

      unused_ids = library!(%{unused: true}) |> ids()
      used_ids = library!(%{unused: false}) |> ids()
      all_ids = library!(%{}) |> ids()

      assert idle.id in unused_ids
      refute used.id in unused_ids
      assert used.id in used_ids
      refute idle.id in used_ids
      assert used.id in all_ids and idle.id in all_ids
    end

    test "facets compose" do
      editor = user(:editor)
      tag = tag!(editor, "both")

      hit =
        CMS.update_media_item!(media(%{content_type: "image/png"}), %{tag_ids: [tag.id]},
          actor: editor
        )

      wrong_kind =
        CMS.update_media_item!(media(%{content_type: "application/pdf"}), %{tag_ids: [tag.id]},
          actor: editor
        )

      found = library!(%{kind: :image, tag_ids: [tag.id], unused: true}) |> ids()
      assert hit.id in found
      refute wrong_kind.id in found
    end

    test "anonymous callers can browse (world-readable, like :read)" do
      item = media(%{content_type: "image/png"})

      found =
        CMS.library_media_items!(%{kind: :image}, actor: nil) |> ids()

      assert item.id in found
    end
  end
end
