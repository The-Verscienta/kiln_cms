defmodule KilnCMS.CMS.UnknownFieldTypeTest do
  @moduledoc """
  A custom field whose `field_type` this release does not know (#2605): a
  newer release's type read after a rollback (`key_value` and `telephone`
  on v1.8.0), or a type whose plugin was removed.

  A write cannot produce one (`Validations.KnownFieldType`), so every such
  row is inserted with raw SQL (`KilnCMS.NewerReleaseRows`), the way the
  newer release stored it. Reading one used to fail every definitions read
  that met it, which took down the editor, every write to the type and
  delivery. Now the row is left out of every ordinary read, its values are
  kept by every write, a private one stays private, and an admin can delete
  it.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.NewerReleaseRows
  alias KilnCMS.Types.UnknownAtom

  @accept "application/vnd.api+json"
  @password "password123456"

  # An atom that exists in this VM but names no registered field type: a
  # removed plugin's type, read by a node that still holds the atom.
  @removed :zz_removed_plugin_type_2605

  @held %{"rows" => [%{"key" => "Torque", "value" => "40 Nm"}]}

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "unknown-type-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => user.email, "password" => @password},
        []
      )

    signed_in.__metadata__.token
  end

  defp api_get(path, token) do
    conn = put_req_header(build_conn(), "accept", @accept)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    conn = get(conn, path)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp field!(admin, type, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{type_definition_id: type.id, label: "Field", field_type: :string}, attrs),
      actor: admin
    )
  end

  # A row of a type this release does not know, on `type`.
  defp held_field!(type, attrs \\ %{}) do
    NewerReleaseRows.field_definition!(
      Map.merge(%{content_type: nil, type_definition_id: type.id, name: "specs"}, attrs)
    )
  end

  defp entry!(admin, type, custom_fields) do
    CMS.create_entry!(
      %{
        title: "Gear #{uniq()}",
        slug: "gear-#{uniq()}",
        type_definition_id: type.id,
        custom_fields: custom_fields
      },
      actor: admin
    )
  end

  # The value a newer release stored under a field this one does not know.
  defp store!(record, table, values) do
    KilnCMS.Repo.query!(
      "UPDATE #{table} SET custom_fields = custom_fields || $1 WHERE id = $2",
      [values, Ecto.UUID.dump!(record.id)]
    )
  end

  defp stored(table, id) do
    %{rows: [[fields]]} =
      KilnCMS.Repo.query!("SELECT custom_fields FROM #{table} WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    fields
  end

  defp all_types, do: [context: FieldDefinition.all_types_context()]

  setup do
    admin = user(:admin)

    type =
      CMS.create_type_definition!(%{name: "gear#{uniq()}", label: "Gear"}, actor: admin)

    motto = field!(admin, type, %{name: "motto", label: "Motto"})
    held = held_field!(type)

    entry = entry!(admin, type, %{"motto" => "first"})
    store!(entry, "entries", %{"specs" => @held})

    %{
      admin: admin,
      type: type,
      motto: motto,
      held: held,
      entry: CMS.get_entry!(entry.id, actor: admin)
    }
  end

  describe "reading the definitions" do
    test "every ordinary read leaves the row out", ctx do
      ids = fn defs -> Enum.map(defs, & &1.id) end

      assert ids.(CMS.list_field_definitions!(actor: ctx.admin)) |> Enum.member?(ctx.motto.id)
      refute ids.(CMS.list_field_definitions!(actor: ctx.admin)) |> Enum.member?(ctx.held)

      assert ids.(CMS.field_definitions_for_definition!(ctx.type.id, actor: ctx.admin)) == [
               ctx.motto.id
             ]

      assert {:error, _not_found} = CMS.get_field_definition(ctx.held, actor: ctx.admin)
    end

    test "the all-types context loads it, as an unknown type and with no new atom", ctx do
      definition = CMS.get_field_definition!(ctx.held, [actor: ctx.admin] ++ all_types())

      assert definition.field_type == %UnknownAtom{value: NewerReleaseRows.unknown_field_type()}
      assert FieldDefinition.unknown_type?(definition)
      refute FieldDefinition.orphaned?(definition)

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(NewerReleaseRows.unknown_field_type())
      end
    end

    test "an existing atom that is not a registered type is unknown too", ctx do
      id = held_field!(ctx.type, %{name: "removed", field_type: Atom.to_string(@removed)})

      assert {:error, _not_found} = CMS.get_field_definition(id, actor: ctx.admin)

      definition = CMS.get_field_definition!(id, [actor: ctx.admin] ++ all_types())
      assert definition.field_type == @removed
      assert FieldDefinition.unknown_type?(definition)
    end

    test "a group's sub-fields and a reference's link fields stay filtered when loaded", ctx do
      group = field!(ctx.admin, ctx.type, %{name: "dosages", field_type: :group})

      unit =
        field!(ctx.admin, ctx.type, %{
          name: "unit",
          type_definition_id: nil,
          group_of_id: group.id
        })

      held_field!(ctx.type, %{
        name: "rated",
        type_definition_id: nil,
        group_of_id: group.id
      })

      [listed] =
        ctx.type.id
        |> CMS.field_definitions_for_definition!([actor: ctx.admin] ++ all_types())
        |> Enum.filter(&(&1.id == group.id))

      assert Enum.map(listed.group_fields, & &1.id) == [unit.id]
    end
  end

  describe "writing a definition" do
    test "a create or a type change naming an unregistered type is refused", ctx do
      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_field_definition(
                 %{
                   type_definition_id: ctx.type.id,
                   name: "nope",
                   label: "N",
                   field_type: @removed
                 },
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "is not a registered field type"

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_field_definition(ctx.motto, %{field_type: @removed}, actor: ctx.admin)

      assert Exception.message(error) =~ "is not a registered field type"
    end

    test "an update that leaves the unknown type alone is refused, with what to do", ctx do
      definition = CMS.get_field_definition!(ctx.held, [actor: ctx.admin] ++ all_types())

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_field_definition(definition, %{label: "Renamed"}, actor: ctx.admin)

      assert Exception.message(error) =~ "can't be changed"
      assert Exception.message(error) =~ "delete it"

      # Nor retyped in place: the stored values are in the old type's shape.
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_field_definition(definition, %{field_type: :string}, actor: ctx.admin)
    end

    test "an admin deletes it, and the values go with it", ctx do
      definition = CMS.get_field_definition!(ctx.held, [actor: ctx.admin] ++ all_types())

      assert :ok = CMS.destroy_field_definition(definition, actor: ctx.admin)

      assert {:error, _} = CMS.get_field_definition(ctx.held, [actor: ctx.admin] ++ all_types())
      refute Map.has_key?(stored("entries", ctx.entry.id), "specs")
      assert stored("entries", ctx.entry.id)["motto"] == "first"
    end

    test "an editor may not delete it", ctx do
      editor = user(:editor)
      definition = CMS.get_field_definition!(ctx.held, [actor: editor] ++ all_types())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_field_definition(definition, actor: editor)

      assert stored("entries", ctx.entry.id)["specs"] == @held
    end

    test "a condition another field reads it by still blocks the delete", ctx do
      rule = %{"field" => "specs", "op" => "not_empty"}

      KilnCMS.Repo.query!(
        "UPDATE field_definitions SET visible_when = $1 WHERE id = $2",
        [rule, Ecto.UUID.dump!(ctx.motto.id)]
      )

      definition = CMS.get_field_definition!(ctx.held, [actor: ctx.admin] ++ all_types())

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.destroy_field_definition(definition, actor: ctx.admin)

      assert stored("entries", ctx.entry.id)["specs"] == @held
    end
  end

  describe "conditions that name a held field" do
    defp set_rule!(id, rule) do
      KilnCMS.Repo.query!(
        "UPDATE field_definitions SET visible_when = $1 WHERE id = $2",
        [rule, Ecto.UUID.dump!(id)]
      )
    end

    test "a field whose condition reads it can still be edited and reordered", ctx do
      set_rule!(ctx.motto.id, %{"field" => "specs", "op" => "not_empty"})
      motto = CMS.get_field_definition!(ctx.motto.id, actor: ctx.admin)

      assert {:ok, motto} =
               CMS.update_field_definition(motto, %{label: "Slogan"}, actor: ctx.admin)

      assert {:ok, motto} = CMS.update_field_definition(motto, %{position: 3}, actor: ctx.admin)
      assert motto.visible_when == %{"field" => "specs", "op" => "not_empty"}
    end

    test "renaming a field a held field's condition reads rewrites that condition", ctx do
      set_rule!(ctx.held, %{"field" => "motto", "op" => "not_empty"})

      assert {:ok, _} =
               CMS.update_field_definition(ctx.motto, %{name: "slogan"}, actor: ctx.admin)

      held = CMS.get_field_definition!(ctx.held, [actor: ctx.admin] ++ all_types())
      assert held.visible_when == %{"field" => "slogan", "op" => "not_empty"}
    end
  end

  describe "an import" do
    test "drops a value under a held name: it is the source site's, not this field's", ctx do
      NewerReleaseRows.field_definition!(%{content_type: "post", name: "post_specs"})

      CMS.create_field_definition!(
        %{content_type: :post, name: "post_motto", label: "Motto", field_type: :string},
        actor: ctx.admin
      )

      envelope = %{
        "records" => [
          %{
            "type" => "post",
            "title" => "Imported",
            "slug" => "imported-#{uniq()}",
            "custom_fields" => %{"post_motto" => "M", "post_specs" => "from elsewhere"}
          }
        ]
      }

      {:ok, report} =
        KilnCMS.Portability.Import.run_envelope(envelope,
          actor: ctx.admin,
          tenant: ctx.entry.org_id,
          skip_media: true
        )

      assert report.failed == []
      [created] = report.created
      assert stored("posts", created.id) == %{"post_motto" => "M"}
    end
  end

  describe "a record's held value" do
    test "a payload of the known fields keeps it", ctx do
      CMS.update_entry!(ctx.entry, %{custom_fields: %{"motto" => "second"}}, actor: ctx.admin)

      assert stored("entries", ctx.entry.id) == %{"motto" => "second", "specs" => @held}
    end

    test "a title-only update on a type with a computed field keeps it", ctx do
      field!(ctx.admin, ctx.type, %{
        name: "shout",
        field_type: :computed,
        compute: "{{ slugify(title) }}"
      })

      CMS.update_entry!(ctx.entry, %{title: "Renamed"}, actor: ctx.admin)

      fields = stored("entries", ctx.entry.id)
      assert fields["shout"] == "renamed"
      assert fields["specs"] == @held
    end

    test "re-sending the stored value is accepted; a different one is refused", ctx do
      assert {:ok, _} =
               CMS.update_entry(
                 ctx.entry,
                 %{custom_fields: %{"motto" => "again", "specs" => @held}},
                 actor: ctx.admin
               )

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_entry(
                 CMS.get_entry!(ctx.entry.id, actor: ctx.admin),
                 %{custom_fields: %{"specs" => %{"rows" => []}}},
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "can't be changed"
      assert stored("entries", ctx.entry.id)["specs"] == @held
    end

    test "a restore keeps it, and does not report it as dropped", ctx do
      # A version that holds the value: written after the newer release stored it.
      entry = CMS.update_entry!(ctx.entry, %{title: "With specs"}, actor: ctx.admin)

      version =
        CMS.list_entry_versions!(authorize?: false)
        |> Enum.filter(&(&1.version_source_id == entry.id))
        |> Enum.max_by(& &1.version_inserted_at, DateTime)

      entry = CMS.update_entry!(entry, %{custom_fields: %{"motto" => "later"}}, actor: ctx.admin)

      plan = KilnCMS.CMS.Changes.RestoreVersion.preview(entry, version.id, actor: ctx.admin)
      assert plan.dropped == []

      CMS.restore_entry_version!(entry, %{version_id: version.id}, actor: ctx.admin)

      assert stored("entries", entry.id) == %{"motto" => "first", "specs" => @held}
    end

    test "a working copy saved and published keeps it", ctx do
      live = CMS.publish_entry!(ctx.entry, actor: ctx.admin)

      {:ok, saved} =
        CMS.save_entry_working_copy(
          live,
          %{fields: %{"custom_fields" => %{"motto" => "held"}}},
          actor: ctx.admin,
          tenant: live.org_id
        )

      assert {:ok, _published} = CMS.publish_entry_changes(saved, actor: ctx.admin)

      assert stored("entries", live.id) == %{"motto" => "held", "specs" => @held}
    end

    test "a duplicate carries it", ctx do
      {copy, _withheld} =
        KilnCMS.CMS.Duplication.duplicate_with_notes!(ctx.type.name, ctx.entry,
          actor: ctx.admin,
          tenant: ctx.entry.org_id
        )

      assert stored("entries", copy.id) == %{"motto" => "first", "specs" => @held}
    end

    test "a duplicate leaves a held unique field blank", ctx do
      held_field!(ctx.type, %{name: "serial", validation: %{"unique" => true}})
      store!(ctx.entry, "entries", %{"serial" => "SN-1"})

      {copy, _withheld} =
        KilnCMS.CMS.Duplication.duplicate_with_notes!(ctx.type.name, ctx.entry,
          actor: ctx.admin,
          tenant: ctx.entry.org_id
        )

      fields = stored("entries", copy.id)
      assert fields["specs"] == @held
      refute Map.has_key?(fields, "serial")
    end

    test "a compiled type's record keeps it too", ctx do
      NewerReleaseRows.field_definition!(%{content_type: "page", name: "page_specs"})

      page =
        CMS.create_page!(%{title: "Held", slug: "held-#{uniq()}"}, actor: ctx.admin)

      store!(page, "pages", %{"page_specs" => @held})

      CMS.update_page!(CMS.get_page!(page.id, actor: ctx.admin), %{title: "Again"},
        actor: ctx.admin
      )

      CMS.update_page!(CMS.get_page!(page.id, actor: ctx.admin), %{custom_fields: %{}},
        actor: ctx.admin
      )

      assert stored("pages", page.id)["page_specs"] == @held
    end
  end

  describe "delivery" do
    test "a fired document leaves it out, recomputed or point-in-time", ctx do
      private = held_field!(ctx.type, %{name: "secret_specs", private: true})
      assert is_binary(private)
      store!(ctx.entry, "entries", %{"secret_specs" => "hidden"})
      entry = CMS.get_entry!(ctx.entry.id, actor: ctx.admin)

      %{values: fresh} = KilnCMS.Firing.CustomFields.resolve(entry)
      assert fresh == %{"motto" => "first"}

      # Point-in-time keeps the stored map as the history holds it, but what a
      # reader may see is today's question: the private one goes.
      %{values: then} = KilnCMS.Firing.CustomFields.resolve(entry, nil, recompute?: false)
      refute Map.has_key?(then, "secret_specs")
      assert then["motto"] == "first"
    end

    test "the schema export and a field sync export do not describe it", ctx do
      CMS.create_field_definition!(
        %{content_type: :page, name: "page_motto", label: "Motto", field_type: :string},
        actor: ctx.admin
      )

      NewerReleaseRows.field_definition!(%{content_type: "page", name: "page_specs"})

      page = KilnCMS.SchemaExport.json_schema(org_id: ctx.entry.org_id)["$defs"]["content_page"]
      refute inspect(page) =~ "page_specs"
      assert inspect(page) =~ "page_motto"

      {:ok, doc} = KilnCMS.CMS.FieldSync.export(actor: ctx.admin)
      # Untruncated: a project overlay's own definitions push the page's past
      # inspect's default 50 items.
      doc = inspect(doc, limit: :infinity)
      refute doc =~ ~s("specs")
      assert doc =~ ~s("motto")
    end
  end

  describe "reads below editor" do
    setup ctx do
      held_field!(ctx.type, %{name: "secret_specs", private: true})
      store!(ctx.entry, "entries", %{"secret_specs" => "hidden"})
      CMS.publish_entry!(CMS.get_entry!(ctx.entry.id, actor: ctx.admin), actor: ctx.admin)
      :ok
    end

    defp entry_fields({200, %{"data" => [%{"attributes" => %{"custom_fields" => fields}}]}}),
      do: fields

    test "a private one stays masked; a public one is served like the reporting views", ctx do
      path =
        "/api/json/entries/published?filter[type_name]=#{ctx.type.name}&fields[entry]=custom_fields"

      for reader <- [nil, token(user(:viewer))] do
        fields = entry_fields(api_get(path, reader))
        refute Map.has_key?(fields, "secret_specs")
        assert fields["specs"] == @held
      end

      assert entry_fields(api_get(path, token(user(:editor))))["secret_specs"] == "hidden"
    end
  end
end
