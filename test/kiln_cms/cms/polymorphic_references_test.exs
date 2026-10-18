defmodule KilnCMS.CMS.PolymorphicReferencesTest do
  @moduledoc """
  Workstream R2 of `docs/relationships-plan.md`: a `:reference` custom field
  may allow several target types (`target_types`) instead of one
  (`target_type`). Each stored snapshot names its own `"type"`, a write must
  name it when more than one type is allowed, and every consumer of the value
  — the `ContentLink` edges, the D13 re-fire edges, `custom_filter`, the schema
  export — reads each item's own type rather than the field's.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLink
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.Firing
  alias KilnCMS.SchemaExport

  require Ash.Query

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pref-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "pref-#{System.unique_integer([:positive])}"
  defp field_name, do: "linked_#{System.unique_integer([:positive])}"

  defp page!(admin, title), do: CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
  defp post!(admin, title), do: CMS.create_post!(%{title: title, slug: slug()}, actor: admin)

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :post, label: "Linked", field_type: :reference},
        attrs
      ),
      actor: admin
    )
  end

  defp referrer!(admin, fields),
    do: CMS.create_post!(%{title: "Referrer", slug: slug(), custom_fields: fields}, actor: admin)

  defp ref(record, type), do: %{"id" => record.id, "type" => type}

  defp snapshot(record, type),
    do: %{"id" => record.id, "type" => type, "slug" => record.slug, "title" => record.title}

  defp error_message!(fun) do
    error = assert_raise(Ash.Error.Invalid, fun)
    Exception.message(error)
  end

  # Every reference edge leaving `source`, in field order, bypassing policy.
  defp edges(source) do
    ContentLink
    |> Ash.Query.filter(source_id == ^source.id and kind == :reference)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.target_type, &1.target_id, &1.position})
  end

  setup do
    %{admin: admin(), name: field_name()}
  end

  describe "the definition" do
    test "target_types names several types, target_type one", %{admin: admin, name: name} do
      field = field!(admin, %{name: name, target_types: ["page", "post"]})

      assert field.target_type == nil
      assert FieldDefinition.reference_targets(field) == ["page", "post"]

      single = field!(admin, %{name: field_name(), target_type: "page"})
      assert single.target_types == []
      assert FieldDefinition.reference_targets(single) == ["page"]
    end

    test "a dynamic type can be one of the targets", %{admin: admin, name: name} do
      dynamic =
        CMS.create_type_definition!(
          %{name: "pt#{System.unique_integer([:positive])}", label: "Product"},
          actor: admin
        )

      field = field!(admin, %{name: name, target_types: ["page", dynamic.name]})
      assert field.target_types == ["page", dynamic.name]
    end

    test "exactly one of the two is set", %{admin: admin, name: name} do
      both = %{name: name, target_type: "page", target_types: ["page", "post"]}

      assert {:error, error} =
               CMS.create_field_definition(
                 Map.merge(%{content_type: :post, label: "L", field_type: :reference}, both),
                 actor: admin
               )

      assert Exception.message(error) =~ "not both"

      assert {:error, error} =
               CMS.create_field_definition(
                 %{content_type: :post, name: name, label: "L", field_type: :reference},
                 actor: admin
               )

      assert Exception.message(error) =~ "pick the type of content this field links to"
    end

    test "every listed type must exist, once", %{admin: admin, name: name} do
      attrs = %{content_type: :post, name: name, label: "L", field_type: :reference}

      assert {:error, error} =
               CMS.create_field_definition(
                 Map.put(attrs, :target_types, ["page", "no_such_type"]),
                 actor: admin
               )

      assert Exception.message(error) =~
               "includes no_such_type, which is not a known content type"

      assert {:error, error} =
               CMS.create_field_definition(
                 Map.put(attrs, :target_types, ["page", "post", "page"]),
                 actor: admin
               )

      assert Exception.message(error) =~ "lists page twice"

      assert {:error, error} =
               CMS.create_field_definition(Map.put(attrs, :target_types, ["page", ""]),
                 actor: admin
               )

      assert Exception.message(error) =~ "no nil values"
    end

    test "other field types ignore target_types", %{admin: admin, name: name} do
      field =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: name,
            label: "L",
            field_type: :string,
            target_types: ["no_such_type"]
          },
          actor: admin
        )

      assert field.field_type == :string
    end
  end

  describe "a single polymorphic reference" do
    setup %{admin: admin, name: name} do
      field!(admin, %{name: name, target_types: ["page", "post"]})
      :ok
    end

    test "stores a snapshot of whichever type the input names", %{admin: admin, name: name} do
      page = page!(admin, "A page")
      other = post!(admin, "A post")

      assert referrer!(admin, %{name => ref(page, "page")}).custom_fields[name] ==
               snapshot(page, "page")

      assert referrer!(admin, %{name => ref(other, "post")}).custom_fields[name] ==
               snapshot(other, "post")

      # The stored snapshot round-trips as input.
      stored = referrer!(admin, %{name => ref(page, "page")})
      {:ok, again} = CMS.update_post(stored, %{custom_fields: stored.custom_fields}, actor: admin)
      assert again.custom_fields[name] == snapshot(page, "page")
    end

    test "a bare id is refused: the type must be named", %{admin: admin, name: name} do
      page = page!(admin, "A page")

      assert error_message!(fn -> referrer!(admin, %{name => page.id}) end) =~
               "must say which type of content it links to (one of: page, post)"
    end

    test "a type the field does not allow is refused", %{admin: admin, name: name} do
      dynamic =
        CMS.create_type_definition!(
          %{name: "pt#{System.unique_integer([:positive])}", label: "Product"},
          actor: admin
        )

      assert error_message!(fn ->
               referrer!(admin, %{name => %{"id" => Ash.UUID.generate(), "type" => dynamic.name}})
             end) =~ "can't link to #{dynamic.name} — this field links to page, post"
    end

    test "an id is looked up under the type it is named with", %{admin: admin, name: name} do
      page = page!(admin, "A page")

      # A page's id called a post resolves to nothing.
      assert error_message!(fn -> referrer!(admin, %{name => ref(page, "post")}) end) =~
               "must be an existing page or post record"
    end

    test "edges carry each value's own type", %{admin: admin, name: name} do
      page = page!(admin, "A page")
      other = post!(admin, "A post")

      referrer = referrer!(admin, %{name => ref(page, "page")})
      assert edges(referrer) == [{"page", page.id, 0}]

      {:ok, referrer} =
        CMS.update_post(referrer, %{custom_fields: %{name => ref(other, "post")}}, actor: admin)

      assert edges(referrer) == [{"post", other.id, 0}]
    end

    test "custom_filter still matches on the id", %{admin: admin, name: name} do
      page = page!(admin, "A page")
      other = post!(admin, "A post")
      to_page = referrer!(admin, %{name => ref(page, "page")})
      to_post = referrer!(admin, %{name => ref(other, "post")})

      list = fn filter ->
        %{custom_filter: %{name => filter}}
        |> CMS.list_posts!(actor: admin)
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

      assert list.(page.id) == [to_page.id]
      assert list.(%{"in" => [page.id, other.id]}) == Enum.sort([to_page.id, to_post.id])
    end
  end

  test "a field with one listed type accepts a bare id", %{admin: admin, name: name} do
    field!(admin, %{name: name, target_types: ["page"]})
    page = page!(admin, "A page")

    assert referrer!(admin, %{name => page.id}).custom_fields[name] == snapshot(page, "page")
  end

  test "a single-type field keeps ignoring the type an input names", %{admin: admin, name: name} do
    field!(admin, %{name: name, target_type: "page"})
    page = page!(admin, "A page")

    assert referrer!(admin, %{name => %{"id" => page.id, "type" => "whatever"}}).custom_fields[
             name
           ] == snapshot(page, "page")
  end

  describe "a list of polymorphic references" do
    setup %{admin: admin, name: name} do
      field!(admin, %{name: name, target_types: ["page", "post"], multiple: true})
      :ok
    end

    test "mixes types in order, each item keeping its own", %{admin: admin, name: name} do
      a = page!(admin, "Page A")
      b = post!(admin, "Post B")
      c = page!(admin, "Page C")

      referrer = referrer!(admin, %{name => ["", ref(b, "post"), ref(a, "page"), ref(c, "page")]})

      assert referrer.custom_fields[name] == [
               snapshot(b, "post"),
               snapshot(a, "page"),
               snapshot(c, "page")
             ]

      assert edges(referrer) == [{"post", b.id, 0}, {"page", a.id, 1}, {"page", c.id, 2}]

      for target <- [a, b, c] do
        assert [%{source: %{id: id}}] = CMS.ContentLinks.backlinks(target, actor: admin)
        assert id == referrer.id
      end
    end

    test "an item that names no type, or a refused one, is named", %{admin: admin, name: name} do
      a = page!(admin, "Page A")
      b = post!(admin, "Post B")

      assert error_message!(fn -> referrer!(admin, %{name => [ref(a, "page"), b.id]}) end) =~
               "item 2 (#{b.id}) doesn't say which type of content it is (one of: page, post)"

      stale = %{"id" => b.id, "type" => "event", "title" => "Old"}

      assert error_message!(fn -> referrer!(admin, %{name => [ref(a, "page"), stale]}) end) =~
               "item 2 “Old” is of type event, which this field can't link to — it links to page, post"
    end

    test "an id named under the wrong type does not resolve", %{admin: admin, name: name} do
      a = page!(admin, "Page A")

      assert error_message!(fn -> referrer!(admin, %{name => [ref(a, "post")]}) end) =~
               "item 1 (#{a.id}) no longer exists or can't be linked"
    end
  end

  describe "the re-fire graph" do
    test "each item is an edge to its own type, and renaming either re-fires", %{
      admin: admin,
      name: name
    } do
      definition =
        CMS.create_type_definition!(
          %{name: "rf#{System.unique_integer([:positive])}", label: "Referrer"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: definition.id,
          name: name,
          label: "Linked",
          field_type: :reference,
          target_types: ["page", "post"],
          multiple: true
        },
        actor: admin
      )

      page = CMS.publish_page!(page!(admin, "Page A"), actor: admin)
      other = CMS.publish_post!(post!(admin, "Post B"), actor: admin)

      referrer =
        definition.name
        |> CMS.ContentTypes.create!(
          %{
            title: "Referrer",
            slug: slug(),
            custom_fields: %{name => [ref(other, "post"), ref(page, "page")]}
          },
          actor: admin
        )
        |> CMS.publish_entry!(%{}, actor: admin)

      KilnCMS.DataCase.drain_oban()

      {:ok, fired_edges} = Firing.edges_from(:entry, referrer.id, authorize?: false)

      assert fired_edges |> Enum.map(&{&1.to_type, &1.to_id}) |> Enum.sort() ==
               Enum.sort([{:page, page.id}, {:post, other.id}])

      CMS.update_post!(other, %{title: "Post B, renamed"}, actor: admin)
      assert %{failure: 0} = KilnCMS.DataCase.drain_oban()

      {:ok, artifact} =
        Firing.get_artifact(:entry, referrer.id, :json,
          authorize?: false,
          tenant: KilnCMS.Accounts.default_org_id()
        )

      assert Enum.map(artifact.body["custom_fields"][name], &{&1["type"], &1["title"]}) == [
               {"post", "Post B, renamed"},
               {"page", "Page A"}
             ]
    end
  end

  describe "schema export" do
    test "reports the allowed types of every reference field", %{admin: admin, name: name} do
      field!(admin, %{name: name, target_types: ["page", "post"], multiple: true})
      single = field_name()
      field!(admin, %{name: single, target_type: "page"})

      properties =
        SchemaExport.json_schema()["$defs"]["content_post"]["properties"]["custom_fields"][
          "properties"
        ]

      assert properties[name]["x-kiln-target-types"] == ["page", "post"]
      assert properties[single]["x-kiln-target-types"] == ["page"]

      # An annotation, not an enum: a stored value may name a since-dropped type.
      refute Map.has_key?(properties[name]["items"]["properties"]["type"], "enum")

      ts = SchemaExport.TypeScript.emit(SchemaExport.json_schema())
      assert ts =~ ~s(#{name}?: /* links to: "page" | "post" */ Array<{ id: string;)
      assert ts =~ ~s(#{single}?: /* links to: "page" */ Record<string, unknown> | null)
    end
  end
end
