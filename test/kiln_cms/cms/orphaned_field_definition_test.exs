defmodule KilnCMS.CMS.OrphanedFieldDefinitionTest do
  @moduledoc """
  A `field_definitions` row whose stored `content_type` names a type this VM no
  longer has (#1770) — a removed plugin, a renamed or deleted compiled type, a
  row left over from early dynamic-type testing.

  A write cannot produce one (`Validations.KnownContentType`), so every row
  here is inserted with raw SQL, the way an upgraded database already holds it.
  The stored name is built at runtime so no atom of it exists: reading it used
  to raise `cannot load "…" as type Ash.Type.Atom` and take every reader of
  the registry down with it.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.OrphanedContentType

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "orphan-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # A type name with no atom behind it: interpolated, so the compiler never
  # sees it as a literal.
  defp gone_type, do: "gone_type_#{System.unique_integer([:positive])}"

  @doc false
  def insert_orphan!(content_type, attrs \\ []) do
    id = Ecto.UUID.generate()
    org_id = Keyword.get(attrs, :org_id, KilnCMS.Accounts.default_org_id())

    KilnCMS.Repo.query!(
      """
      INSERT INTO field_definitions
        (id, org_id, content_type, name, label, field_type, required, options,
         position, names_record, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, 'string', false, '{}', 0, $6, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(org_id),
        content_type,
        Keyword.get(attrs, :name, "orphan_#{System.unique_integer([:positive])}"),
        Keyword.get(attrs, :label, "Orphan"),
        Keyword.get(attrs, :names_record, false)
      ]
    )

    id
  end

  describe "reading an orphaned definition" do
    test "loads with the stored name kept, as an orphan marker — no new atom" do
      name = gone_type()
      id = insert_orphan!(name)

      definition = CMS.get_field_definition!(id, actor: user(:admin))

      assert definition.content_type == %OrphanedContentType{name: name}
      assert to_string(definition.content_type) == name
      assert FieldDefinition.orphaned?(definition)

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "the full listing no longer raises, and still lists every other field" do
      admin = user(:admin)
      insert_orphan!(gone_type())

      live =
        CMS.create_field_definition!(%{content_type: :page, name: "still_here", label: "S"},
          actor: admin
        )

      ids = [actor: admin] |> CMS.list_field_definitions!() |> Enum.map(& &1.id)
      assert live.id in ids
    end

    test "a name that is still an atom but no longer a registered type is orphaned too" do
      id = insert_orphan!(Atom.to_string(:kiln_retired_type_1770))

      definition = CMS.get_field_definition!(id, actor: user(:admin))

      assert definition.content_type == :kiln_retired_type_1770
      assert FieldDefinition.orphaned?(definition)
    end

    test "a registered or dynamic-scoped definition is not orphaned" do
      admin = user(:admin)

      page =
        CMS.create_field_definition!(%{content_type: :page, name: "ok_field", label: "Ok"},
          actor: admin
        )

      refute FieldDefinition.orphaned?(page)

      refute FieldDefinition.orphaned?(%{
               type_definition_id: Ecto.UUID.generate(),
               content_type: nil
             })
    end

    test "no content type resolves from an orphan — not even a dynamic type sharing the name" do
      admin = user(:admin)
      name = gone_type()
      CMS.create_type_definition!(%{name: name, label: "Clinic"}, actor: admin)
      id = insert_orphan!(name)

      definition = CMS.get_field_definition!(id, actor: admin)

      assert KilnCMS.CMS.ContentTypes.get(definition.content_type) == nil
      refute KilnCMS.CMS.ContentTypes.type?(definition.content_type)
    end
  end

  describe "readers skip an orphaned definition" do
    test "name fields (the search alias leg) ignore a flagged orphan" do
      insert_orphan!(gone_type(), names_record: true, name: "orphan_alias")

      flagged = KilnCMS.CMS.NameFields.all(KilnCMS.Accounts.default_org_id())

      refute flagged |> Map.values() |> List.flatten() |> Enum.member?("orphan_alias")
      assert Enum.all?(Map.keys(flagged), &is_atom/1)
    end

    test "content with custom fields still saves beside an orphan of the same name" do
      admin = user(:admin)
      insert_orphan!(gone_type(), name: "subtitle_1770")

      CMS.create_field_definition!(
        %{content_type: :page, name: "subtitle_1770", label: "Subtitle"},
        actor: admin
      )

      page =
        CMS.create_page!(
          %{
            title: "Orphan neighbour",
            slug: "orphan-#{System.unique_integer([:positive])}",
            custom_fields: %{"subtitle_1770" => "kept"}
          },
          actor: admin
        )

      assert page.custom_fields == %{"subtitle_1770" => "kept"}

      assert [page.id] ==
               %{custom_filter: %{"subtitle_1770" => "kept"}}
               |> CMS.list_pages!(actor: admin)
               |> Enum.map(& &1.id)
    end

    test "the schema export ignores it" do
      insert_orphan!(gone_type(), name: "orphan_export")

      document = KilnCMS.SchemaExport.json_schema(org_id: KilnCMS.Accounts.default_org_id())

      refute Jason.encode!(document) =~ "orphan_export"
    end

    test "it encodes as its stored name" do
      name = gone_type()
      id = insert_orphan!(name)
      definition = CMS.get_field_definition!(id, actor: user(:admin))

      assert Jason.encode!(definition.content_type) == Jason.encode!(name)
    end
  end

  describe "repairing it" do
    test "an admin deletes it" do
      admin = user(:admin)
      id = insert_orphan!(gone_type())
      definition = CMS.get_field_definition!(id, actor: admin)

      assert :ok = CMS.destroy_field_definition(definition, actor: admin)
      assert {:error, _} = CMS.get_field_definition(id, actor: admin)
    end

    test "deleting it leaves a same-named dynamic type's stored values alone" do
      admin = user(:admin)
      name = gone_type()
      type = CMS.create_type_definition!(%{name: name, label: "Clinic"}, actor: admin)

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "hours", label: "Hours"},
        actor: admin
      )

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          name,
          %{title: "Main St", slug: "main-st", custom_fields: %{"hours" => "9-5"}},
          actor: admin
        )

      id = insert_orphan!(name, name: "hours")
      definition = CMS.get_field_definition!(id, actor: admin)
      assert :ok = CMS.destroy_field_definition(definition, actor: admin)

      assert CMS.get_entry!(entry.id, actor: admin).custom_fields == %{"hours" => "9-5"}
    end

    test "an editor may not delete it" do
      id = insert_orphan!(gone_type())
      editor = user(:editor)
      definition = CMS.get_field_definition!(id, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_field_definition(definition, actor: editor)
    end

    test "it cannot be saved back while it points at nothing" do
      admin = user(:admin)
      id = insert_orphan!(gone_type())
      definition = CMS.get_field_definition!(id, actor: admin)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_field_definition(definition, %{label: "Renamed"}, actor: admin)

      assert Exception.message(error) =~ "not a known content type"
    end
  end
end
