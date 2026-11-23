defmodule KilnCMS.CMS.FlexibleGrantsTest do
  @moduledoc """
  Per-item-type write grants on a `:flexible` field (#2282, PR 4,
  `docs/flexible-content-plan.md` section 8): `custom_fields.<field>.<item type>`
  lets an editor edit, add and remove the items of that type, matched by `_id`;
  the whole-field entry covers everything, and reordering needs it.
  """
  # async: false — the private-field name cache is global per org.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Duplication
  alias KilnCMS.CMS.FieldAccess

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "flexg-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp editor(entries), do: user(:editor, %{field_grants: %{"post" => entries}})

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)

  defp slug, do: "flexg-#{System.unique_integer([:positive])}"

  defp put_items(post, items, actor, extra \\ %{}),
    do: CMS.update_post(post, %{custom_fields: Map.merge(%{"fg" => items}, extra)}, actor: actor)

  defp hd_item_type(definitions, name) do
    definitions
    |> Enum.flat_map(&KilnCMS.CMS.FieldDefinition.item_types/1)
    |> Enum.find(&(&1.name == name))
  end

  defp refused?({:error, %Ash.Error.Invalid{} = error}, key),
    do: Exception.message(error) =~ key and Exception.message(error) =~ "field grant"

  defp refused?(_other, _key), do: false

  defp items(post, actor), do: CMS.get_post!(post.id, actor: actor).custom_fields["fg"]

  setup do
    admin = user(:admin)
    flexible = def!(admin, %{content_type: :post, name: "fg", field_type: :flexible})

    hero = def!(admin, %{name: "hero", field_type: :group, flex_of_id: flexible.id})
    quote_type = def!(admin, %{name: "quote", field_type: :group, flex_of_id: flexible.id})

    for {parent, name} <- [{hero, "headline"}, {quote_type, "text"}] do
      def!(admin, %{name: name, field_type: :string, group_of_id: parent.id})
    end

    def!(admin, %{name: "notes", content_type: :post, field_type: :string})

    post =
      CMS.create_post!(
        %{
          title: "Page",
          slug: slug(),
          custom_fields: %{
            "notes" => "n",
            "fg" => [
              %{"_type" => "hero", "headline" => "H1"},
              %{"_type" => "quote", "text" => "Q1"},
              %{"_type" => "hero", "headline" => "H2"}
            ]
          }
        },
        actor: admin
      )

    %{admin: admin, post: post, stored: post.custom_fields["fg"]}
  end

  describe "an item-type grant" do
    test "edits an item of its type and nothing else", %{post: post, stored: [h1, q1, h2]} do
      editor = editor(["custom_fields.fg.hero"])

      assert {:ok, updated} = put_items(post, [%{h1 | "headline" => "New"}, q1, h2], editor)
      assert [%{"headline" => "New"}, ^q1, ^h2] = updated.custom_fields["fg"]
    end

    test "an item of another type is refused, naming its type", %{
      post: post,
      stored: [h1, q1, h2]
    } do
      editor = editor(["custom_fields.fg.hero"])

      assert refused?(
               put_items(post, [h1, %{q1 | "text" => "sneaky"}, h2], editor),
               "custom_fields.fg.quote"
             )

      assert items(post, editor) == [h1, q1, h2]
    end

    test "adds and removes items of its type, not of another", %{
      post: post,
      stored: [h1, q1, h2]
    } do
      editor = editor(["custom_fields.fg.hero"])

      assert {:ok, added} =
               put_items(post, [h1, q1, h2, %{"_type" => "hero", "headline" => "H3"}], editor)

      assert length(added.custom_fields["fg"]) == 4
      assert {:ok, removed} = put_items(added, [q1, h2], editor)
      assert [%{"_type" => "quote"}, %{"_type" => "hero"}] = removed.custom_fields["fg"]

      assert refused?(
               put_items(post, [h1, q1, h2, %{"_type" => "quote", "text" => "new"}], editor),
               "custom_fields.fg.quote"
             )

      assert refused?(put_items(post, [h1, h2], editor), "custom_fields.fg.quote")
    end

    test "a type change needs both types", %{post: post, stored: [h1, q1, h2]} do
      editor = editor(["custom_fields.fg.hero"])

      assert refused?(
               put_items(
                 post,
                 [%{"_id" => h1["_id"], "_type" => "quote", "text" => "x"}, q1, h2],
                 editor
               ),
               "custom_fields.fg.quote"
             )

      both = editor(["custom_fields.fg.hero", "custom_fields.fg.quote"])

      assert {:ok, _} =
               put_items(
                 post,
                 [%{"_id" => h1["_id"], "_type" => "quote", "text" => "x"}, q1, h2],
                 both
               )
    end

    test "reordering needs the whole field", %{post: post, stored: [h1, q1, h2]} do
      editor = editor(["custom_fields.fg.hero", "custom_fields.fg.quote"])

      assert refused?(put_items(post, [h2, q1, h1], editor), "custom_fields.fg ")
      assert {:ok, reordered} = put_items(post, [h2, q1, h1], editor(["custom_fields.fg"]))
      assert {:ok, _} = put_items(reordered, [q1, h2, h1], editor(["custom_fields"]))
    end

    test "re-sending the stored items is not a change", %{post: post, stored: stored} do
      editor = editor(["custom_fields.notes"])

      assert {:ok, _} = put_items(post, stored, editor, %{"notes" => "changed"})
    end

    test "a sub-field name is not an item type and grants nothing", %{
      post: post,
      stored: [h1, q1, h2]
    } do
      editor = editor(["custom_fields.fg.headline"])
      assert refused?(put_items(post, [%{h1 | "headline" => "x"}, q1, h2], editor), "fg.hero")
    end

    test "an edit deep inside an item is the item type's edit", %{admin: admin} do
      hero = CMS.field_definitions_for!(:post, actor: admin) |> hd_item_type("hero")
      nested = def!(admin, %{name: "rows", field_type: :flexible, group_of_id: hero.id})
      row = def!(admin, %{name: "row", field_type: :group, flex_of_id: nested.id})
      def!(admin, %{name: "cell", field_type: :string, group_of_id: row.id})

      post =
        CMS.create_post!(
          %{
            title: "Deep",
            slug: slug(),
            custom_fields: %{
              "fg" => [
                %{
                  "_type" => "hero",
                  "headline" => "H",
                  "rows" => [%{"_type" => "row", "cell" => "a"}]
                }
              ]
            }
          },
          actor: admin
        )

      [%{"rows" => [inner]} = hero_item] = post.custom_fields["fg"]
      changed = %{hero_item | "rows" => [%{inner | "cell" => "b"}]}

      assert {:ok, _} = put_items(post, [changed], editor(["custom_fields.fg.hero"]))
      assert refused?(put_items(post, [changed], editor(["custom_fields.fg.quote"])), "fg.hero")
    end

    test "a create is held to the granted types", %{admin: admin} do
      editor = editor(["custom_fields.fg.hero"])

      assert {:ok, created} =
               CMS.create_post(
                 %{
                   title: "New",
                   slug: slug(),
                   custom_fields: %{"fg" => [%{"_type" => "hero", "headline" => "x"}]}
                 },
                 actor: editor
               )

      assert [%{"_type" => "hero"}] = items(created, admin)

      assert refused?(
               CMS.create_post(
                 %{
                   title: "New",
                   slug: slug(),
                   custom_fields: %{"fg" => [%{"_type" => "quote", "text" => "x"}]}
                 },
                 actor: editor
               ),
               "custom_fields.fg.quote"
             )
    end
  end

  describe "FieldAccess" do
    test "writable?/2 takes the type entry or the field entry" do
      assert FieldAccess.writable?(["custom_fields.fg.hero"], ["fg", "hero"])
      refute FieldAccess.writable?(["custom_fields.fg.hero"], ["fg", "quote"])
      refute FieldAccess.writable?(["custom_fields.fg.hero"], ["fg"])
      assert FieldAccess.writable?(["custom_fields.fg"], ["fg", "quote"])
    end

    test "writable_items/3 keeps the writable types in order" do
      items = [%{"_type" => "hero"}, %{"_type" => "quote"}, %{"_type" => "hero", "x" => 1}]

      assert {:ok, [%{"_type" => "hero"}, %{"x" => 1}]} =
               FieldAccess.writable_items(["custom_fields.fg.hero"], "fg", items)

      assert {:ok, []} = FieldAccess.writable_items(["custom_fields.other"], "fg", items)
      assert :error = FieldAccess.writable_items([], "fg", [%{"a" => 1}])
      assert :error = FieldAccess.writable_items([], "fg", "text")
    end

    test "an item type is never a read-grant entry" do
      refute FieldAccess.valid_read_entry?("custom_fields.fg.hero", [])
    end
  end

  describe "a copy" do
    test "carries only the items of the granted types", ctx do
      %{post: post, admin: admin} = ctx
      editor = editor(["title", "custom_fields.fg.hero"])

      {copy, withheld} =
        Duplication.duplicate_with_notes!(:post, post, actor: editor, tenant: post.org_id)

      assert ["hero", "hero"] = Enum.map(items(copy, admin), & &1["_type"])
      assert "custom_fields.fg" in withheld
      assert "custom_fields.notes" in withheld
    end

    test "carries the whole field when every item is of a granted type", ctx do
      %{post: post, admin: admin} = ctx
      editor = editor(["title", "custom_fields.fg.hero", "custom_fields.fg.quote"])

      {copy, withheld} =
        Duplication.duplicate_with_notes!(:post, post, actor: editor, tenant: post.org_id)

      assert length(items(copy, admin)) == 3
      refute "custom_fields.fg" in withheld
    end

    test "a type the editor holds none of leaves the field out", ctx do
      %{post: post, admin: admin} = ctx
      editor = editor(["title", "custom_fields.notes"])

      {copy, withheld} =
        Duplication.duplicate_with_notes!(:post, post, actor: editor, tenant: post.org_id)

      assert CMS.get_post!(copy.id, actor: admin).custom_fields["fg"] in [nil, []]
      assert "custom_fields.fg" in withheld
    end
  end
end
