defmodule KilnCMSWeb.StructuredDataDynamicTypeTest do
  @moduledoc """
  #769: the served page's JSON-LD must agree with the fired `:json_ld`
  artifact's `@type` for a dynamic type's declared `schema_org_type` — both
  producers read `KilnCMS.Firing.SchemaOrg.resolve/1`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.SchemaOrg
  alias KilnCMSWeb.StructuredData

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "structured-data-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{admin: admin, org: KilnCMS.Accounts.default_org_id()}
  end

  defp type_name, do: "remedy#{System.unique_integer([:positive])}"

  test "a dynamic type's declared schema.org type reaches the served page's @type", ctx do
    definition =
      CMS.create_type_definition!(
        %{name: type_name(), label: "Remedy", schema_org_type: "MedicalWebPage"},
        actor: ctx.admin
      )

    entry =
      CMS.ContentTypes.create!(definition.name, %{title: "Ginger", slug: "ginger-1"},
        actor: ctx.admin
      )

    ct = ContentTypes.get(definition.name, ctx.org)
    data = StructuredData.build(entry, ct)

    assert data["@type"] == "MedicalWebPage"
    # Not an article-family type, so title carries as `name`, not `headline`.
    assert data["name"] == "Ginger"
    refute Map.has_key?(data, "headline")
  end

  test "an unknown/stale schema_org_type falls back to the default rather than firing unvetted markup",
       ctx do
    definition =
      CMS.create_type_definition!(%{name: type_name(), label: "Odd"}, actor: ctx.admin)

    entry =
      CMS.ContentTypes.create!(definition.name, %{title: "Thing", slug: "thing-1"},
        actor: ctx.admin
      )

    ct = ContentTypes.get(definition.name, ctx.org)
    data = StructuredData.build(entry, ct)

    assert data["@type"] == SchemaOrg.default_type()
  end

  describe "Event family" do
    setup ctx do
      td =
        CMS.create_type_definition!(
          %{name: type_name(), label: "Gig", schema_org_type: "MusicEvent"},
          actor: ctx.admin
        )

      CMS.create_field_definition!(
        %{type_definition_id: td.id, name: "when", label: "When", field_type: "datetime_range"},
        actor: ctx.admin
      )

      %{td: td}
    end

    test "the served page carries the Event's dates and omits CreativeWork-only fields", ctx do
      entry =
        CMS.create_entry!(
          %{
            title: "A gig",
            slug: "a-gig-1",
            type_definition_id: ctx.td.id,
            custom_fields: %{
              "when" => %{"start" => "2026-03-15T19:00", "end" => "2026-03-15T21:00"}
            }
          },
          actor: ctx.admin
        )

      ct = ContentTypes.get(ctx.td.name, ctx.org)
      data = StructuredData.build(entry, ct)

      assert data["@type"] == "MusicEvent"
      assert data["name"] == "A gig"
      assert data["startDate"] == "2026-03-15T19:00:00Z"
      assert data["endDate"] == "2026-03-15T21:00:00Z"

      # CreativeWork properties — invalid on an Event, mirrors the fired producer.
      refute Map.has_key?(data, "keywords")
      refute Map.has_key?(data, "datePublished")
      refute Map.has_key?(data, "dateModified")
    end

    test "a gated Event's teaser carries the same @type and dates as the full render", ctx do
      entry =
        CMS.create_entry!(
          %{
            title: "A gig",
            slug: "a-gig-2",
            type_definition_id: ctx.td.id,
            audience: :member,
            custom_fields: %{
              "when" => %{"start" => "2026-03-15T19:00", "end" => "2026-03-15T21:00"}
            }
          },
          actor: ctx.admin
        )

      teaser = KilnCMSWeb.Teaser.from_record(entry, "http://x/gigs/a-gig-2")
      [node] = StructuredData.teaser(teaser)

      assert node["@type"] == "MusicEvent"
      assert node["name"] == "A gig"
      assert node["startDate"] == "2026-03-15T19:00:00Z"
      assert node["endDate"] == "2026-03-15T21:00:00Z"
      assert node["isAccessibleForFree"] == false
      refute Map.has_key?(node, "datePublished")
    end
  end

  describe "served vs fired agreement" do
    test "both producers resolve the same @type for the same document", ctx do
      definition =
        CMS.create_type_definition!(
          %{name: type_name(), label: "Remedy", schema_org_type: "MedicalWebPage"},
          actor: ctx.admin
        )

      entry =
        CMS.ContentTypes.create!(definition.name, %{title: "Ginger", slug: "ginger-2"},
          actor: ctx.admin
        )

      {:ok, entry} =
        CMS.ContentTypes.transition(definition.name, "publish", entry, actor: ctx.admin)

      KilnCMS.DataCase.drain_oban()

      {:ok, ld} = KilnCMS.Firing.Engine.read(ctx.org, :entry, entry.id, :json_ld)
      [fired_main | _] = ld["@graph"]

      ct = ContentTypes.get(definition.name, ctx.org)
      served = StructuredData.build(entry, ct)

      assert fired_main["@type"] == served["@type"]
      assert served["@type"] == "MedicalWebPage"
    end
  end
end
