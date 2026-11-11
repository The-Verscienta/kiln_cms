defmodule KilnCMS.CMS.FieldDisplayTest do
  @moduledoc """
  How a custom-field value reads in the version compare modal (#2294): typed
  rendering per field type, the fallback for a retired definition, and the
  batched, actor-scoped resolution of media and reference targets.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDisplay
  alias KilnCMS.CMS.VersionDiff

  @ctx FieldDisplay.empty_context()

  defp def_(type, attrs \\ %{}),
    do: Map.merge(%{name: "f", label: "F", field_type: type, group_fields: []}, attrs)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fd-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "fd-#{System.unique_integer([:positive])}"

  # A diff whose only row is a `custom_fields` entry carrying `value`.
  defp diff_with(name, value) do
    VersionDiff.between(
      %{"custom_fields" => %{}},
      %{"custom_fields" => %{name => value}},
      KilnCMS.CMS.Page
    )
  end

  describe "display/3 per type" do
    test "a select shows the option label, falling back to the stored value" do
      definition = def_(:select, %{option_labels: %{"a" => "Alpha"}, options: ["a", "b"]})

      assert FieldDisplay.display(definition, "a", @ctx) == "Alpha"
      assert FieldDisplay.display(definition, "b", @ctx) == "b"
    end

    test "a multiple select shows every label" do
      definition = def_(:select, %{option_labels: %{"a" => "Alpha"}, multiple: true})

      assert FieldDisplay.display(definition, ["a", "b"], @ctx) == "Alpha, b"
    end

    test "media and reference show the resolved label, else the raw id" do
      id = Ecto.UUID.generate()
      other = Ecto.UUID.generate()
      ctx = %{media: %{id => "hero.jpg"}, refs: %{id => "About us"}}

      assert FieldDisplay.display(def_(:media), %{"id" => id, "url" => "x"}, ctx) == "hero.jpg"
      assert FieldDisplay.display(def_(:media), %{"id" => other, "url" => "x"}, ctx) == other

      assert FieldDisplay.display(def_(:reference), %{"id" => id, "title" => "Stale"}, ctx) ==
               "About us"

      assert FieldDisplay.display(def_(:reference), [%{"id" => id}, %{"id" => other}], ctx) ==
               "About us, #{other}"
    end

    test "rich text loses its tags and is bounded" do
      definition = def_(:text, %{format: :rich})

      assert FieldDisplay.display(definition, "<p>Hello <strong>big</strong> world</p>", @ctx) ==
               "Hello big world"

      long = "<p>" <> String.duplicate("word ", 200) <> "</p>"
      assert String.length(FieldDisplay.display(definition, long, @ctx)) <= 201
    end

    test "a plain text field is shown as written" do
      assert FieldDisplay.display(def_(:text, %{format: :plain}), "<b>x</b>", @ctx) == "<b>x</b>"
    end

    test "a group shows labelled sub-fields, bounded to a few rows" do
      sub = [
        def_(:string, %{name: "amount", label: "Amount"}),
        def_(:select, %{name: "unit", label: "Unit", option_labels: %{"g" => "Grams"}})
      ]

      definition = def_(:group, %{group_fields: sub, multiple: true})

      rows = for n <- 1..5, do: %{"amount" => "#{n}", "unit" => "g"}
      text = FieldDisplay.display(definition, rows, @ctx)

      assert text =~ "Amount: 1; Unit: Grams"
      assert text =~ "+2"
      refute text =~ "Amount: 4"
    end

    test "an unknown type and a retired definition use the generic rendering" do
      assert FieldDisplay.display(def_(:rating), 4, @ctx) == "4"
      assert FieldDisplay.display(nil, %{"a" => 1}, @ctx) == ~s({"a":1})
      assert FieldDisplay.display(nil, true, @ctx) == "true"
    end
  end

  describe "context/4" do
    setup do
      %{admin: user(:admin), viewer: user(:viewer)}
    end

    test "resolves media and reference labels for a reader who can read them", %{admin: admin} do
      target = CMS.create_page!(%{title: "Target page", slug: slug()}, actor: admin)
      item = CMS.create_media_item!(%{filename: "hero.jpg"}, actor: admin)

      definitions = [def_(:media, %{name: "m"}), def_(:reference, %{name: "r"})]

      diff =
        VersionDiff.between(
          %{"custom_fields" => %{}},
          %{
            "custom_fields" => %{
              "m" => %{"id" => item.id, "url" => "u"},
              "r" => %{"id" => target.id, "type" => "page", "slug" => "s", "title" => "Old"}
            }
          },
          KilnCMS.CMS.Page
        )

      ctx = FieldDisplay.context(definitions, diff, admin, target.org_id)

      assert ctx.media[item.id] == "hero.jpg"
      assert ctx.refs[target.id] == "Target page"
    end

    test "an unreadable reference falls back to the raw id", %{admin: admin, viewer: viewer} do
      draft = CMS.create_page!(%{title: "Secret draft", slug: slug()}, actor: admin)
      definitions = [def_(:reference, %{name: "r"})]

      snapshot = %{"id" => draft.id, "type" => "page", "slug" => "s", "title" => "Secret draft"}
      diff = diff_with("r", snapshot)

      ctx = FieldDisplay.context(definitions, diff, viewer, draft.org_id)

      assert ctx.refs == %{}
      assert FieldDisplay.display(hd(definitions), snapshot, ctx) == draft.id
    end

    test "a trashed reference falls back to the raw id", %{admin: admin} do
      page = CMS.create_page!(%{title: "Going away", slug: slug()}, actor: admin)
      definitions = [def_(:reference, %{name: "r"})]
      snapshot = %{"id" => page.id, "type" => "page", "slug" => "s", "title" => "Going away"}
      diff = diff_with("r", snapshot)

      assert FieldDisplay.context(definitions, diff, admin, page.org_id).refs[page.id] ==
               "Going away"

      CMS.destroy_page!(page, actor: admin)

      ctx = FieldDisplay.context(definitions, diff, admin, page.org_id)
      assert FieldDisplay.display(hd(definitions), snapshot, ctx) == page.id
    end

    test "a diff with no media or references reads nothing", %{admin: admin} do
      diff = diff_with("n", "x")

      assert FieldDisplay.context([def_(:string, %{name: "n"})], diff, admin, nil) ==
               FieldDisplay.empty_context()
    end
  end
end
