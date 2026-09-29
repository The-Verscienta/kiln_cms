defmodule KilnCMS.FieldRegistrySystemActorTest do
  @moduledoc """
  The two readers of the field registry that ran as `authorize?: false`,
  `KilnCMS.Events` and `KilnCMS.SchemaExport`, now read `FieldDefinition` as a
  system actor (#1659), which the resource already admits for reads only. Both
  fail CLOSED: a refused read filters to `[]`, which reads as "this type has no
  fields" — every event a non-event, and an exported schema with its custom
  fields missing.

  Also here: `Search.record_query/3`, the one write on `Analytics.SearchQuery`,
  which is admitted for `record` only.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Analytics.SearchQuery
  alias KilnCMS.CMS
  alias KilnCMS.Events
  alias KilnCMS.SchemaExport
  alias KilnCMS.Search
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "frsa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # A dynamic type in `org` carrying one `datetime_range` field: event-shaped.
  defp event_type!(org, admin) do
    name = "frsa#{uniq()}"

    td =
      CMS.create_type_definition!(%{name: name, label: "Gig", path_segment: name},
        actor: admin,
        tenant: org
      )

    CMS.create_field_definition!(
      %{type_definition_id: td.id, name: "when", label: "When", field_type: "datetime_range"},
      actor: admin,
      tenant: org
    )

    {name, td}
  end

  defp compiled_field!(org, admin) do
    CMS.create_field_definition!(
      %{content_type: :page, name: "subtitle#{uniq()}", label: "Subtitle", field_type: :string},
      actor: admin,
      tenant: org
    )
  end

  setup do
    %{org: org("frsa"), admin: user(:admin)}
  end

  describe "KilnCMS.Events" do
    test "system/0 and with_actor/2" do
      assert %SystemActor{subsystem: :events} = Events.system()
      assert_raise RuntimeError, fn -> Events.with_actor(nil, fn -> raise "boom" end) end
      assert %SystemActor{subsystem: :events} = Events.system()
    end

    test "a dynamic type's schedule field is found as the system", %{org: org, admin: admin} do
      {_name, td} = event_type!(org, admin)

      assert %{name: "when"} = Events.schedule_field({:definition, td.id}, org.id)
    end

    test "a refused dynamic-type read raises instead of making a non-event", ctx do
      {_name, td} = event_type!(ctx.org, ctx.admin)

      assert_raise Ash.Error.Forbidden, fn ->
        Events.with_actor(nil, fn -> Events.event_type?({:definition, td.id}, ctx.org.id) end)
      end
    end

    test "a compiled type's fields are read as the system, and fail closed", ctx do
      field = compiled_field!(ctx.org, ctx.admin)

      # `find_field` looks for a schedule; a string field is not one, so the
      # answer is nil either way. What differs is that a refusal raises.
      assert nil == Events.schedule_field({:content_type, :page}, ctx.org.id)
      assert field.content_type == :page

      assert_raise Ash.Error.Forbidden, fn ->
        Events.with_actor(nil, fn -> Events.schedule_field({:content_type, :page}, ctx.org.id) end)
      end
    end
  end

  describe "KilnCMS.SchemaExport" do
    test "system/0 and with_actor/2" do
      assert %SystemActor{subsystem: :schema_export} = SchemaExport.system()
      assert_raise RuntimeError, fn -> SchemaExport.with_actor(nil, fn -> raise "boom" end) end
      assert %SystemActor{subsystem: :schema_export} = SchemaExport.system()
    end

    test "a dynamic type exports its fields, and a refused read raises", ctx do
      {name, _td} = event_type!(ctx.org, ctx.admin)

      schema =
        SchemaExport.json_schema(org_id: ctx.org.id, types: [name])["$defs"][
          SchemaExport.content_def_name(name)
        ]

      assert Map.has_key?(schema["properties"]["custom_fields"]["properties"], "when")

      assert_raise Ash.Error.Forbidden, fn ->
        SchemaExport.with_actor(nil, fn ->
          SchemaExport.json_schema(org_id: ctx.org.id, types: [name])
        end)
      end
    end

    test "a compiled type exports its fields, and a refused read raises", ctx do
      field = compiled_field!(ctx.org, ctx.admin)

      properties =
        SchemaExport.json_schema(org_id: ctx.org.id, types: ["page"])["$defs"]["content_page"][
          "properties"
        ]["custom_fields"]["properties"]

      assert Map.has_key?(properties, field.name)

      assert_raise Ash.Error.Forbidden, fn ->
        SchemaExport.with_actor(nil, fn ->
          SchemaExport.json_schema(org_id: ctx.org.id, types: ["page"])
        end)
      end
    end
  end

  describe "Search.record_query/3 and SearchQuery" do
    defp recorded(org, term) do
      SearchQuery
      |> Ash.Query.filter(query == ^term)
      |> Ash.read!(authorize?: false, tenant: org)
    end

    test "the search records a query as the system", %{org: org} do
      term = "frsa-term-#{uniq()}"
      assert :ok = Search.record_query(term, 3, tenant: org.id)
      assert [%{count: 1, result_count: 3}] = recorded(org, term)
    end

    test "no person but an admin may record one, and the system may not purge", %{org: org} do
      for actor <- [nil, user(:editor), user(:viewer)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 KilnCMS.Analytics.record_search(
                   %{query: "x#{uniq()}", locale: "en", result_count: 0},
                   actor: actor,
                   tenant: org
                 )
      end

      term = "frsa-purge-#{uniq()}"
      :ok = Search.record_query(term, 1, tenant: org.id)
      [row] = recorded(org, term)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(row,
                 action: :purge_expired,
                 actor: SystemActor.new(:search),
                 tenant: org
               )
    end
  end
end
