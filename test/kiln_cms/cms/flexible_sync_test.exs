defmodule KilnCMS.CMS.FlexibleSyncTest do
  @moduledoc """
  Stored items follow their definitions (#2282,
  `docs/flexible-content-plan.md` section 8): renaming or destroying an item
  type or a sub-field of one rewrites the items in `custom_fields` through the
  path to them (`KilnCMS.CMS.FlexiblePath`), at depth 1 and at the depth cap, on
  compiled and dynamic types; the owner walks reach the owning type (so it is
  swept); and an item type with stored items is not destroyed by accident.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "flexs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "flexs-#{System.unique_integer([:positive])}"

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)

  defp item_type!(admin, flexible, name, attrs \\ %{}),
    do: def!(admin, Map.merge(%{name: name, field_type: :group, flex_of_id: flexible.id}, attrs))

  defp sub!(admin, parent, name, attrs \\ %{}),
    do: def!(admin, Map.merge(%{name: name, group_of_id: parent.id, field_type: :string}, attrs))

  defp stored(post, admin), do: CMS.get_post!(post.id, actor: admin).custom_fields

  # The raw jsonb, so a rewrite is read as the database holds it.
  defp raw(post) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!("SELECT custom_fields FROM posts WHERE id = $1", [
        Ecto.UUID.dump!(post.id)
      ])

    value
  end

  # sections (1) > hero.rows (2) > row.cells (3) > cell.text
  #
  # `extras` is a second flexible field of the type whose item type is also
  # called "hero" with a "headline": a rewrite of `sections.hero.headline` must
  # leave it alone, as it must `sections.quote.headline`.
  setup do
    admin = user(:admin)

    sections = def!(admin, %{content_type: :post, name: "sections", field_type: :flexible})
    hero = item_type!(admin, sections, "hero")
    headline = sub!(admin, hero, "headline")

    tone =
      sub!(admin, hero, "tone", %{
        field_type: :select,
        options: ["dark", "light"],
        item_setting: true,
        position: 1
      })

    rows = sub!(admin, hero, "rows", %{field_type: :flexible, position: 2})
    row = item_type!(admin, rows, "row")
    label = sub!(admin, row, "label")
    cells = sub!(admin, row, "cells", %{field_type: :flexible, position: 1})
    cell = item_type!(admin, cells, "cell")
    text = sub!(admin, cell, "text")
    note = item_type!(admin, cells, "note", %{position: 1})
    sub!(admin, note, "text")

    quote_type = item_type!(admin, sections, "quote", %{position: 1})
    quote_headline = sub!(admin, quote_type, "headline")

    extras = def!(admin, %{content_type: :post, name: "extras", field_type: :flexible})
    extra_hero = item_type!(admin, extras, "hero")
    sub!(admin, extra_hero, "headline")

    post =
      CMS.create_post!(
        %{
          title: "P",
          slug: slug(),
          custom_fields: %{
            "sections" => [
              %{
                "_type" => "hero",
                "headline" => "H",
                "_settings" => %{"tone" => "dark"},
                "rows" => [
                  %{
                    "_type" => "row",
                    "label" => "R",
                    "cells" => [
                      %{"_type" => "cell", "text" => "c1"},
                      %{"_type" => "note", "text" => "n1"}
                    ]
                  }
                ]
              },
              %{"_type" => "quote", "headline" => "Q"}
            ],
            "extras" => [%{"_type" => "hero", "headline" => "X"}]
          }
        },
        actor: admin
      )

    %{
      admin: admin,
      post: post,
      sections: sections,
      hero: hero,
      headline: headline,
      tone: tone,
      rows: rows,
      row: row,
      label: label,
      cells: cells,
      cell: cell,
      text: text,
      quote_type: quote_type,
      quote_headline: quote_headline,
      note: note,
      extras: extras,
      extra_hero: extra_hero
    }
  end

  defp hero_of(fields), do: fields["sections"] |> Enum.at(0)
  defp row_of(fields), do: fields |> hero_of() |> Map.fetch!("rows") |> Enum.at(0)
  defp cells_of(fields), do: fields |> row_of() |> Map.fetch!("cells")

  describe "renaming a sub-field of an item type" do
    test "at depth 1, inside the right type of the right flexible field only", ctx do
      CMS.update_field_definition!(ctx.headline, %{name: "title"}, actor: ctx.admin)

      fields = raw(ctx.post)
      assert hero_of(fields)["title"] == "H"
      refute Map.has_key?(hero_of(fields), "headline")
      # the other type of the same field, and the same names in another field
      assert Enum.at(fields["sections"], 1)["headline"] == "Q"
      assert [%{"headline" => "X"}] = fields["extras"]
      # ids, types and everything else are untouched
      assert hero_of(fields)["_type"] == "hero"
      assert row_of(fields)["label"] == "R"
    end

    test "at depth 3, inside the right item type only", ctx do
      CMS.update_field_definition!(ctx.text, %{name: "body"}, actor: ctx.admin)

      assert [%{"_type" => "cell", "body" => "c1"}, %{"_type" => "note", "text" => "n1"}] =
               cells_of(raw(ctx.post))
    end

    test "a setting is renamed inside _settings", ctx do
      CMS.update_field_definition!(ctx.tone, %{name: "mood"}, actor: ctx.admin)

      assert %{"mood" => "dark"} = hero_of(raw(ctx.post))["_settings"]
      refute Map.has_key?(hero_of(raw(ctx.post))["_settings"], "tone")
    end

    test "a flexible sub-field is renamed like any other key", ctx do
      CMS.update_field_definition!(ctx.rows, %{name: "lines"}, actor: ctx.admin)

      hero = hero_of(raw(ctx.post))
      assert [%{"_type" => "row"}] = hero["lines"]
      refute Map.has_key?(hero, "rows")
    end

    test "the owning type is swept at depth 1 and at depth 3", ctx do
      CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      CMS.update_field_definition!(ctx.headline, %{name: "title"}, actor: ctx.admin)
      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => ctx.post.id})

      KilnCMS.DataCase.drain_oban()
      refute_enqueued(worker: KilnCMS.Firing.FireWorker)

      CMS.update_field_definition!(ctx.text, %{name: "body"}, actor: ctx.admin)
      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => ctx.post.id})
    end
  end

  describe "destroying a sub-field of an item type" do
    test "purges the key from every item of that type, at depth 1", ctx do
      CMS.destroy_field_definition!(ctx.headline, actor: ctx.admin)

      fields = raw(ctx.post)
      refute Map.has_key?(hero_of(fields), "headline")
      assert Map.has_key?(hero_of(fields), "rows")
      assert Enum.at(fields["sections"], 1)["headline"] == "Q"
      assert [%{"headline" => "X"}] = fields["extras"]
    end

    test "an item it empties is dropped, and an emptied list loses its key", ctx do
      # (depth 3) the cell holds only `text`; the note keeps its own
      CMS.destroy_field_definition!(ctx.text, actor: ctx.admin)

      # the note's `text` is a different sub-field of a different item type
      assert [%{"_type" => "note", "text" => "n1"}] = cells_of(raw(ctx.post))

      # the quote holds only a headline: purging it drops the quote
      CMS.destroy_field_definition!(ctx.quote_headline, actor: ctx.admin)
      assert [%{"_type" => "hero"}] = raw(ctx.post)["sections"]
    end

    test "a setting is removed from _settings, which goes when it empties", ctx do
      CMS.destroy_field_definition!(ctx.tone, actor: ctx.admin)

      refute Map.has_key?(hero_of(raw(ctx.post)), "_settings")
      assert hero_of(raw(ctx.post))["headline"] == "H"
    end

    test "a nested flexible sub-field is purged with every item below it", ctx do
      CMS.destroy_field_definition!(ctx.rows, actor: ctx.admin)

      refute Map.has_key?(hero_of(raw(ctx.post)), "rows")
    end
  end

  describe "renaming an item type" do
    test "rewrites _type in that field only, at depth 1", ctx do
      CMS.update_field_definition!(ctx.hero, %{name: "banner"}, actor: ctx.admin)

      fields = raw(ctx.post)
      assert hero_of(fields)["_type"] == "banner"
      assert hero_of(fields)["headline"] == "H"
      assert [%{"_type" => "hero"}] = fields["extras"]
      assert Enum.at(fields["sections"], 1)["_type"] == "quote"
    end

    test "and at depth 3", ctx do
      CMS.update_field_definition!(ctx.cell, %{name: "box"}, actor: ctx.admin)

      assert [%{"_type" => "box"}, %{"_type" => "note"}] = cells_of(raw(ctx.post))
    end

    test "the next write still validates against the new name", ctx do
      CMS.update_field_definition!(ctx.hero, %{name: "banner"}, actor: ctx.admin)

      assert {:ok, _} =
               CMS.update_post(
                 ctx.post,
                 %{custom_fields: %{"sections" => stored(ctx.post, ctx.admin)["sections"]}},
                 actor: ctx.admin
               )
    end
  end

  describe "deleting an item type" do
    test "is refused while items of it exist, at depth 1 and at depth 3", ctx do
      assert {:error, error} = CMS.destroy_field_definition(ctx.hero, actor: ctx.admin)
      assert Exception.message(error) =~ "purge_items?"
      assert Exception.message(error) =~ "hero"

      assert {:error, error} = CMS.destroy_field_definition(ctx.cell, actor: ctx.admin)
      assert Exception.message(error) =~ "cell"

      # nothing was lost
      assert length(cells_of(raw(ctx.post))) == 2
    end

    test "a name another flexible field's items share does not count", ctx do
      # `extras` holds a hero too; remove the one in `sections` first
      CMS.destroy_field_definition!(ctx.hero, %{purge_items?: true}, actor: ctx.admin)

      # an item type with the same name in `extras` is guarded by `extras`' items
      assert {:error, _} = CMS.destroy_field_definition(ctx.extra_hero, actor: ctx.admin)
    end

    test "is allowed when no item of it exists", ctx do
      unused = item_type!(ctx.admin, ctx.sections, "unused", %{position: 5})
      assert :ok = CMS.destroy_field_definition(unused, actor: ctx.admin)

      # `cell` has items, `note` has items; a type with none at depth 3 does not
      spare = item_type!(ctx.admin, ctx.cells, "spare", %{position: 5})
      assert :ok = CMS.destroy_field_definition(spare, actor: ctx.admin)
    end

    test "with purge_items?: true removes its items and leaves the rest, at depth 1", ctx do
      assert :ok =
               CMS.destroy_field_definition(ctx.quote_type, %{purge_items?: true},
                 actor: ctx.admin
               )

      fields = raw(ctx.post)
      assert [%{"_type" => "hero"}] = fields["sections"]
      assert [%{"headline" => "X"}] = fields["extras"]
    end

    test "with purge_items?: true removes its items at depth 3", ctx do
      assert :ok = CMS.destroy_field_definition(ctx.cell, %{purge_items?: true}, actor: ctx.admin)

      assert [%{"_type" => "note", "text" => "n1"}] = cells_of(raw(ctx.post))
    end

    test "purging the last item of a list removes the list's key", ctx do
      CMS.destroy_field_definition!(ctx.quote_type, %{purge_items?: true}, actor: ctx.admin)
      CMS.destroy_field_definition!(ctx.cell, %{purge_items?: true}, actor: ctx.admin)
      CMS.destroy_field_definition!(ctx.note, %{purge_items?: true}, actor: ctx.admin)

      refute Map.has_key?(row_of(raw(ctx.post)), "cells")
    end

    test "an item type whose flexible field is destroyed goes with it, unguarded", ctx do
      assert :ok = CMS.destroy_field_definition(ctx.extras, actor: ctx.admin)

      refute Map.has_key?(raw(ctx.post), "extras")
      assert length(raw(ctx.post)["sections"]) == 2
    end

    test "purging an item type sweeps the owning type", ctx do
      CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      CMS.destroy_field_definition!(ctx.cell, %{purge_items?: true}, actor: ctx.admin)
      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => ctx.post.id})
    end
  end

  describe "a dynamic type" do
    setup %{admin: admin} do
      type =
        CMS.create_type_definition!(
          %{name: "gizmo_#{System.unique_integer([:positive])}", label: "Gizmo"},
          actor: admin
        )

      blocks = def!(admin, %{type_definition_id: type.id, name: "blocks", field_type: :flexible})
      part = item_type!(admin, blocks, "part")
      title = sub!(admin, part, "title")
      subs = sub!(admin, part, "subs", %{field_type: :flexible, position: 1})
      leaf = item_type!(admin, subs, "leaf")
      deep = sub!(admin, leaf, "deep", %{field_type: :flexible})
      bit = item_type!(admin, deep, "bit")
      leaf_name = sub!(admin, bit, "name")

      entry =
        CMS.create_entry!(
          %{
            title: "E",
            slug: slug(),
            type_definition_id: type.id,
            custom_fields: %{
              "blocks" => [
                %{
                  "_type" => "part",
                  "title" => "T",
                  "subs" => [
                    %{"_type" => "leaf", "deep" => [%{"_type" => "bit", "name" => "L"}]}
                  ]
                }
              ]
            }
          },
          actor: admin
        )

      %{entry: entry, part: part, title: title, leaf: leaf, bit: bit, leaf_name: leaf_name}
    end

    defp entry_raw(entry) do
      %{rows: [[value]]} =
        KilnCMS.Repo.query!("SELECT custom_fields FROM entries WHERE id = $1", [
          Ecto.UUID.dump!(entry.id)
        ])

      value
    end

    test "renames and purges at depth 1 and 3", ctx do
      CMS.update_field_definition!(ctx.title, %{name: "heading"}, actor: ctx.admin)
      CMS.update_field_definition!(ctx.leaf_name, %{name: "label"}, actor: ctx.admin)

      assert %{
               "blocks" => [
                 %{
                   "heading" => "T",
                   "subs" => [%{"deep" => [%{"_type" => "bit", "label" => "L"}]}]
                 }
               ]
             } = entry_raw(ctx.entry)

      CMS.update_field_definition!(ctx.bit, %{name: "tip"}, actor: ctx.admin)

      assert %{"blocks" => [%{"subs" => [%{"deep" => [%{"_type" => "tip"}]}]}]} =
               entry_raw(ctx.entry)

      assert {:error, _} = CMS.destroy_field_definition(ctx.part, actor: ctx.admin)
      assert :ok = CMS.destroy_field_definition(ctx.part, %{purge_items?: true}, actor: ctx.admin)
      refute Map.has_key?(entry_raw(ctx.entry), "blocks")
    end
  end
end
