defmodule KilnCMS.MultitenancyDynamicTypesTest do
  @moduledoc """
  Tenant isolation for the dynamic type-registry (epic #336, PR 4b):
  `TypeDefinition` and `FieldDefinition` are per-site.

  Proves the `:attribute` axis holds for the runtime schema: two sites can each
  define a type/field with the same name, a scoped read (and the per-org
  `ContentTypes` registry) returns only that org's schema, a tenant-less read
  spans both (`global?: true`), and a custom-field write only ever sees its own
  site's field definitions.

  Not async: the `ContentTypes` registry + reads span the table, so a shared
  sandbox is required. Orgs are seeded via `Ash.Seed` to bypass the
  `multitenancy_enabled` create guard.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mtdt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  # A distinctive, collision-free type name (not a compiled type / reserved path).
  defp type_name, do: "gadget#{System.unique_integer([:positive])}"

  setup do
    %{a: org("orga"), b: org("orgb"), actor: admin()}
  end

  describe "TypeDefinition name isolation" do
    test "two orgs can each define a type with the same name", %{a: a, b: b, actor: actor} do
      name = type_name()

      ta = CMS.create_type_definition!(%{name: name, label: "A"}, actor: actor, tenant: a)
      tb = CMS.create_type_definition!(%{name: name, label: "B"}, actor: actor, tenant: b)

      assert ta.org_id == a.id
      assert tb.org_id == b.id
      refute ta.id == tb.id
    end

    test "a duplicate type name WITHIN one org is rejected", %{a: a, actor: actor} do
      name = type_name()
      CMS.create_type_definition!(%{name: name, label: "First"}, actor: actor, tenant: a)

      assert {:error, _} =
               CMS.create_type_definition(%{name: name, label: "Second"}, actor: actor, tenant: a)
    end
  end

  describe "the ContentTypes registry is per-org" do
    setup %{a: a, b: b, actor: actor} do
      na = type_name()
      nb = type_name()
      CMS.create_type_definition!(%{name: na, label: "A only"}, actor: actor, tenant: a)
      CMS.create_type_definition!(%{name: nb, label: "B only"}, actor: actor, tenant: b)
      %{na: na, nb: nb}
    end

    test "dynamic_all/1 returns only the org's own dynamic types", ctx do
      a_names = ContentTypes.dynamic_all(ctx.a.id) |> Enum.map(& &1.type)
      assert ctx.na in a_names
      refute ctx.nb in a_names

      b_names = ContentTypes.dynamic_all(ctx.b.id) |> Enum.map(& &1.type)
      assert ctx.nb in b_names
      refute ctx.na in b_names
    end

    # `all_for_org/1` and `options/2` are the shared enumerations that replaced
    # ~20 hand-rolled `all() ++ dynamic_all(org_id(...))` expressions (#527), so
    # they are now the single place a leak between sites would appear.
    test "all_for_org/1 and options/2 carry only the org's own dynamic types", ctx do
      a_types = ContentTypes.all_for_org(ctx.a) |> Enum.map(& &1.type)
      assert ctx.na in a_types
      refute ctx.nb in a_types

      # ...and an org struct and its bare id are the same org.
      assert ContentTypes.all_for_org(ctx.b.id) == ContentTypes.all_for_org(ctx.b)

      a_values = ctx.a |> ContentTypes.options() |> Enum.map(&elem(&1, 1))
      assert ctx.na in a_values
      refute ctx.nb in a_values
    end

    test "get_dynamic/2 resolves a name only within its own site", ctx do
      assert %{type: type} = ContentTypes.get_dynamic(ctx.na, ctx.a.id)
      assert type == ctx.na
      assert ContentTypes.get_dynamic(ctx.na, ctx.b.id) == nil
    end

    test "a scoped list_type_definitions returns only that org's rows; tenant-less spans both",
         ctx do
      a_names =
        CMS.list_type_definitions!(actor: ctx.actor, tenant: ctx.a) |> Enum.map(& &1.name)

      assert ctx.na in a_names
      refute ctx.nb in a_names

      all_names = CMS.list_type_definitions!(actor: ctx.actor) |> Enum.map(& &1.name)
      assert ctx.na in all_names
      assert ctx.nb in all_names
    end
  end

  describe "FieldDefinition isolation" do
    test "two orgs can each define the same field on the same compiled type",
         %{a: a, b: b, actor: actor} do
      fa =
        CMS.create_field_definition!(%{content_type: :page, name: "subtitle", label: "A"},
          actor: actor,
          tenant: a
        )

      fb =
        CMS.create_field_definition!(%{content_type: :page, name: "subtitle", label: "B"},
          actor: actor,
          tenant: b
        )

      assert fa.org_id == a.id
      assert fb.org_id == b.id
    end

    test "field_definitions_for is scoped to the reading org", %{a: a, b: b, actor: actor} do
      CMS.create_field_definition!(%{content_type: :page, name: "subtitle", label: "A"},
        actor: actor,
        tenant: a
      )

      CMS.create_field_definition!(%{content_type: :page, name: "subtitle", label: "B"},
        actor: actor,
        tenant: b
      )

      a_labels =
        CMS.field_definitions_for!(:page, actor: actor, tenant: a)
        |> Enum.filter(&(&1.name == "subtitle"))
        |> Enum.map(& &1.label)

      assert a_labels == ["A"]
    end
  end

  describe "custom-field writes see only their own site's schema" do
    test "a page in org A is validated against A's field definitions, not B's",
         %{a: a, b: b, actor: actor} do
      # Org B requires a custom field on pages; org A does not.
      CMS.create_field_definition!(
        %{content_type: :page, name: "b_only", label: "B only", required: true},
        actor: actor,
        tenant: b
      )

      # Creating a page in org A must NOT trip B's required field (A has no such
      # definition), i.e. ApplyCustomFields read the schema under A's tenant.
      assert {:ok, _page} =
               CMS.create_page(
                 %{title: "A page", slug: "a-#{System.unique_integer([:positive])}", blocks: []},
                 actor: actor,
                 tenant: a
               )

      # Sanity: the same create in org B is rejected for the missing required field.
      assert {:error, _} =
               CMS.create_page(
                 %{title: "B page", slug: "b-#{System.unique_integer([:positive])}", blocks: []},
                 actor: actor,
                 tenant: b
               )
    end
  end

  describe "generic dispatch resolves the type under the caller's org (#972)" do
    # `ContentTypes`' convention dispatch built its interface name and looked up
    # the domain via `get!(type)` with NO org, so every path that goes through
    # `call/4` — transition, update, restore, purge, destroy, list_versions —
    # resolved a dynamic type against the DEFAULT org and raised "unknown
    # content type" for one defined anywhere else.
    setup %{b: b, actor: actor} do
      name = type_name()

      CMS.create_type_definition!(%{name: name, label: "Gadget"}, actor: actor, tenant: b)

      entry =
        ContentTypes.create!(
          name,
          %{title: "A gadget", slug: "gadget-#{System.unique_integer([:positive])}", blocks: []},
          actor: actor,
          tenant: b
        )

      %{name: name, entry: entry}
    end

    test "transition/4 publishes a dynamic type in a non-default org", %{
      name: name,
      entry: entry,
      b: b,
      actor: actor
    } do
      assert {:ok, published} =
               ContentTypes.transition(name, "publish", entry, actor: actor, tenant: b)

      assert published.state == :published
    end

    test "update/4 reaches the right domain too", %{name: name, entry: entry, b: b, actor: actor} do
      assert {:ok, updated} =
               ContentTypes.update(name, entry, %{title: "Renamed"}, actor: actor, tenant: b)

      assert updated.title == "Renamed"
    end

    test "list_versions!/2 and destroy/3 resolve under the tenant", %{
      name: name,
      entry: entry,
      b: b,
      actor: actor
    } do
      assert is_list(ContentTypes.list_versions!(name, actor: actor, tenant: b))
      assert :ok = ContentTypes.destroy(name, entry, actor: actor, tenant: b)
    end

    # The importer is the caller that made this visible: it wraps the publish in
    # a rescue, so the raise became "every record silently stayed a draft while
    # the report said published".
    test "a dynamic type imports as PUBLISHED, not silently as a draft", %{
      name: name,
      b: b,
      actor: actor
    } do
      slug = "imported-#{System.unique_integer([:positive])}"

      {:ok, report} =
        KilnCMS.Portability.Import.run_envelope(
          %{
            "records" => [
              %{"type" => name, "title" => "Imported", "slug" => slug, "state" => "published"}
            ]
          },
          actor: actor,
          tenant: b,
          skip_media: true
        )

      assert length(report.created) == 1

      imported =
        ContentTypes.list!(name, actor: actor, tenant: b) |> Enum.find(&(&1.slug == slug))

      assert imported.state == :published
    end
  end
end
