defmodule KilnCMS.CMS.ItemMediaReferenceTest do
  @moduledoc """
  `:media` and `:reference` sub-fields inside the items of a `:flexible` field
  and the rows of a `:group` (#2282, `docs/flexible-content-plan.md` section 6
  and ADR 0065): the write path resolves them as the top-level fields are, as
  the CALLER under the writing tenant, and rebuilds every snapshot from the
  record; the reference edges they imply are keyed by definition path and
  follow the definitions when a sub-field, item type or field is renamed or
  destroyed; `mix kiln.media.resnapshot` re-takes the media inside them and
  leaves the references alone; and `FieldDisplay` reads them without a raw id
  or a stored snapshot.

  An item type offers `:media` and `:reference` sub-fields
  (`FieldDefinition.item_field_types/0`); a group's rows do not yet (no row
  pickers), so a group sub-field of those types is created as a string and
  retyped directly (`Ash.Seed.update!/2`), which is what a later release's
  definition looks like to this one.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldDisplay
  alias KilnCMS.CMS.VersionDiff
  alias KilnCMS.Media.{Resnapshot, Snapshot}

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "itemref-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "itemref-#{System.unique_integer([:positive])}"

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)

  defp item_type!(admin, flexible, name),
    do: def!(admin, %{name: name, field_type: :group, flex_of_id: flexible.id, label: name})

  defp sub!(admin, parent, name, type \\ :string, attrs \\ %{}) do
    extra =
      case type do
        :string -> %{field_type: :string}
        :media -> %{field_type: :media}
        :reference -> %{field_type: :reference, target_type: "page"}
      end

    base = %{name: name, group_of_id: parent.id}

    if FieldDefinition.item_type?(parent) do
      def!(admin, Map.merge(base, Map.merge(extra, attrs)))
    else
      # A plain group's rows are not lifted: retype directly.
      sub = def!(admin, Map.merge(base, Map.merge(%{field_type: :string}, attrs)))
      if type == :string, do: sub, else: Ash.Seed.update!(sub, extra)
    end
  end

  defp page!(admin, title, publish? \\ true) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
    if publish?, do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  defp media!(attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.CMS.MediaItem,
      Map.merge(
        %{
          filename: "pic-#{System.unique_integer([:positive])}.png",
          url: "/uploads/pic-#{System.unique_integer([:positive])}.png",
          alt: "Alt text",
          content_type: "image/png"
        },
        attrs
      )
    )
  end

  defp post(actor, fields, opts \\ []),
    do:
      CMS.create_post(
        %{title: "Referrer", slug: slug(), custom_fields: fields},
        [actor: actor] ++ opts
      )

  defp post!(actor, fields) do
    {:ok, post} = post(actor, fields)
    post
  end

  defp message(result) do
    assert {:error, error} = result
    Exception.message(error)
  end

  defp stored(post), do: CMS.get_post!(post.id, authorize?: false).custom_fields

  defp edges(post) do
    post.id
    |> CMS.list_reference_links!(authorize?: false, tenant: post.org_id)
    |> Enum.map(&{&1.field, &1.target_id})
    |> Enum.sort()
  end

  defp raw(post) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!("SELECT custom_fields FROM posts WHERE id = $1", [
        Ecto.UUID.dump!(post.id)
      ])

    value
  end

  # sections (1) > section {title, cta, pic, rows (2) > row {cta, pic}}, and a
  # repeating group `visits` {place, doctor, photo}.
  setup do
    admin = user(:admin)
    sections = def!(admin, %{content_type: :post, name: "sections", field_type: :flexible})
    section = item_type!(admin, sections, "section")
    sub!(admin, section, "title")
    sub!(admin, section, "cta", :reference, %{position: 1, label: "Call to action"})
    sub!(admin, section, "pic", :media, %{position: 2})
    rows = sub!(admin, section, "rows", :string, %{position: 3})
    rows = Ash.Seed.update!(rows, %{field_type: :flexible})
    row = item_type!(admin, rows, "row")
    sub!(admin, row, "cta", :reference)
    sub!(admin, row, "pic", :media, %{position: 1})

    visits =
      def!(admin, %{content_type: :post, name: "visits", field_type: :group, multiple: true})

    sub!(admin, visits, "place")
    sub!(admin, visits, "doctor", :reference, %{position: 1})
    sub!(admin, visits, "photo", :media, %{position: 2})

    %{
      admin: admin,
      editor: user(:editor),
      viewer: user(:viewer),
      sections: sections,
      section: section,
      visits: visits,
      target: page!(admin, "Target page"),
      other: page!(admin, "Other page"),
      media: media!()
    }
  end

  defp item(attrs), do: Map.merge(%{"_type" => "section"}, attrs)

  describe "the write path" do
    test "stores snapshots rebuilt from the records, in an item and a group row", ctx do
      post =
        post!(ctx.editor, %{
          "sections" => [item(%{"cta" => ctx.target.id, "pic" => ctx.media.id})],
          "visits" => [%{"place" => "Clinic", "doctor" => ctx.target.id, "photo" => ctx.media.id}]
        })

      assert %{"cta" => cta, "pic" => pic} = hd(stored(post)["sections"])
      assert cta == reference(ctx.target)
      assert pic == Snapshot.of(ctx.media)

      assert %{"doctor" => ^cta, "photo" => ^pic, "place" => "Clinic"} =
               hd(stored(post)["visits"])
    end

    test "a snapshot a client sends is rebuilt from the database, never trusted", ctx do
      forged = %{
        "id" => ctx.target.id,
        "type" => "page",
        "slug" => "forged-slug",
        "title" => "Forged title"
      }

      forged_media = %{"id" => ctx.media.id, "url" => "/forged.png", "alt" => "Forged"}

      post =
        post!(ctx.editor, %{
          "sections" => [item(%{"cta" => forged, "pic" => forged_media})],
          "visits" => [%{"doctor" => forged, "photo" => forged_media}]
        })

      section = hd(stored(post)["sections"])
      visit = hd(stored(post)["visits"])

      for {ref, pic} <- [{section["cta"], section["pic"]}, {visit["doctor"], visit["photo"]}] do
        assert ref == reference(ctx.target)
        assert pic["url"] == ctx.media.url
        assert pic["alt"] == "Alt text"
      end
    end

    test "a reference at the second level is resolved too", ctx do
      post =
        post!(ctx.editor, %{
          "sections" => [
            item(%{
              "rows" => [%{"_type" => "row", "cta" => ctx.target.id, "pic" => ctx.media.id}]
            })
          ]
        })

      assert %{"cta" => %{"title" => "Target page"}, "pic" => %{"id" => id}} =
               stored(post)["sections"] |> hd() |> Map.fetch!("rows") |> hd()

      assert id == ctx.media.id
    end

    test "a target the writer cannot read is refused at the item's path", ctx do
      trashed = page!(ctx.admin, "Trashed", true)
      CMS.destroy_page!(trashed, actor: ctx.admin)

      message =
        message(post(ctx.editor, %{"sections" => [item(%{"cta" => trashed.id})]}))

      assert message =~ "sections[0].cta"
      assert message =~ "must be an existing page record"
      refute message =~ "Trashed"

      message =
        message(
          post(ctx.editor, %{
            "sections" => [
              item(%{"title" => "ok"}),
              item(%{"rows" => [%{"_type" => "row", "cta" => trashed.id}]})
            ]
          })
        )

      assert message =~ "sections[1].rows[0].cta"

      assert message(post(ctx.editor, %{"visits" => [%{"doctor" => trashed.id}]})) =~
               "visits[0].doctor"
    end

    test "a media item that does not exist is refused at the item's path", ctx do
      assert message(post(ctx.editor, %{"sections" => [item(%{"pic" => Ash.UUID.generate()})]})) =~
               "sections[0].pic"

      assert message(
               post(ctx.editor, %{"sections" => [item(%{"title" => "x", "pic" => %{"id" => ""}})]})
             ) =~
               "sections[0].pic"

      assert message(post(ctx.editor, %{"visits" => [%{"place" => "x", "photo" => "nonsense"}]})) =~
               "visits[0].photo"
    end

    test "a viewer cannot write at all", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               post(ctx.viewer, %{"sections" => [item(%{"cta" => ctx.target.id})]})
    end

    test "a target or media item of another site does not resolve", ctx do
      org = KilnCMS.OrgFixtures.org("itemref-other")

      foreign =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Foreign",
          slug: slug(),
          state: :published,
          org_id: org.id
        })

      foreign_media = media!(%{org_id: org.id})
      tenant = KilnCMS.Accounts.default_org_id()

      assert message(
               post(ctx.editor, %{"sections" => [item(%{"cta" => foreign.id})]}, tenant: tenant)
             ) =~ "sections[0].cta"

      assert message(
               post(ctx.editor, %{"sections" => [item(%{"pic" => foreign_media.id})]},
                 tenant: tenant
               )
             ) =~ "sections[0].pic"

      assert message(post(ctx.editor, %{"visits" => [%{"doctor" => foreign.id}]}, tenant: tenant)) =~
               "visits[0].doctor"
    end

    test "a list is refused where one value goes, a blank one clears it", ctx do
      assert message(post(ctx.editor, %{"sections" => [item(%{"cta" => [ctx.target.id]})]})) =~
               "sections[0].cta"

      post =
        post!(ctx.editor, %{
          "sections" => [item(%{"title" => "Kept", "cta" => "", "pic" => ""})]
        })

      assert [%{"title" => "Kept"} = only] = stored(post)["sections"]
      refute Map.has_key?(only, "cta")
      refute Map.has_key?(only, "pic")
    end

    test "reordering and a repeated _id keep each snapshot on its own item", ctx do
      a = item(%{"_id" => Ash.UUID.generate(), "title" => "A", "cta" => ctx.target.id})
      b = item(%{"_id" => Ash.UUID.generate(), "title" => "B", "cta" => ctx.other.id})
      post = post!(ctx.editor, %{"sections" => [a, b]})

      [sa, sb] = stored(post)["sections"]
      assert {sa["_id"], sa["cta"]["title"]} == {a["_id"], "Target page"}
      assert {sb["_id"], sb["cta"]["title"]} == {b["_id"], "Other page"}

      post =
        CMS.update_post!(post, %{custom_fields: %{"sections" => [sb, sa]}}, actor: ctx.editor)

      assert [%{"title" => "B", "cta" => %{"title" => "Other page"}} = first, second] =
               stored(post)["sections"]

      assert first["_id"] == b["_id"]
      assert second["cta"]["title"] == "Target page"

      # Two items claiming one _id: the second gets a new one, and keeps its own target.
      clash = %{a | "cta" => ctx.other.id, "title" => "Clash"}

      post =
        CMS.update_post!(post, %{custom_fields: %{"sections" => [a, clash]}}, actor: ctx.editor)

      [s1, s2] = stored(post)["sections"]
      assert s1["_id"] == a["_id"] and s2["_id"] != a["_id"]
      assert {s1["cta"]["title"], s2["cta"]["title"]} == {"Target page", "Other page"}
    end

    test "a stale snapshot is refreshed when the record is saved again", ctx do
      # A draft target, so a retitle is live at once (a published page's goes
      # to its working copy).
      draft = page!(ctx.admin, "Draft target", false)
      post = post!(ctx.editor, %{"sections" => [item(%{"cta" => draft.id})]})
      CMS.update_page!(draft, %{title: "Retitled"}, actor: ctx.admin)

      assert hd(stored(post)["sections"])["cta"]["title"] == "Draft target"

      # The form resends the stored items with an edit (an unchanged value is
      # no write at all, as for a top-level field).
      resent = Enum.map(stored(post)["sections"], &Map.put(&1, "title", "Edited"))

      post = CMS.update_post!(post, %{custom_fields: %{"sections" => resent}}, actor: ctx.editor)

      assert hd(stored(post)["sections"])["cta"]["title"] == "Retitled"
    end

    test "a write that does not name the field keeps its items as they were", ctx do
      post = post!(ctx.editor, %{"sections" => [item(%{"cta" => ctx.target.id})]})
      before = stored(post)

      CMS.update_post!(post, %{title: "Renamed"}, actor: ctx.editor)
      assert stored(post) == before
    end
  end

  describe "reference edges" do
    test "an item reference implies an edge keyed by the definition path", ctx do
      post =
        post!(ctx.editor, %{
          "sections" => [
            item(%{"cta" => ctx.target.id}),
            item(%{
              "cta" => ctx.target.id,
              "rows" => [%{"_type" => "row", "cta" => ctx.other.id}]
            })
          ],
          "visits" => [%{"doctor" => ctx.other.id}]
        })

      # Two items naming one target are one edge.
      assert edges(post) ==
               Enum.sort([
                 {"sections.section.cta", ctx.target.id},
                 {"sections.section.rows.row.cta", ctx.other.id},
                 {"visits.doctor", ctx.other.id}
               ])

      assert Enum.all?(
               CMS.list_reference_links!(post.id, authorize?: false, tenant: post.org_id),
               &(&1.position == 0 and &1.metadata == %{} and &1.kind == :reference)
             )
    end

    test "reordering and removing items follow the values", ctx do
      a = item(%{"_id" => Ash.UUID.generate(), "cta" => ctx.target.id})
      b = item(%{"_id" => Ash.UUID.generate(), "cta" => ctx.other.id})
      post = post!(ctx.editor, %{"sections" => [a, b]})
      before = CMS.list_reference_links!(post.id, authorize?: false, tenant: post.org_id)

      post = CMS.update_post!(post, %{custom_fields: %{"sections" => [b, a]}}, actor: ctx.editor)

      # Same edges, not rewritten.
      assert Enum.sort(Enum.map(before, & &1.id)) ==
               post.id
               |> CMS.list_reference_links!(authorize?: false, tenant: post.org_id)
               |> Enum.map(& &1.id)
               |> Enum.sort()

      post = CMS.update_post!(post, %{custom_fields: %{"sections" => [a]}}, actor: ctx.editor)
      assert edges(post) == [{"sections.section.cta", ctx.target.id}]

      post = CMS.update_post!(post, %{custom_fields: %{"sections" => []}}, actor: ctx.editor)
      assert edges(post) == []
    end

    test "an item reference is not a link that deletes or caps anything", ctx do
      post = post!(ctx.editor, %{"sections" => [item(%{"cta" => ctx.other.id})]})

      # `:keep` and uncapped: purging the target leaves the referrer's value.
      CMS.destroy_page!(ctx.other, actor: ctx.admin)
      assert :ok = CMS.purge_page(ctx.other, actor: ctx.admin)

      assert hd(stored(post)["sections"])["cta"]["id"] == ctx.other.id
      assert edges(post) == [{"sections.section.cta", ctx.other.id}]
    end

    test "a published record's working copy makes edges only when it is published", ctx do
      post = post!(ctx.admin, %{"sections" => [item(%{"cta" => ctx.target.id})]})
      post = CMS.publish_post!(post, %{}, actor: ctx.admin)

      {:ok, post} =
        CMS.ContentTypes.save_working_copy(
          "post",
          post,
          %{fields: %{"custom_fields" => %{"sections" => [item(%{"cta" => ctx.other.id})]}}},
          actor: ctx.admin,
          tenant: post.org_id
        )

      assert edges(post) == [{"sections.section.cta", ctx.target.id}]

      post = CMS.publish_post_changes!(post, %{}, actor: ctx.admin)
      assert hd(stored(post)["sections"])["cta"]["id"] == ctx.other.id
      assert edges(post) == [{"sections.section.cta", ctx.other.id}]
    end
  end

  describe "edges follow the definitions" do
    setup ctx do
      post =
        post!(ctx.editor, %{
          "sections" => [
            item(%{
              "cta" => ctx.target.id,
              "rows" => [%{"_type" => "row", "cta" => ctx.other.id}]
            })
          ],
          "visits" => [%{"doctor" => ctx.other.id}]
        })

      %{post: post}
    end

    defp sub_named(parent_id, name) do
      CMS.list_field_definitions!(authorize?: false)
      |> Enum.find(&(&1.group_of_id == parent_id and &1.name == name))
    end

    # The admin refuses a media or reference sub-field's type on any update
    # while the list is locked, so a rename goes through the string it
    # started as; the sync under test does not look at the type.
    defp rename!(admin, parent_id, name, to) do
      sub = Ash.Seed.update!(sub_named(parent_id, name), %{field_type: :string})
      CMS.update_field_definition!(sub, %{name: to}, actor: admin)
    end

    test "renaming a sub-field moves its edge key and its descendants'", ctx do
      rename!(ctx.admin, ctx.section.id, "cta", "button")

      assert {"sections.section.button", ctx.target.id} in edges(ctx.post)

      CMS.update_field_definition!(sub_named(ctx.section.id, "rows"), %{name: "lines"},
        actor: ctx.admin
      )

      assert {"sections.section.lines.row.cta", ctx.other.id} in edges(ctx.post)
      assert length(edges(ctx.post)) == 3
    end

    test "renaming an item type rewrites the edges under it", ctx do
      CMS.update_field_definition!(ctx.section, %{name: "block"}, actor: ctx.admin)

      assert {"sections.block.cta", ctx.target.id} in edges(ctx.post)
      assert {"sections.block.rows.row.cta", ctx.other.id} in edges(ctx.post)
      assert length(edges(ctx.post)) == 3
    end

    test "renaming a group sub-field and a top-level field moves their edges", ctx do
      visits = ctx.visits

      rename!(ctx.admin, visits.id, "doctor", "physician")

      assert {"visits.physician", ctx.other.id} in edges(ctx.post)

      CMS.update_field_definition!(ctx.sections, %{name: "blocks"}, actor: ctx.admin)
      assert {"blocks.section.cta", ctx.target.id} in edges(ctx.post)
      assert {"blocks.section.rows.row.cta", ctx.other.id} in edges(ctx.post)
      assert raw(ctx.post)["blocks"]
    end

    test "destroying a sub-field purges its edges, descendants included", ctx do
      CMS.destroy_field_definition!(sub_named(ctx.section.id, "cta"), actor: ctx.admin)
      assert {"sections.section.cta", ctx.target.id} not in edges(ctx.post)
      assert length(edges(ctx.post)) == 2

      CMS.destroy_field_definition!(sub_named(ctx.section.id, "rows"), %{}, actor: ctx.admin)
      assert edges(ctx.post) == [{"visits.doctor", ctx.other.id}]
    end

    test "destroying a group sub-field or a whole field purges its edges", ctx do
      CMS.destroy_field_definition!(sub_named(ctx.visits.id, "doctor"), actor: ctx.admin)
      assert length(edges(ctx.post)) == 2

      CMS.destroy_field_definition!(ctx.sections, actor: ctx.admin)
      assert edges(ctx.post) == []
    end

    test "destroying an item type purges its edges, with its items or after them", ctx do
      CMS.destroy_field_definition!(ctx.section, %{purge_items?: true}, actor: ctx.admin)

      assert edges(ctx.post) == [{"visits.doctor", ctx.other.id}]
      assert stored(ctx.post)["sections"] in [nil, []]
    end

    test "a name's underscore matches only itself, so a sibling field's edges stay", ctx do
      pair = fn name ->
        flex = def!(ctx.admin, %{content_type: :post, name: name, field_type: :flexible})
        type = item_type!(ctx.admin, flex, "t")
        sub!(ctx.admin, type, "cta", :reference)
        flex
      end

      a = pair.("hero_a")
      _b = pair.("heroxa")

      post =
        post!(ctx.editor, %{
          "hero_a" => [%{"_type" => "t", "cta" => ctx.target.id}],
          "heroxa" => [%{"_type" => "t", "cta" => ctx.other.id}]
        })

      CMS.destroy_field_definition!(a, actor: ctx.admin)

      assert edges(post) == [{"heroxa.t.cta", ctx.other.id}]
    end
  end

  describe "ClearReferenceOptions and ClearInverse on a nested reference" do
    test "a reference inside an item or group keeps no target-side option" do
      for parent <- [:group_of_id, :flex_of_id] do
        changeset =
          KilnCMS.CMS.FieldDefinition
          |> Ash.Changeset.new()
          |> Ash.Changeset.force_change_attribute(:field_type, :reference)
          |> Ash.Changeset.force_change_attribute(parent, Ash.UUID.generate())
          |> Ash.Changeset.force_change_attribute(:max_sources, 3)
          |> Ash.Changeset.force_change_attribute(:on_target_delete, :restrict)
          |> Ash.Changeset.force_change_attribute(:schema_org_property, "about")
          |> Ash.Changeset.force_change_attribute(:selection, %{"states" => ["published"]})
          |> Ash.Changeset.force_change_attribute(:inverse_label, "Used by")
          |> Ash.Changeset.force_change_attribute(:inverse_name, "used_by")

        changeset =
          changeset
          |> KilnCMS.CMS.Changes.ClearReferenceOptions.change([], %{})
          |> KilnCMS.CMS.Changes.ClearInverse.change([], %{})

        for {key, cleared} <- [
              max_sources: nil,
              on_target_delete: :keep,
              schema_org_property: nil,
              selection: nil,
              inverse_label: nil,
              inverse_name: nil
            ] do
          assert Ash.Changeset.get_attribute(changeset, key) == cleared, "#{parent} #{key}"
        end
      end
    end

    test "a top-level reference keeps them" do
      changeset =
        KilnCMS.CMS.FieldDefinition
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:field_type, :reference)
        |> Ash.Changeset.force_change_attribute(:max_sources, 3)
        |> Ash.Changeset.force_change_attribute(:on_target_delete, :restrict)
        |> KilnCMS.CMS.Changes.ClearReferenceOptions.change([], %{})

      assert Ash.Changeset.get_attribute(changeset, :max_sources) == 3
      assert Ash.Changeset.get_attribute(changeset, :on_target_delete) == :restrict
    end
  end

  describe "mix kiln.media.resnapshot" do
    # A stored value as an earlier release left it: no variants, an old url.
    defp stale_pic(media), do: %{"id" => media.id, "url" => "/old.png", "alt" => "Old alt"}

    test "re-takes media in items and rows, leaves references as stored, then settles", ctx do
      org = KilnCMS.Accounts.default_org_id()
      stale_ref = %{"id" => ctx.target.id, "type" => "page", "slug" => "old", "title" => "Old"}

      post = post!(ctx.editor, %{})

      post =
        Ash.Seed.update!(post, %{
          custom_fields: %{
            "sections" => [
              %{
                "_id" => Ash.UUID.generate(),
                "_type" => "section",
                "cta" => stale_ref,
                "pic" => stale_pic(ctx.media),
                "rows" => [
                  %{
                    "_id" => Ash.UUID.generate(),
                    "_type" => "row",
                    "pic" => stale_pic(ctx.media),
                    "cta" => stale_ref
                  }
                ]
              }
            ],
            "visits" => [%{"photo" => stale_pic(ctx.media), "doctor" => stale_ref}]
          }
        })

      dry = Resnapshot.run(org, dry_run?: true)
      assert dry.stale >= 1
      assert dry.written == 0
      assert dry.failed == []
      assert stored(post) == post.custom_fields

      report = Resnapshot.run(org)
      assert report.written == dry.stale
      assert report.failed == []

      fresh = Snapshot.of(ctx.media)
      [section] = stored(post)["sections"]
      assert section["pic"] == fresh
      assert hd(section["rows"])["pic"] == fresh
      assert hd(stored(post)["visits"])["photo"] == fresh

      # The references are exactly what was stored, however stale.
      assert section["cta"] == stale_ref
      assert hd(section["rows"])["cta"] == stale_ref
      assert hd(stored(post)["visits"])["doctor"] == stale_ref

      assert %{stale: 0, written: 0} = Resnapshot.run(org)
    end

    # The pass is media-only: whatever else the stored value has drifted into
    # (a required sub-field added since, an item type the field no longer has,
    # a key no sub-field declares) is kept as stored and never refuses it.
    test "a stale record still refreshes its media: nothing else is re-judged", ctx do
      org = KilnCMS.Accounts.default_org_id()
      stale_ref = %{"id" => ctx.target.id, "type" => "page", "slug" => "old", "title" => "Old"}
      sub!(ctx.admin, ctx.section, "kicker", :string, %{required: true, position: 9})
      sub!(ctx.admin, ctx.visits, "badge", :string, %{required: true, position: 9})

      post = post!(ctx.editor, %{})

      stored_value = %{
        "sections" => [
          %{
            "_id" => Ash.UUID.generate(),
            "_type" => "section",
            "pic" => stale_pic(ctx.media),
            "cta" => stale_ref,
            "legacy" => "kept"
          },
          %{"_id" => Ash.UUID.generate(), "_type" => "retired", "note" => "orphan"}
        ],
        "visits" => [%{"photo" => stale_pic(ctx.media), "stray" => "kept"}]
      }

      post = Ash.Seed.update!(post, %{custom_fields: stored_value})

      dry = Resnapshot.run(org, dry_run?: true)
      assert dry.stale >= 1
      assert dry.failed == []
      assert stored(post) == stored_value

      report = Resnapshot.run(org)
      assert report.failed == []
      assert report.written == dry.stale

      fresh = Snapshot.of(ctx.media)
      [section, orphan] = stored(post)["sections"]
      assert section["pic"] == fresh
      assert section["cta"] == stale_ref
      assert section["legacy"] == "kept"
      assert orphan == Enum.at(stored_value["sections"], 1)
      assert [%{"photo" => ^fresh, "stray" => "kept"}] = stored(post)["visits"]

      assert %{stale: 0, written: 0} = Resnapshot.run(org)
    end

    test "a trashed record is re-snapshotted without a fire and counted as trashed", ctx do
      org = KilnCMS.Accounts.default_org_id()
      post = post!(ctx.editor, %{})

      post =
        Ash.Seed.update!(post, %{
          custom_fields: %{
            "sections" => [
              %{"_id" => Ash.UUID.generate(), "_type" => "section", "pic" => stale_pic(ctx.media)}
            ]
          }
        })

      CMS.destroy_post!(post, actor: ctx.admin)

      report = Resnapshot.run(org)
      assert report.trashed >= 1
      assert report.trashed_failed == []

      trashed =
        CMS.list_trashed_posts!(authorize?: false, tenant: org) |> Enum.find(&(&1.id == post.id))

      assert hd(trashed.custom_fields["sections"])["pic"] == Snapshot.of(ctx.media)
    end

    test "an item naming media that no longer exists fails that record, not the run", ctx do
      org = KilnCMS.Accounts.default_org_id()
      post = post!(ctx.editor, %{})

      post =
        Ash.Seed.update!(post, %{
          custom_fields: %{
            "sections" => [
              %{
                "_id" => Ash.UUID.generate(),
                "_type" => "section",
                "pic" => %{"id" => Ash.UUID.generate(), "url" => "/gone.png"}
              }
            ]
          }
        })

      report = Resnapshot.run(org)

      assert Enum.any?(report.failed, fn {_type, id, message} ->
               id == post.id and message =~ "sections[0].pic"
             end)
    end
  end

  describe "FieldDisplay" do
    test "a flexible field reads as its items, media and references resolved", ctx do
      post =
        post!(ctx.editor, %{
          "sections" => [
            item(%{
              "title" => "Intro",
              "cta" => ctx.target.id,
              "pic" => ctx.media.id,
              "rows" => [%{"_type" => "row", "cta" => ctx.other.id}]
            })
          ]
        })

      definitions = CMS.field_definitions_for!(:post, authorize?: false)
      sections = Enum.find(definitions, &(&1.name == "sections"))
      value = stored(post)["sections"]

      diff = %VersionDiff{
        fields: [
          %VersionDiff.Field{
            name: :custom_fields,
            entries: [%{key: "sections", old: nil, new: value}]
          }
        ]
      }

      context = FieldDisplay.context(definitions, diff, ctx.admin, post.org_id)
      assert context.refs[ctx.target.id] == "Target page"
      assert context.refs[ctx.other.id] == "Other page"
      assert context.media[ctx.media.id] == ctx.media.filename

      text = FieldDisplay.display(sections, value, context)
      assert text =~ "Intro"
      assert text =~ "Target page"
      assert text =~ ctx.media.filename
      refute text =~ ctx.target.id
      refute text =~ ctx.media.id

      # A reader who cannot read the targets gets ids, never a stored title.
      empty = FieldDisplay.display(sections, value, FieldDisplay.empty_context())
      refute empty =~ "Target page"
      refute empty =~ "Other page"
    end
  end

  describe "copies and portability" do
    alias KilnCMS.CMS.{Duplication, Translations}
    alias KilnCMS.Portability.{Export, Import}

    setup ctx do
      org = KilnCMS.Accounts.default_org_id()

      source =
        post!(ctx.editor, %{
          "sections" => [
            item(%{"title" => "Intro", "cta" => ctx.target.id, "pic" => ctx.media.id})
          ],
          "visits" => [%{"place" => "Clinic", "doctor" => ctx.target.id}]
        })

      %{org: org, source: source}
    end

    test "a duplicate re-resolves what the source holds, as the copier", ctx do
      CMS.update_page!(ctx.target, %{title: "Renamed target"}, actor: ctx.admin)

      copy =
        Duplication.duplicate!(:post, ctx.source, actor: ctx.editor, tenant: ctx.org)

      assert %{"cta" => %{"title" => "Renamed target"}, "pic" => pic, "title" => "Intro"} =
               hd(stored(copy)["sections"])

      assert pic == Snapshot.of(ctx.media)
      assert [%{"doctor" => %{"title" => "Renamed target"}}] = stored(copy)["visits"]

      assert edges(copy) == [
               {"sections.section.cta", ctx.target.id},
               {"visits.doctor", ctx.target.id}
             ]
    end

    test "a locale copy re-resolves too", ctx do
      {copy, _withheld} =
        Translations.create_translation_with_notes!(:post, ctx.source, "fr",
          actor: ctx.editor,
          tenant: ctx.org
        )

      assert %{"cta" => %{"id" => id}, "pic" => %{"id" => media_id}} =
               hd(stored(copy)["sections"])

      assert id == ctx.target.id
      assert media_id == ctx.media.id
    end

    test "a copy fails closed on a stored reference that no longer resolves", ctx do
      CMS.destroy_page!(ctx.target, actor: ctx.admin)

      error =
        assert_raise Ash.Error.Invalid, fn ->
          Duplication.duplicate!(:post, ctx.source, actor: ctx.editor, tenant: ctx.org)
        end

      assert Exception.message(error) =~ "sections[0].cta"
      refute Exception.message(error) =~ "Target page"
    end

    test "a stored reference to another site's record is not copied", ctx do
      org = KilnCMS.OrgFixtures.org("itemref-copy")

      foreign =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Foreign",
          slug: slug(),
          state: :published,
          org_id: org.id
        })

      forged = Map.put(reference(foreign), "title", "Forged")

      source =
        Ash.Seed.update!(ctx.source, %{
          custom_fields: %{"sections" => [item(%{"title" => "Intro", "cta" => forged})]}
        })

      result =
        try do
          {:ok, Duplication.duplicate!(:post, source, actor: ctx.editor, tenant: ctx.org)}
        rescue
          error -> {:error, error}
        end

      case result do
        {:ok, copy} -> refute inspect(stored(copy)) =~ foreign.id
        {:error, _error} -> :ok
      end
    end

    test "an export carries the items; an import rebuilds their snapshots and refuses unknown ids",
         ctx do
      {:ok, envelope} = Export.run(["post"], actor: ctx.admin, tenant: ctx.org)
      record = Enum.find(envelope["records"], &(&1["slug"] == ctx.source.slug))

      assert %{"cta" => %{"id" => _}, "pic" => %{"id" => _}} =
               hd(record["custom_fields"]["sections"])

      forged =
        put_in(record, ["custom_fields", "sections", Access.at(0), "cta", "title"], "Forged")

      forged = Map.put(forged, "slug", slug())

      {:ok, report} =
        Import.run_envelope(%{"records" => [forged]},
          actor: ctx.editor,
          tenant: ctx.org,
          skip_media: true
        )

      assert report.failed == []
      [created] = report.created

      assert %{"cta" => %{"title" => "Target page"}} =
               hd(stored(%{id: created.id})["sections"])

      # Another install's ids mean nothing here: the record fails, at the item's path.
      stranger = Ecto.UUID.generate()

      stranger_record =
        record
        |> Map.put("slug", slug())
        |> put_in(["custom_fields", "sections", Access.at(0), "cta"], %{
          "id" => stranger,
          "type" => "page"
        })

      {:ok, report} =
        Import.run_envelope(%{"records" => [stranger_record]},
          actor: ctx.editor,
          tenant: ctx.org,
          skip_media: true
        )

      assert report.created == []
      assert [%{} = failed] = report.failed
      assert inspect(failed) =~ "sections[0].cta"
    end
  end

  describe "the type list" do
    test "an item type takes a media or reference sub-field; a plain group's rows still do not",
         ctx do
      for type <- [:media, :reference] do
        assert {:ok, %{field_type: ^type}} =
                 CMS.create_field_definition(
                   %{
                     name: "extra_#{type}",
                     label: "Extra",
                     field_type: type,
                     group_of_id: ctx.section.id,
                     target_type: "page"
                   },
                   actor: ctx.admin
                 )

        assert {:error, _} =
                 CMS.create_field_definition(
                   %{
                     name: "nope",
                     label: "Nope",
                     field_type: type,
                     group_of_id: ctx.visits.id,
                     target_type: "page"
                   },
                   actor: ctx.admin
                 )
      end
    end

    test "an item's reference needs a target, and carries no cap, rule, inverse or selection",
         ctx do
      assert {:error, _} =
               CMS.create_field_definition(
                 %{
                   name: "aimless",
                   label: "Aimless",
                   field_type: :reference,
                   group_of_id: ctx.section.id
                 },
                 actor: ctx.admin
               )

      ref =
        CMS.create_field_definition!(
          %{
            name: "capped",
            label: "Capped",
            field_type: :reference,
            group_of_id: ctx.section.id,
            target_types: ["page", "post"],
            max_sources: 1,
            on_target_delete: :clear,
            inverse_label: "Used by",
            inverse_name: "used_by",
            multiple: true
          },
          actor: ctx.admin
        )

      assert ref.max_sources == nil
      assert ref.on_target_delete == :keep
      assert ref.inverse_name == nil and ref.inverse_label == nil
      assert ref.multiple == false
    end

    test "no sub-field of an item can be private, so a masked value never hides inside one",
         ctx do
      for type <- [:media, :reference] do
        assert {:error, _} =
                 CMS.create_field_definition(
                   %{
                     name: "secret_#{type}",
                     label: "Secret",
                     field_type: type,
                     group_of_id: ctx.section.id,
                     target_type: "page",
                     private: true
                   },
                   actor: ctx.admin
                 )
      end
    end

    test "an editor cannot define one", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_definition(
                 %{
                   name: "mine",
                   label: "Mine",
                   field_type: :media,
                   group_of_id: ctx.section.id
                 },
                 actor: ctx.editor
               )
    end
  end

  defp reference(page),
    do: %{"id" => page.id, "type" => "page", "slug" => page.slug, "title" => page.title}
end
