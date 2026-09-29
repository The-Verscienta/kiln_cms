defmodule Mix.Tasks.Kiln.Gen.ContentStrictTest do
  @moduledoc """
  `mix kiln.gen.content --from` under the strict (`global?: false`) tenancy
  build (#419), which is the production default and runs only on the strict CI
  leg.

  The generator used to read the dynamic type's `TypeDefinition` with no
  tenant. The fail-open main suite answered that read; production refused it,
  so promoting a type failed there (#1743). It now reads in the org `--org`
  names, or the default org.

  Not async: the codemod's `:ash_domains` app-env fixture is VM-global.
  """
  use KilnCMS.DataCase, async: false

  import Igniter.Test
  import KilnCMS.OrgFixtures

  @moduletag :strict_tenancy

  alias KilnCMS.CMS.TypeDefinition

  setup do
    # See `Mix.Tasks.Kiln.Gen.ContentTest`: the codemod's domain lookup needs
    # the compiled `:ash_domains` config a real project has.
    Application.put_env(:test, :ash_domains, [KilnCMS.CMS])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    igniter =
      test_project(
        files: %{
          "config/config.exs" => """
          import Config
          config :test, ash_domains: [KilnCMS.CMS]
          """,
          "lib/kiln_cms/cms.ex" => """
          defmodule KilnCMS.CMS do
            use Ash.Domain, otp_app: :test

            resources do
            end
          end
          """
        }
      )

    # The same name in two orgs, told apart by `has_excerpt`, so the generated
    # module shows which org's definition the generator read.
    name = "gizmo#{System.unique_integer([:positive])}"
    other = org("gen-content-strict")
    seed_type!(name, KilnCMS.Accounts.default_org_id(), has_excerpt: false)
    seed_type!(name, other.id, has_excerpt: true)

    {:ok, igniter: igniter, name: name, other: other}
  end

  defp seed_type!(name, org_id, attrs) do
    Ash.Seed.seed!(
      TypeDefinition,
      Map.merge(
        %{name: name, label: "Gizmo", path_segment: "#{name}s", org_id: org_id},
        Map.new(attrs)
      )
    )
  end

  defp resource_path(name), do: "lib/kiln_cms/cms/#{name}.ex"

  test "the strict build is actually strict for type definitions" do
    refute Ash.Resource.Info.multitenancy_global?(TypeDefinition)
  end

  test "--org reads that organization's type definition", ctx do
    igniter =
      Igniter.compose_task(ctx.igniter, "kiln.gen.content", [
        "--from",
        ctx.name,
        "--org",
        ctx.other.slug
      ])

    assert_creates(igniter, resource_path(ctx.name))
    assert diff(igniter) =~ "use KilnCMS.CMS.Content, type: :#{ctx.name}, excerpt?: true"
  end

  test "without --org it reads the default org's type definition", ctx do
    igniter = Igniter.compose_task(ctx.igniter, "kiln.gen.content", ["--from", ctx.name])

    assert_creates(igniter, resource_path(ctx.name))
    patch = diff(igniter)
    assert patch =~ "use KilnCMS.CMS.Content, type: :#{ctx.name}\n"
    refute patch =~ "excerpt?: true"
  end

  test "an unknown --org is a clear error", ctx do
    assert_raise Mix.Error, ~r/no organization with slug "no-such-org"/, fn ->
      Igniter.compose_task(ctx.igniter, "kiln.gen.content", [
        "--from",
        ctx.name,
        "--org",
        "no-such-org"
      ])
    end
  end

  test "a type the org does not define is a clear error", ctx do
    assert_raise Mix.Error, ~r/no dynamic type named "nope" in organization/, fn ->
      Igniter.compose_task(ctx.igniter, "kiln.gen.content", [
        "--from",
        "nope",
        "--org",
        ctx.other.slug
      ])
    end
  end
end
