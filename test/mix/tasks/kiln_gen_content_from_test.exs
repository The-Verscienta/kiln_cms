defmodule Mix.Tasks.Kiln.Gen.ContentFromTest do
  @moduledoc """
  `mix kiln.gen.content --from` carries a dynamic type's `path_segment` into
  the promoted resource as its plural (#2731).

  The generator derived the plural from the segment for the domain's
  interfaces and its notices, but the generated `use` line had no `plural:`,
  so the resource registered `"<type>s"` and served at a different URL.

  Not async: the codemod's `:ash_domains` app-env fixture is VM-global (see
  `Mix.Tasks.Kiln.Gen.ContentTest`).
  """
  use KilnCMS.DataCase, async: false

  import Igniter.Test

  alias KilnCMS.CMS.TypeDefinition

  setup do
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

    {:ok, igniter: igniter, name: "story#{System.unique_integer([:positive])}"}
  end

  defp seed_type!(name, path_segment) do
    Ash.Seed.seed!(TypeDefinition, %{
      name: name,
      label: "Story",
      path_segment: path_segment,
      org_id: KilnCMS.Accounts.default_org_id()
    })
  end

  test "an irregular path_segment becomes the resource's plural", %{igniter: igniter, name: name} do
    plural = "#{name}_tales"
    seed_type!(name, plural)

    igniter = Igniter.compose_task(igniter, "kiln.gen.content", ["--from", name])

    patch = diff(igniter)
    assert patch =~ ~s(use KilnCMS.CMS.Content, type: :#{name}, plural: "#{plural}"\n)
    assert patch =~ "define(:list_#{plural}, action: :read)"

    notices = Enum.join(igniter.notices, "\n")
    assert notices =~ "Served publicly at /#{plural}/<slug>"
    # The segment is kept, so public URLs don't move.
    refute notices =~ "public URLs move"
  end

  test "a regular path_segment leaves the plural implicit", %{igniter: igniter, name: name} do
    seed_type!(name, "#{name}s")

    igniter = Igniter.compose_task(igniter, "kiln.gen.content", ["--from", name])

    patch = diff(igniter)
    assert patch =~ "use KilnCMS.CMS.Content, type: :#{name}\n"
    refute patch =~ "plural:"
    assert patch =~ "define(:list_#{name}s, action: :read)"
  end

  test "an unusable path_segment falls back to the default plural and says the URLs move",
       %{igniter: igniter, name: name} do
    seed_type!(name, "#{name}-tales")

    igniter = Igniter.compose_task(igniter, "kiln.gen.content", ["--from", name])

    patch = diff(igniter)
    refute patch =~ "plural:"
    assert patch =~ "define(:list_#{name}s, action: :read)"

    notices = Enum.join(igniter.notices, "\n")
    assert notices =~ "Served publicly at /#{name}s/<slug>"
    assert notices =~ "public URLs move from /#{name}-tales/<slug> to /#{name}s/<slug>"
  end
end
