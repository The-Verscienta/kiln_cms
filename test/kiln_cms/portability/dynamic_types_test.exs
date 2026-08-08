defmodule KilnCMS.Portability.DynamicTypesTest do
  @moduledoc """
  Export/import of **admin-defined** content types (#952).

  The compiled types (`Page`, `Post`) are covered by `export_test.exs` and
  `import_test.exs`. Dynamic types are a different shape in every way that
  matters here: they are rows rather than modules, they resolve per-org, and
  their whole payload lives in `custom_fields` rather than in attributes.

  That last point is why this file exists. For a `Post`, losing `custom_fields`
  costs you some extra fields. For a `Recipe` it costs you **the content** —
  every record round-trips with a title, a slug and nothing else, while every
  other assertion in the suite still passes.

  Not async: the `ContentTypes` registry spans the table, so a shared sandbox is
  required. Orgs are seeded via `Ash.Seed` to bypass the `multitenancy_enabled`
  create guard, matching `KilnCMS.MultitenancyDynamicTypesTest`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Portability.Export
  alias KilnCMS.Portability.Import

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "portdyn-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp type_name, do: "recipe#{System.unique_integer([:positive])}"

  defp field!(actor, org, definition, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{type_definition_id: definition.id, position: 0}, attrs),
      actor: actor,
      tenant: org
    )
  end

  setup do
    actor = user(:admin)
    org = org("portdyn")
    name = type_name()

    definition =
      CMS.create_type_definition!(%{name: name, label: "Recipe"}, actor: actor, tenant: org)

    # One of each shape the coercion path treats differently: a plain string, a
    # number, a boolean, a date, and a constrained select. A round trip that
    # only carried strings would look fine and still be losing every other type.
    field!(actor, org, definition, %{name: "servings", label: "Servings", field_type: :integer})
    field!(actor, org, definition, %{name: "vegan", label: "Vegan", field_type: :boolean})
    field!(actor, org, definition, %{name: "cooked_on", label: "Cooked on", field_type: :date})
    field!(actor, org, definition, %{name: "source", label: "Source", field_type: :string})

    field!(actor, org, definition, %{
      name: "difficulty",
      label: "Difficulty",
      field_type: :select,
      options: ["easy", "hard"]
    })

    %{actor: actor, org: org, name: name, definition: definition}
  end

  defp scope(%{actor: actor, org: org}), do: [actor: actor, tenant: org]

  defp create_recipe!(ctx, custom_fields, extra \\ %{}) do
    ContentTypes.create!(
      ctx.name,
      Map.merge(
        %{
          title: "Soup",
          slug: "soup-#{System.unique_integer([:positive])}",
          blocks: [],
          custom_fields: custom_fields
        },
        extra
      ),
      scope(ctx)
    )
  end

  defp reload(ctx, slug),
    do: ContentTypes.list!(ctx.name, scope(ctx)) |> Enum.find(&(&1.slug == slug))

  describe "export" do
    test "includes the dynamic type and its records", ctx do
      record = create_recipe!(ctx, %{"servings" => "4"})

      {:ok, envelope} = Export.run(:all, scope(ctx))

      assert ctx.name in envelope["kiln_export"]["types"]

      exported = Enum.find(envelope["records"], &(&1["slug"] == record.slug))
      assert exported["type"] == ctx.name
    end

    test "carries custom_fields, which for a dynamic type IS the content", ctx do
      record =
        create_recipe!(ctx, %{
          "servings" => "4",
          "vegan" => "true",
          "cooked_on" => "2024-03-01",
          "source" => "Grandma",
          "difficulty" => "easy"
        })

      {:ok, envelope} = Export.run([ctx.name], scope(ctx))
      exported = Enum.find(envelope["records"], &(&1["slug"] == record.slug))

      fields = exported["custom_fields"]
      refute is_nil(fields), "custom_fields must survive the export"

      assert fields["servings"] == 4
      assert fields["vegan"] == true
      assert to_string(fields["cooked_on"]) == "2024-03-01"
      assert fields["source"] == "Grandma"
      assert fields["difficulty"] == "easy"
    end

    test "a type in another org is not exported", ctx do
      other_org = org("portdyn-other")
      other_actor = user(:admin)

      other =
        CMS.create_type_definition!(%{name: type_name(), label: "Other"},
          actor: other_actor,
          tenant: other_org
        )

      {:ok, envelope} = Export.run(:all, scope(ctx))

      refute other.name in envelope["kiln_export"]["types"]
    end
  end

  describe "round trip" do
    test "every field type survives export then import", ctx do
      original =
        create_recipe!(ctx, %{
          "servings" => "6",
          "vegan" => "false",
          "cooked_on" => "2023-12-25",
          "source" => "A book",
          "difficulty" => "hard"
        })

      {:ok, envelope} = Export.run([ctx.name], scope(ctx))

      ContentTypes.purge(ctx.name, original, scope(ctx))

      {:ok, report} = Import.run_envelope(envelope, scope(ctx) ++ [skip_media: true])

      assert report.failed == []
      assert length(report.created) == 1

      imported = reload(ctx, original.slug)
      assert imported.title == "Soup"

      fields = imported.custom_fields
      assert fields["servings"] == 6
      assert fields["vegan"] == false
      assert to_string(fields["cooked_on"]) == "2023-12-25"
      assert fields["source"] == "A book"
      assert fields["difficulty"] == "hard"
    end

    test "a published dynamic record round-trips as published", ctx do
      original = create_recipe!(ctx, %{"servings" => "2"})
      {:ok, _} = ContentTypes.transition(ctx.name, "publish", original, scope(ctx))

      {:ok, envelope} = Export.run([ctx.name], scope(ctx))
      ContentTypes.purge(ctx.name, reload(ctx, original.slug), scope(ctx))

      {:ok, report} = Import.run_envelope(envelope, scope(ctx) ++ [skip_media: true])
      assert report.failed == []

      assert reload(ctx, original.slug).state == :published
    end
  end

  describe "required custom fields" do
    setup ctx do
      field!(ctx.actor, ctx.org, ctx.definition, %{
        name: "method",
        label: "Method",
        field_type: :string,
        required: true
      })

      ctx
    end

    # The importer's own docs say a dry run "is a plan, not a validation" and
    # can over-report. This pins that honestly rather than pretending otherwise:
    # the run reports the record as failed, and the failure names the field.
    test "an envelope omitting a required field fails the record, not the run", ctx do
      envelope = %{
        "records" => [
          %{
            "type" => ctx.name,
            "title" => "Missing method",
            "slug" => "missing-#{System.unique_integer([:positive])}",
            "custom_fields" => %{"servings" => "1"}
          }
        ]
      }

      {:ok, report} = Import.run_envelope(envelope, scope(ctx) ++ [skip_media: true])

      assert report.created == []
      assert [%{reason: reason}] = report.failed
      assert reason =~ "method" or reason =~ "required"
    end

    test "supplying it imports cleanly", ctx do
      slug = "with-method-#{System.unique_integer([:positive])}"

      envelope = %{
        "records" => [
          %{
            "type" => ctx.name,
            "title" => "Has method",
            "slug" => slug,
            "custom_fields" => %{"servings" => "1", "method" => "Simmer"}
          }
        ]
      }

      {:ok, report} = Import.run_envelope(envelope, scope(ctx) ++ [skip_media: true])

      assert report.failed == []
      assert reload(ctx, slug).custom_fields["method"] == "Simmer"
    end
  end

  describe "authorization" do
    test "an export reads dynamic types under the actor's own policies", ctx do
      create_recipe!(ctx, %{"servings" => "4"})

      viewer = user(:viewer)

      {:ok, as_admin} = Export.run(:all, scope(ctx))
      {:ok, as_viewer} = Export.run(:all, actor: viewer, tenant: ctx.org)

      assert length(as_viewer["records"]) <= length(as_admin["records"])
    end
  end
end
