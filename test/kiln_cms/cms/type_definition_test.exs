defmodule KilnCMS.CMS.TypeDefinitionTest do
  @moduledoc """
  Admin-defined (dynamic) content types (decision D17): the `TypeDefinition`
  meta-model resource, its collision guards against compiled types and
  reserved routes, the two-scope `FieldDefinition` extension, and the
  dynamic side of the `ContentTypes` registry.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "td-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp editor do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "td-editor-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp unique_name, do: "dyn#{System.unique_integer([:positive])}"

  defp define!(attrs \\ %{}, actor) do
    CMS.create_type_definition!(
      Map.merge(%{name: unique_name(), label: "Dynamic type"}, attrs),
      actor: actor
    )
  end

  describe "creating a type definition" do
    test "defaults the path segment to the naive plural of the name" do
      definition = define!(%{name: "recipe#{System.unique_integer([:positive])}"}, admin())
      assert definition.path_segment == definition.name <> "s"
    end

    test "keeps an explicit path segment" do
      definition = define!(%{path_segment: "cook-book"}, admin())
      assert definition.path_segment == "cook-book"
    end

    test "rejects an invalid machine name" do
      assert {:error, _} =
               CMS.create_type_definition(%{name: "Not Valid", label: "X"}, actor: admin())
    end

    test "rejects an invalid path segment" do
      assert {:error, _} =
               CMS.create_type_definition(
                 %{name: unique_name(), label: "X", path_segment: "Bad Segment"},
                 actor: admin()
               )
    end

    test "cannot take a compiled content type's name or plural" do
      assert {:error, _} = CMS.create_type_definition(%{name: "page", label: "X"}, actor: admin())

      assert {:error, _} =
               CMS.create_type_definition(%{name: "posts", label: "X"}, actor: admin())
    end

    test "cannot take a compiled type's path segment or a reserved route" do
      assert {:error, _} =
               CMS.create_type_definition(
                 %{name: unique_name(), label: "X", path_segment: "blog"},
                 actor: admin()
               )

      assert {:error, _} =
               CMS.create_type_definition(
                 %{name: unique_name(), label: "X", path_segment: "editor"},
                 actor: admin()
               )
    end

    test "name and path segment are unique across dynamic types" do
      definition = define!(admin())

      assert {:error, _} =
               CMS.create_type_definition(%{name: definition.name, label: "Dup"}, actor: admin())

      assert {:error, _} =
               CMS.create_type_definition(
                 %{name: unique_name(), label: "Dup", path_segment: definition.path_segment},
                 actor: admin()
               )
    end
  end

  describe "updating" do
    test "presentational attributes update; the machine name is create-only" do
      definition = define!(admin())

      updated =
        CMS.update_type_definition!(definition, %{label: "Renamed"}, actor: admin())

      assert updated.label == "Renamed"

      assert {:error, _} =
               CMS.update_type_definition(definition, %{name: "other_name"}, actor: admin())
    end
  end

  describe "archive and restore" do
    test "destroy archives (soft) and restore brings the type back" do
      admin = admin()
      definition = define!(admin)

      assert :ok = CMS.destroy_type_definition(definition, actor: admin)

      active_ids = Enum.map(CMS.list_type_definitions!(actor: admin), & &1.id)
      refute definition.id in active_ids

      archived =
        Enum.find(CMS.list_archived_type_definitions!(actor: admin), &(&1.id == definition.id))

      assert archived

      restored = CMS.restore_type_definition!(archived, actor: admin)
      assert is_nil(restored.archived_at)

      assert definition.id in Enum.map(CMS.list_type_definitions!(actor: admin), & &1.id)
    end

    test "an archived type's name still blocks re-creation (restore-safe)" do
      admin = admin()
      definition = define!(admin)
      :ok = CMS.destroy_type_definition(definition, actor: admin)

      assert {:error, _} =
               CMS.create_type_definition(%{name: definition.name, label: "Again"},
                 actor: admin()
               )
    end
  end

  describe "policies" do
    test "editors read but cannot define types" do
      admin = admin()
      editor = editor()
      definition = define!(admin)

      assert {:error, _} =
               CMS.create_type_definition(%{name: unique_name(), label: "X"}, actor: editor)

      assert definition.id in Enum.map(CMS.list_type_definitions!(actor: editor), & &1.id)
    end
  end

  describe "field definitions scoped to a dynamic type" do
    test "fields attach by type_definition_id and list via for_definition in order" do
      admin = admin()
      definition = define!(admin)

      CMS.create_field_definition!(
        %{type_definition_id: definition.id, name: "servings", label: "Servings", position: 2},
        actor: admin
      )

      CMS.create_field_definition!(
        %{type_definition_id: definition.id, name: "cook_time", label: "Cook time", position: 1},
        actor: admin
      )

      names =
        definition.id
        |> CMS.field_definitions_for_definition!(authorize?: false)
        |> Enum.map(& &1.name)

      assert names == ["cook_time", "servings"]
    end

    test "a field belongs to exactly one scope" do
      admin = admin()
      definition = define!(admin)

      assert {:error, _} =
               CMS.create_field_definition(%{name: "orphan", label: "X"}, actor: admin)

      assert {:error, _} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   type_definition_id: definition.id,
                   name: "both",
                   label: "X"
                 },
                 actor: admin
               )
    end

    test "field names are unique per dynamic type but reusable across types" do
      admin = admin()
      first = define!(admin)
      second = define!(admin)

      CMS.create_field_definition!(
        %{type_definition_id: first.id, name: "shared", label: "X"},
        actor: admin
      )

      assert CMS.create_field_definition!(
               %{type_definition_id: second.id, name: "shared", label: "X"},
               actor: admin
             )

      assert {:error, _} =
               CMS.create_field_definition(
                 %{type_definition_id: first.id, name: "shared", label: "Dup"},
                 actor: admin
               )
    end
  end

  describe "the dynamic registry" do
    test "dynamic_all/0 describes dynamic types as string-typed descriptors" do
      admin = admin()
      definition = define!(%{label: "Recipe", plural_label: "Recipes"}, admin)

      descriptor = Enum.find(ContentTypes.dynamic_all(), &(&1.type == definition.name))

      assert %{
               source: :dynamic,
               resource: nil,
               label: "Recipe",
               plural: "Recipes"
             } = descriptor

      assert descriptor.path_segment == definition.path_segment
      assert ContentTypes.get_dynamic(definition.name).definition.id == definition.id
    end

    test "compiled discovery is unaffected" do
      define!(admin())

      assert Enum.all?(ContentTypes.all(), &(&1.source == :compiled))
      assert Enum.any?(ContentTypes.all(), &(&1.type == :page))
    end
  end
end
