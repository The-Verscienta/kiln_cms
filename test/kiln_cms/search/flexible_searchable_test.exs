defmodule KilnCMS.Search.FlexibleSearchableTest do
  @moduledoc """
  #2282 PR 6: a `searchable` flexible field is indexed by its items' prose,
  read through the item types' sub-field definitions, and never by an item's
  `_id`, `_type` or `_settings`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SearchableFields

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "F"}, attrs), actor: admin)

  setup do
    admin = admin()

    flexible =
      def!(admin, %{
        content_type: :post,
        name: "fs_sections",
        field_type: :flexible,
        searchable: true
      })

    hero = def!(admin, %{name: "hero", field_type: :group, flex_of_id: flexible.id})
    quote_type = def!(admin, %{name: "quote", field_type: :group, flex_of_id: flexible.id})

    def!(admin, %{name: "headline", group_of_id: hero.id, field_type: :string, searchable: true})

    def!(admin, %{
      name: "background",
      group_of_id: hero.id,
      field_type: :select,
      options: ["zebrastripe", "plain"],
      item_setting: true,
      position: 1
    })

    def!(admin, %{name: "cover", group_of_id: hero.id, field_type: :media, position: 2})
    def!(admin, %{name: "text", group_of_id: quote_type.id, field_type: :text})
    def!(admin, %{name: "n", group_of_id: quote_type.id, field_type: :integer, position: 1})

    %{admin: admin, flexible: flexible}
  end

  defp post!(admin, items) do
    CMS.create_post!(
      %{
        title: "Page",
        slug: "fs-#{System.unique_integer([:positive])}",
        custom_fields: %{"fs_sections" => items}
      },
      actor: admin
    )
  end

  test "the items' text is in search_text; _id, _type and settings are not", %{admin: admin} do
    post =
      post!(admin, [
        %{
          "_type" => "hero",
          "headline" => "Mandrake Root",
          "_settings" => %{"background" => "zebrastripe"}
        },
        %{"_type" => "quote", "text" => "<p>Be <b>brief</b></p>", "n" => 42}
      ])

    post = CMS.get_post!(post.id, actor: admin)
    [hero, quote_item] = post.custom_fields["fs_sections"]
    text = post.search_text

    assert text =~ "Mandrake Root"
    assert text =~ "Be brief"
    assert text =~ "42"
    refute text =~ "zebrastripe"
    refute text =~ hero["_id"]
    refute text =~ quote_item["_id"]
    refute text =~ "hero"
    refute text =~ "quote"
  end

  test "a sub-field's own searchable flag stays cleared", %{admin: admin, flexible: flexible} do
    [hero | _] = loaded(admin, flexible).item_types |> Enum.filter(&(&1.name == "hero"))
    assert Enum.all?(hero.group_fields, &(not &1.searchable))
  end

  test "an unflagged flexible field is not indexed", %{admin: admin, flexible: flexible} do
    CMS.update_field_definition!(flexible, %{searchable: false}, actor: admin)

    post = post!(admin, [%{"_type" => "hero", "headline" => "Hidden"}])
    refute CMS.get_post!(post.id, actor: admin).search_text =~ "Hidden"
  end

  test "media and reference sub-fields contribute nothing; an unknown type falls back",
       %{admin: admin, flexible: flexible} do
    hero = loaded(admin, flexible)
    image = %{"id" => Ecto.UUID.generate(), "title" => "Snapshot Title", "alt" => "alt words"}

    value = [
      %{
        "_id" => "i1",
        "_type" => "gone",
        "free" => "Fallback prose",
        "_settings" => %{"a" => "x"}
      }
    ]

    assert SearchableFields.texts(%{"fs_sections" => value}, [hero]) == ["Fallback prose"]

    typed = [%{"_id" => "i2", "_type" => "hero", "headline" => "Real", "cover" => image}]
    assert SearchableFields.texts(%{"fs_sections" => typed}, [hero]) == ["Real"]
  end

  test "nested flexible fields are read down their own item types", %{
    admin: admin,
    flexible: flexible
  } do
    inner =
      def!(admin, %{name: "inner", group_of_id: hero_id(admin, flexible), field_type: :flexible})

    leaf = def!(admin, %{name: "leaf", field_type: :group, flex_of_id: inner.id})
    def!(admin, %{name: "word", group_of_id: leaf.id, field_type: :string})

    post =
      post!(admin, [
        %{
          "_type" => "hero",
          "headline" => "Outer",
          "inner" => [%{"_type" => "leaf", "word" => "Innermost"}]
        }
      ])

    text = CMS.get_post!(post.id, actor: admin).search_text
    assert text =~ "Outer"
    assert text =~ "Innermost"
    refute text =~ "leaf"
  end

  test "the generic rule an extractor reuses skips _-prefixed keys too" do
    value = [
      %{"_id" => "9d7e6c1a-0000", "_type" => "hero", "_settings" => %{"a" => "x"}, "t" => "Prose"}
    ]

    assert SearchableFields.default_texts(value) == ["Prose"]
  end

  defp loaded(admin, flexible) do
    :post |> CMS.field_definitions_for!(actor: admin) |> Enum.find(&(&1.id == flexible.id))
  end

  defp hero_id(admin, flexible) do
    loaded(admin, flexible).item_types |> Enum.find(&(&1.name == "hero")) |> Map.fetch!(:id)
  end
end
