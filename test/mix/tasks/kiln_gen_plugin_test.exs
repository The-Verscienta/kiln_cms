defmodule Mix.Tasks.Kiln.Gen.PluginTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.Kiln.Gen.Plugin

  defp project, do: test_project(files: %{"config/config.exs" => "import Config\n"})

  describe "an overlay plugin (the default)" do
    test "goes under projects/ and is registered in :plugins" do
      igniter = Igniter.compose_task(project(), "kiln.gen.plugin", ["Ratings"])

      assert_creates(igniter, "projects/ratings/plugin.ex")
      assert diff(igniter) =~ "plugins: [Ratings.Plugin]"
    end
  end

  describe "--dep (#1909)" do
    test "writes a standalone Mix project beside the checkout and leaves the core alone" do
      igniter =
        Igniter.compose_task(project(), "kiln.gen.plugin", [
          "KilnRatings",
          "--dep",
          "--block",
          "star_rating",
          "--field",
          "stars"
        ])

      for path <- [
            "mix.exs",
            ".formatter.exs",
            ".gitignore",
            "config/config.exs",
            "README.md",
            "lib/kiln_ratings/plugin.ex",
            "lib/kiln_ratings/blocks/star_rating.ex",
            "lib/kiln_ratings/field_types/stars.ex",
            "test/test_helper.exs",
            "test/kiln_ratings_test.exs"
          ] do
        assert_creates(igniter, Path.join("../kiln_ratings", path))
      end

      # A dependency's modules are not loadable until a site adds it, so
      # nothing registers it here, and nothing lands in projects/.
      assert_unchanged(igniter, "config/config.exs")
      refute Enum.any?(Rewrite.paths(igniter.rewrite), &String.starts_with?(&1, "projects/"))
    end

    test "--path picks where the project goes" do
      igniter =
        Igniter.compose_task(project(), "kiln.gen.plugin", [
          "Ratings",
          "--dep",
          "--path",
          "plugins/ratings"
        ])

      assert_creates(igniter, "plugins/ratings/mix.exs")
      assert_creates(igniter, "plugins/ratings/lib/ratings/plugin.ex")
    end

    test "--path without --dep is refused rather than ignored" do
      igniter = Igniter.compose_task(project(), "kiln.gen.plugin", ["Ratings", "--path", "x"])

      assert [issue] = igniter.issues
      assert issue =~ "--path only applies with --dep"
      assert_unchanged(igniter, "config/config.exs")
    end

    test "the project depends on kiln_plugin, and on phoenix_html only for a block" do
      deps = fn source ->
        {:defmodule, _meta, [_name, [do: body]]} = Code.string_to_quoted!(source)
        {:__block__, _meta, defs} = body

        Enum.find_value(defs, fn
          {:defp, _meta, [{:deps, _, _}, [do: deps]]} -> deps
          _other -> nil
        end)
      end

      # The bundled SDK's minor: 1.1.0 → "~> 1.1".
      sdk = Plugin.sdk_requirement()
      assert sdk == "~> 1.1"

      assert deps.(Plugin.dep_mix_source("Ratings", "ratings", nil)) ==
               [{:kiln_plugin, sdk}]

      assert deps.(Plugin.dep_mix_source("Ratings", "ratings", "star_rating")) ==
               [{:kiln_plugin, sdk}, {:phoenix_html, "~> 4.1"}]
    end

    test "the plugin module compiles, and points content types at an overlay" do
      camel = "GenDepPluginT#{System.unique_integer([:positive])}"
      source = Plugin.plugin_source(camel, "badge", nil, dep: true)
      Code.compile_string(source)

      # (Strings, not bare aliases: `alias ...Gen.Plugin` would capture `Plugin`.)
      assert Module.concat([camel, "Plugin"]).blocks() == [
               Module.concat([camel, "Blocks", "Badge"])
             ]

      assert source =~ "projects/ overlay"
      refute source =~ "def domains"
    end
  end
end
