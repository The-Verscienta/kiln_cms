defmodule Mix.Tasks.Kiln.Gen.PluginTest do
  @moduledoc false

  # Not async (#2380). Igniter evaluates the test project's config/config.exs
  # while formatting: it puts what that config sets into the real app env,
  # then restores a snapshot of the WHOLE app env taken before. Concurrently,
  # that swaps keys under other tests and can put back a value another test
  # had already restored, leaking it for the rest of the run. The generator
  # wrote `:plugins` there until #2910; the compile tests below also define
  # modules, which is no place for concurrency either.
  use ExUnit.Case, async: false

  import Igniter.Test

  alias Mix.Tasks.Kiln.Gen.Plugin

  defp project, do: test_project(files: %{"config/config.exs" => "import Config\n"})

  defp source(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  # Compiles the sources together and returns the warnings and errors, so a
  # missing @impl shows up as a failure rather than noise on stderr. A block
  # derives Inspect, and protocols are already consolidated in a test run, so
  # that one warning is the test's doing, not the generated code's.
  defp compile_diagnostics(sources) do
    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        Enum.each(sources, &Code.compile_string/1)
      end)

    diagnostics
    |> Enum.map(& &1.message)
    |> Enum.reject(&(&1 =~ "protocol has already been consolidated"))
  end

  # Uncomments each `# def` example: its `# @impl` line, if it has one, and
  # its `#   ` continuation lines. Prose comments stay comments.
  defp uncomment_examples(source) do
    Regex.replace(
      ~r/^[ \t]*# (?:@impl .*\n[ \t]*# )?def .*\n(?:[ \t]*#   .*\n)*/m,
      source,
      &String.replace(&1, ~r/^([ \t]*)# ?/m, "\\1")
    )
  end

  describe "an overlay plugin (the default)" do
    # #2975: an overlay's tables stop the staging scrub until declared, so the
    # scaffold shows the declaration beside domains/0, in a shape that works
    # once uncommented.
    test "shows how to declare its tables for the staging scrub" do
      camel = "GenScrubPluginT#{System.unique_integer([:positive])}"
      source = Plugin.plugin_source(camel, nil)

      [example] =
        Regex.run(~r/# def staging_scrub,\n(?:\s*#.*\n)+/, source)

      uncommented = String.replace(example, ~r/^\s*# ?/m, "")
      assert {:ok, _quoted} = Code.string_to_quoted(uncommented)
      assert uncommented =~ "{:purge, #{camel}.Catalog.Booking}"
      assert uncommented =~ "{:rewrite, #{camel}.Catalog.Guest, set: [email: nil]}"
      assert uncommented =~ ~s|{:keep, #{camel}.Catalog.Venue, "opening hours, no visitors"}|

      # Commented out: a fresh plugin owns no tables and declares nothing.
      Code.compile_string(source)
      assert Module.concat([camel, "Plugin"]).staging_scrub() == []
    end

    # #2910: registering in the core's tracked config/config.exs put an overlay
    # plugin into the reusable core. The overlay's activation file is
    # projects/<name>/project.exs, which replaces the core's :plugins list.
    test "goes under projects/ and is registered in the overlay's project.exs" do
      igniter = Igniter.compose_task(project(), "kiln.gen.plugin", ["Ratings"])

      assert_creates(igniter, "projects/ratings/plugin.ex")
      assert_creates(igniter, "projects/ratings/project.exs")
      assert_unchanged(igniter, "config/config.exs")

      project_exs = source(igniter, "projects/ratings/project.exs")
      assert project_exs =~ ~r/^config :kiln_cms, :plugins, \[Ratings\.Plugin\]$/m
      assert project_exs =~ "cp projects/ratings/project.exs config/project.exs"
      assert {:ok, _quoted} = Code.string_to_quoted(project_exs)
    end

    test "an overlay that already has a project.exs gets the plugin added to its list" do
      igniter =
        test_project(
          files: %{
            "config/config.exs" => "import Config\n",
            "projects/ratings/project.exs" => """
            import Config

            config :kiln_cms, :plugins, [Other.Plugin]
            """
          }
        )
        |> Igniter.compose_task("kiln.gen.plugin", ["Ratings"])

      assert source(igniter, "projects/ratings/project.exs") =~
               "config :kiln_cms, :plugins, [Other.Plugin, Ratings.Plugin]"

      assert_unchanged(igniter, "config/config.exs")
    end

    # #2910: a warning fails an overlay built --warnings-as-errors. Elixir
    # warns about a callback without @impl once any callback in the module has
    # one, unless it overrides a default that carries it (every Kiln.Plugin
    # callback does).
    test "the generated overlay compiles without warnings" do
      camel = "GenCleanPluginT#{System.unique_integer([:positive])}"
      snake = Macro.underscore(camel)

      igniter =
        Igniter.compose_task(project(), "kiln.gen.plugin", [
          camel,
          "--block",
          "star_rating",
          "--field",
          "stars"
        ])

      sources =
        Enum.map(
          ["plugin.ex", "blocks/star_rating.ex", "field_types/stars.ex"],
          &source(igniter, "projects/#{snake}/#{&1}")
        )

      assert compile_diagnostics(sources) == []

      assert Module.concat([camel, "Plugin"]).blocks() == [
               Module.concat([camel, "Blocks.StarRating"])
             ]
    end

    # The commented examples are there to be uncommented; each one has to
    # compile cleanly once it is (#2910). The field type's
    # handle_input_event/3 has no default, so it was the one that warned:
    # no @impl, and an unused variable.
    test "every commented callback compiles without warnings once uncommented" do
      camel = "GenUncommentT#{System.unique_integer([:positive])}"

      plugin = uncomment_examples(Plugin.plugin_source(camel, nil))
      field = uncomment_examples(Plugin.field_source(camel, "stars"))

      assert plugin =~ ~r/^\s+def domains, do: \[#{camel}\.Catalog\]$/m
      assert plugin =~ ~r/^\s+def staging_scrub,$/m
      assert plugin =~ ~r/^\s+def oban_queues, do:/m
      assert field =~ ~r/^\s+do: %\{hook: Kiln\.FieldType\.colocated_hook/m
      assert field =~ ~r/^\s+def handle_input_event\(/m

      assert compile_diagnostics([plugin, field]) == []
    end

    # #2910: a hand-written content type needs its search-vector migration,
    # which ash.codegen can't write and mix kiln.search.check gates.
    test "the notice covers activation and the search-vector migration" do
      igniter = Igniter.compose_task(project(), "kiln.gen.plugin", ["Ratings"])
      notice = Enum.join(igniter.notices, "\n")

      assert notice =~ ~r/^config :kiln_cms, :plugins in projects\/ratings\/project\.exs, the$/m
      assert notice =~ ~r/^\s+- dev: cp projects\/ratings\/project\.exs config\/project\.exs$/m
      assert notice =~ ~r/^\s+- image: docker build --build-arg PROJECT=ratings$/m
      assert notice =~ ~r/^\s+def up, do: add_search_vector\("<table>"\)$/m
      assert notice =~ ~r/^\s+def down, do: drop_search_vector\("<table>"\)$/m

      assert notice =~
               ~r/^\s+one creating its table, in projects\/ratings\/priv\/repo\/migrations\/:$/m

      assert notice =~ ~r/^\s+the template\. mix kiln\.search\.check fails without it\.$/m
      refute notice =~ "config/config.exs"
    end

    # #2733: the notice used to say `mix kiln.gen.content <Type> --domain
    # Ratings.Catalog`. kiln.gen.content has no --domain switch and registers
    # every type on KilnCMS.CMS, so the next step has to be the by-hand one.
    test "the next step for content types is one that works" do
      igniter = Igniter.compose_task(project(), "kiln.gen.plugin", ["Ratings"])
      notice = Enum.join(igniter.notices, "\n")

      assert notice =~
               ~r/^\s+use KilnCMS\.CMS\.Content, type: :<type>, domain: Ratings\.Catalog$/m

      assert notice =~ ~r/^\s+projects\/example\/catalog\/\*\.ex as the template:$/m
      assert notice =~ ~r/^\s+- uncomment domains\/0 in projects\/ratings\/plugin\.ex$/m
      # The registration lives in the overlay, not in the git-ignored
      # config/project.exs, which is only where dev activation copies it.
      assert notice =~ ~r/^\s+in projects\/ratings\/project\.exs, with$/m
      assert notice =~ ~r/^\s+replace the core's too, so restate the core's entries\.$/m
      assert notice =~ ~r/^\s+- mix ash\.codegen <migration_name>, then move what it wrote to$/m
      assert notice =~ ~r/^\s+priv\/ into projects\/ratings\/priv\/repo\/migrations\/ and$/m
      assert notice =~ ~r/^\s+projects\/ratings\/priv\/resource_snapshots\/repo\/\. Before the$/m
      assert notice =~ ~r/^\s+cp -R projects\/ratings\/priv\/\. priv\/$/m
      refute notice =~ "--domain"
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

      # The bundled SDK's minor: 1.6.0 → "~> 1.6".
      sdk = Plugin.sdk_requirement()
      assert sdk == "~> 1.6"

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
      # A dependency owns no tables, so it has nothing to declare (#2975).
      refute source =~ "staging_scrub"
    end
  end
end
