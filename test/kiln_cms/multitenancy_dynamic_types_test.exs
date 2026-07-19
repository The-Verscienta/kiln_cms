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
end
