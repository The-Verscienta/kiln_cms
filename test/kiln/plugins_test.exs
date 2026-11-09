defmodule Kiln.PluginsTest do
  @moduledoc """
  The plugin contract (D18), proven through the test-suite fixture plugin:
  its block joins the storage union / registry / firing render with no core
  edits, its supervision child runs, and its queue is declared for the boot
  merge.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.CMS
  alias KilnCMS.FixturePlugin

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "plug-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Membership assertions, not exact-list: a downstream overlay runs this
  # suite with its own plugin installed next to the fixture (projects/README).
  test "the registry reflects the installed plugin" do
    assert FixturePlugin in Kiln.Plugins.all()
    assert FixturePlugin.CalloutBlock in Kiln.Plugins.blocks()
    assert Keyword.get(Kiln.Plugins.oban_queues(), :fixture) == 1

    assert %{label: "Fixture", path: "/editor/fixture", role: :admin} in Kiln.Plugins.nav_items()
  end

  test "manifests/0 exposes the catalog metadata + contribution surface" do
    manifest = Enum.find(Kiln.Plugins.manifests(), &(&1.module == FixturePlugin))

    assert manifest.name == "fixture_plugin"
    assert manifest.version == "1.2.3"
    assert manifest.summary == "Test fixture exercising every plugin seam."
    assert manifest.homepage == "https://example.com/fixture-plugin"

    assert manifest.blocks == [
             FixturePlugin.CalloutBlock,
             FixturePlugin.RestrictedRequiredBlock,
             FixturePlugin.RestrictedRequiredDefaultBlock,
             FixturePlugin.ProductCardBlock,
             FixturePlugin.ChecklistBlock
           ]

    # Rating is the one with real behaviour; Tokenless and Exploding exist to
    # cover `type_token_definitions/1`'s probe and rescue branches (#804), which
    # no CORE field type can reach. Lookup carries a client hook (#1918).
    assert manifest.field_types == [
             FixturePlugin.FieldTypes.Rating,
             FixturePlugin.FieldTypes.Tokenless,
             FixturePlugin.FieldTypes.Exploding,
             FixturePlugin.FieldTypes.Lookup
           ]

    # The fixture declares neither, but both keys must be in the manifest: a
    # plugin contributing only a check is invisible to the catalog otherwise.
    assert manifest.advisories == []
    assert manifest.spam_checks == []
    assert manifest.image_backends == [FixturePlugin.ImageBackend]

    assert manifest.nav_items == 1
    assert manifest.admin_routes == 1
    assert manifest.plug_routes == 0
    assert manifest.oban_queues == [fixture: 1]
    assert manifest.children == 1
  end

  test "manifests/0 counts a dependency plugin's plug routes (#2272)" do
    manifest = Enum.find(Kiln.Plugins.manifests(), &(&1.module == KilnDepFixture.Plugin))

    assert manifest.plug_routes == 6

    assert {:forward, "/fixture-forward", KilnDepFixture.FeedRouter, []} in Kiln.Plugins.plug_routes()
  end

  test "manifests/0 lists a dependency plugin's challenge providers (#2249)" do
    manifest = Enum.find(Kiln.Plugins.manifests(), &(&1.module == KilnDepFixture.Plugin))

    assert manifest.challenge_providers == [KilnDepFixture.ChallengeProvider]
    assert KilnDepFixture.ChallengeProvider in Kiln.Plugins.challenge_providers()

    fixture = Enum.find(Kiln.Plugins.manifests(), &(&1.module == FixturePlugin))
    assert fixture.challenge_providers == []
  end

  describe "a plugin compiled against kiln_plugin before 1.4" do
    # No `plug_routes/0` at all: the behaviour is implemented by hand, as a
    # plugin built against the 1.3 package would be.
    defmodule OldPlugin do
      def name, do: "old"
    end

    test "contributes no plug routes, and does not crash the readers" do
      assert Kiln.Plugins.PlugRoute.of(OldPlugin) == []
      assert Kiln.Plugins.PlugRoute.of(NotLoadedAnywhere) == []
    end

    test "contributes no security checks (#2252)" do
      assert KilnCMS.Security.Posture.Registry.of_plugin(OldPlugin) == []
    end

    test "contributes no challenge providers (#2249)" do
      assert KilnCMS.Challenge.Registry.of_plugin(OldPlugin) == []
      assert KilnCMS.Challenge.Registry.of_plugin(NotLoadedAnywhere) == []
    end

    test "a plugin that never overrides the callback contributes none" do
      defmodule DefaultsPlugin do
        use Kiln.Plugin
      end

      assert DefaultsPlugin.plug_routes() == []
      assert Kiln.Plugins.PlugRoute.of(DefaultsPlugin) == []
      assert DefaultsPlugin.challenge_providers() == []
      assert DefaultsPlugin.security_checks() == []
      assert KilnCMS.Challenge.Registry.of_plugin(DefaultsPlugin) == []
    end
  end

  test "a metadata-free plugin reports nil metadata (use defaults)" do
    defmodule BarelyAPlugin do
      use Kiln.Plugin
    end

    assert BarelyAPlugin.version() == nil
    assert BarelyAPlugin.summary() == nil
    assert BarelyAPlugin.homepage() == nil
  end

  describe "mix kiln.plugins.list" do
    import ExUnit.CaptureIO

    test "renders installed plugins with metadata and contributions" do
      output = capture_io(fn -> assert Mix.Tasks.Kiln.Plugins.List.run([]) == :ok end)

      assert output =~ "fixture_plugin v1.2.3"
      assert output =~ "Test fixture exercising every plugin seam."
      assert output =~ "https://example.com/fixture-plugin"
      # Contribution summary is pluralized and omits zero-count kinds.
      assert output =~ "5 blocks, 4 field types, 1 image backend, 1 nav item, 1 admin route"
      assert output =~ "6 plug routes"
    end

    test "the contribution summary counts every route kind" do
      # The fixture declares only an admin route, so the editor- and
      # public-route seams are covered here instead: a plugin whose whole
      # surface is a public booking page must not read as contributing nothing.
      assert contributions(editor_routes: 1, public_routes: 2) ==
               "1 editor route, 2 public routes"

      assert contributions(plug_routes: 1) == "1 plug route"
    end

    test "the contribution summary counts challenge providers" do
      assert contributions(challenge_providers: [Captcha]) == "1 challenge provider"
      assert contributions(challenge_providers: [Captcha, Other]) == "2 challenge providers"
    end

    test "the contribution summary counts security checks (#2252)" do
      assert contributions(security_checks: [Captcha]) == "1 security check"
      assert contributions(security_checks: [Captcha, Other]) == "2 security checks"
    end

    test "the contribution summary counts advisories and spam checks" do
      # The other two kinds no in-tree plugin declares. `advisories` is also the
      # one irregular plural in the summary — the generic rule would render it
      # "2 advisorys".
      assert contributions(advisories: [MissingSummary], spam_checks: [TooManyEmoji]) ==
               "1 advisory, 1 spam check"

      assert contributions(
               advisories: [MissingSummary, StaleLink],
               spam_checks: [TooManyEmoji, LinkFarm, Gibberish]
             ) == "2 advisories, 3 spam checks"
    end

    test "a plugin that contributes nothing says so" do
      assert contributions([]) == "nothing (metadata only)"
    end
  end

  # The rendered contribution summary for a plugin contributing exactly
  # `overrides` — the leading header is matched, not returned, so each case
  # reads as the one list of kinds it is about.
  defp contributions(overrides) do
    manifest =
      Map.merge(
        %{
          module: Booking.Plugin,
          name: "booking",
          version: nil,
          summary: nil,
          homepage: nil,
          domains: [],
          blocks: [],
          field_types: [],
          advisories: [],
          spam_checks: [],
          image_backends: [],
          challenge_providers: [],
          security_checks: [],
          nav_items: 0,
          admin_routes: 0,
          editor_routes: 0,
          public_routes: 0,
          plug_routes: 0,
          oban_queues: [],
          children: 0
        },
        Map.new(overrides)
      )

    "* booking — Booking.Plugin\n    contributes: " <> summary =
      Mix.Tasks.Kiln.Plugins.List.format(manifest)

    summary
  end

  test "a plugin block is a first-class member of the block system" do
    # Storage union + runtime registry, from the same compile-time source.
    assert Keyword.has_key?(Blocks.union_types(), :callout)
    assert Blocks.registry()[:callout] == FixturePlugin.CalloutBlock
    assert FixturePlugin.CalloutBlock in Blocks.modules()
  end

  test "a plugin block round-trips through content storage and renders" do
    page =
      CMS.create_page!(
        %{
          title: "Plugged",
          slug: "plug-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "callout", "text" => "Note & well", "tone" => "warn"}]
        },
        actor: admin()
      )

    # Reads back as the plugin's typed struct…
    [%Ash.Union{type: :callout, value: block}] = CMS.get_page!(page.id, authorize?: false).blocks
    assert %FixturePlugin.CalloutBlock{text: "Note & well", tone: "warn"} = block
    assert is_binary(block.id)

    # …and serializes through the standard dispatch (escaped, of course).
    web = block |> Blocks.render(:web) |> IO.iodata_to_binary()
    assert web == ~s(<aside class="callout callout-warn">Note &amp; well</aside>)
    assert Blocks.search_text(block) == "Note & well"
  end

  describe "a plugin compiled as a Mix dependency (#1909)" do
    # `KilnDepFixture` is its own Mix project (sdk/fixtures/dep_plugin) that
    # depends only on `kiln_plugin`, taken by the core's mix.exs as a `path:`
    # dependency, so Mix compiled it before the core. Its block and field type
    # still reach the registries the core bakes at compile time.
    test "is installed and its contributions are registered" do
      assert KilnDepFixture.Plugin in Kiln.Plugins.all()
      assert Keyword.has_key?(Blocks.union_types(), :dep_badge)
      assert Blocks.registry()[:dep_badge] == KilnDepFixture.Badge
      assert KilnCMS.CMS.FieldTypes.get(:stars) == KilnDepFixture.FieldTypes.Stars
      assert :stars in KilnCMS.CMS.FieldTypes.names()
    end

    test "its block round-trips through content storage" do
      page =
        CMS.create_page!(
          %{
            title: "Dep plugged",
            slug: "dep-plug-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "dep_badge", "label" => "New"}]
          },
          actor: admin()
        )

      [%Ash.Union{type: :dep_badge, value: block}] =
        CMS.get_page!(page.id, authorize?: false).blocks

      assert %KilnDepFixture.Badge{label: "New"} = block
      assert %{"_type" => "dep_badge", "label" => "New"} = Blocks.render(block, :json)
      assert Blocks.search_text(block) == "New"
    end

    test "its advisory check runs against a context the core built" do
      check = KilnDepFixture.Advisories.MissingSummary
      body = Kiln.Advisory.Walk.compute([%{"_type" => "heading", "level" => 2, "text" => "Hi"}])

      assert [{^check, %Kiln.Advisory.Finding{code: :dep_missing_summary, field: :summary}}] =
               Kiln.Advisory.Registry.run(Kiln.Advisory.Context.new(%{summary: nil}, body), [
                 check
               ])

      assert [{^check, :ok}] =
               Kiln.Advisory.Registry.run(Kiln.Advisory.Context.new(%{summary: "S"}, body), [
                 check
               ])

      assert [{^check, :n_a}] =
               Kiln.Advisory.Registry.run(
                 Kiln.Advisory.Context.new(%{}, Kiln.Advisory.Walk.compute([])),
                 [check]
               )
    end
  end

  describe "the recompile digest (Kiln.Plugins.__mix_recompile__?/0)" do
    test "is current for the installed plugins" do
      refute Kiln.Plugins.__mix_recompile__?()
    end

    # Mix tracks no compile-time edge into a dependency's modules, so the
    # digest has to see an edit *inside* a contributed module, not only a
    # changed `blocks/0` list. scripts/ci/check_plugin_dep_recompile.sh
    # proves the list case end to end.
    test "changes when a contributed module's code changes, with the same lists" do
      plugin = Module.concat(__MODULE__, "DigestPlugin#{System.unique_integer([:positive])}")
      block = Module.concat(plugin, Block)

      Code.compile_string("""
      defmodule #{inspect(plugin)} do
        def blocks, do: [#{inspect(block)}]
        def field_types, do: []
      end
      """)

      compile_block = fn body ->
        :code.purge(block)
        :code.delete(block)
        Code.compile_string("defmodule #{inspect(block)} do\n  def v, do: #{body}\nend\n")
      end

      compile_block.(1)
      first = Kiln.Plugins.CompileEdges.digest([plugin])
      assert first == Kiln.Plugins.CompileEdges.digest([plugin])

      compile_block.(2)
      refute Kiln.Plugins.CompileEdges.digest([plugin]) == first
    end

    test "says recompile when a plugin module no longer loads" do
      missing = Module.concat(__MODULE__, Missing)
      assert is_reference(Kiln.Plugins.CompileEdges.digest([missing]))
    end
  end

  test "the plugin's supervision child is running" do
    pid = Process.whereis(FixturePlugin.Counter)
    assert is_pid(pid) and Process.alive?(pid)
  end

  describe "mix kiln.gen.plugin sources" do
    test "the generated plugin module compiles against the contract" do
      camel = "GenPluginT#{System.unique_integer([:positive])}"
      compiled = Code.compile_string(Mix.Tasks.Kiln.Gen.Plugin.plugin_source(camel, nil))
      mod = Module.concat([camel, Plugin])

      assert List.keymember?(compiled, mod, 0)
      # `X.Plugin` names itself after X, not the convention suffix.
      assert mod.name() == Macro.underscore(camel)
      assert mod.blocks() == []
      assert mod.nav_items() == []
      # A summary is scaffolded, so a fresh plugin never lists as unexplained.
      assert mod.summary() =~ camel
    end

    test "the generated sample field type compiles against the contract" do
      camel = "GenFieldT#{System.unique_integer([:positive])}"
      Code.compile_string(Mix.Tasks.Kiln.Gen.Plugin.field_source(camel, "hex_color"))

      # (Strings, not bare aliases — same capture caveat as below.)
      mod = Module.concat([camel, "FieldTypes", "HexColor"])
      assert Code.ensure_loaded?(mod)
      assert mod.name() == :hex_color
      assert mod.label() == "Hex color"
      assert mod.cast("  #aabbcc  ", nil) == {:ok, "#aabbcc"}
      assert mod.input_type() == "text"

      # A --field plugin wires the module into field_types/0.
      source = Mix.Tasks.Kiln.Gen.Plugin.plugin_source(camel, nil, "hex_color")
      assert source =~ "def field_types, do: [#{camel}.FieldTypes.HexColor]"
    end

    @tag :capture_log
    test "the generated sample block compiles, renders escaped, and searches" do
      camel = "GenBlockT#{System.unique_integer([:positive])}"
      Code.compile_string(Mix.Tasks.Kiln.Gen.Plugin.block_source(camel, "star_rating"))

      # Spark emits several modules (EctoType etc.) — assert on the block
      # module itself rather than the compile-return list. (Strings, not bare
      # aliases: the test's `alias KilnCMS.Blocks` would capture `Blocks`.)
      mod = Module.concat([camel, "Blocks", "StarRating"])
      assert Code.ensure_loaded?(mod)
      assert Kiln.Block.Info.name(mod) == :star_rating

      block = struct(mod, text: "Nice & shiny")
      html = block |> mod.render(:web) |> IO.iodata_to_binary()
      assert html == ~s(<div class="star_rating">Nice &amp; shiny</div>)
      assert mod.search_text(block) == "Nice & shiny"
    end
  end

  describe "mix kiln.plugins.doctor" do
    # put_env is global — keep these in one sync-safe block by restoring.
    setup do
      original = Application.get_env(:kiln_cms, :plugins, [])
      on_exit(fn -> Application.put_env(:kiln_cms, :plugins, original) end)
      :ok
    end

    test "passes for the fixture plugin" do
      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    # #1909: the core overrides `kiln_plugin` so a plugin's Hex requirement
    # converges on the bundled copy, and Mix then checks no requirement on it.
    test "reads each dependency's kiln_plugin requirement from the resolved graph" do
      # The real one: sdk/fixtures/dep_plugin/mix.exs declares "~> 1.4".
      assert {:kiln_dep_fixture, "~> 1.4"} in Mix.Tasks.Kiln.Plugins.Doctor.sdk_requirements(
               Mix.Tasks.Kiln.Plugins.Doctor.declared_deps()
             )

      requirements =
        Mix.Tasks.Kiln.Plugins.Doctor.sdk_requirements([
          {:future_plugin, [{:jason, "~> 1.0"}, {:kiln_plugin, "~> 9.0"}]},
          {:unrelated, [{:jason, "~> 1.0"}]},
          {:pathless, [{:kiln_plugin, nil}]}
        ])

      assert requirements == [{:future_plugin, "~> 9.0"}]

      assert [problem] =
               Mix.Tasks.Kiln.Plugins.Doctor.sdk_requirement_problems("1.0.0", requirements)

      assert problem =~ "future_plugin requires kiln_plugin ~> 9.0"
      assert problem =~ "bundles kiln_plugin 1.0.0"
    end

    test "accepts a matching requirement and names an unparsable one" do
      assert Mix.Tasks.Kiln.Plugins.Doctor.sdk_requirement_problems("1.2.0", [
               {:a, "~> 1.0"},
               {:b, ">= 1.2.0"}
             ]) == []

      assert [problem] =
               Mix.Tasks.Kiln.Plugins.Doctor.sdk_requirement_problems("1.2.0", [{:c, "one"}])

      assert problem =~ ~s[c requires kiln_plugin "one" (not a valid version requirement)]
    end

    # #2272. `plug_route_problems/1` reads the real compiled router for the core
    # roots, so these also pin that `/editor`, `/api`, `/gql` and `/mcp` are
    # taken whatever the table says.
    defmodule GoodRoutes do
      use Kiln.Plugin

      def plug_routes,
        do: [
          {:post, "/hooks/ping", Hooks, :create},
          {:get, "/hooks/status", Hooks, :show},
          {:forward, "/feeds", Hooks, []}
        ]
    end

    defmodule MalformedRoutes do
      use Kiln.Plugin

      def plug_routes,
        do: [
          {:post, "no-slash", Hooks, :create},
          {:fetch, "/hooks/x", Hooks, :create},
          {:get, "/", Hooks, :index},
          {:get, "/:slug/x", Hooks, :show},
          {:forward, "/feeds/:id", Hooks, []},
          {:get, "/hooks/f", Hooks, fn -> :nope end},
          {:get, "/hooks/m", "NotAModule", :show},
          :not_a_tuple
        ]
    end

    defmodule ReservedRoutes do
      use Kiln.Plugin

      def plug_routes,
        do: [
          {:get, "/editor/hook", Hooks, :show},
          {:get, "/api", Hooks, :show},
          {:forward, "/gql", Hooks, []},
          {:post, "/mcp/x", Hooks, :show},
          # Not under /api: a different first segment that merely starts with it.
          {:get, "/apiary/ok", Hooks, :show},
          {:get, "/editorial", Hooks, :show}
        ]
    end

    defmodule CoreCollision do
      use Kiln.Plugin

      def plug_routes,
        do: [
          {:get, "/up", Hooks, :show},
          {:get, "/sitemap.xml", Hooks, :show}
        ]
    end

    defmodule OverlapsGood do
      use Kiln.Plugin

      def plug_routes,
        do: [
          {:post, "/hooks/ping", Hooks, :create},
          {:match, "/hooks/status", Hooks, :show},
          {:get, "/feeds/rss", Hooks, :show},
          {:get, "/hooks-extra", Hooks, :show}
        ]
    end

    defmodule PublicOverlap do
      use Kiln.Plugin
      def plug_routes, do: [{:forward, "/book", Hooks, []}]
    end

    defmodule PublicBooking do
      use Kiln.Plugin
      def plug_routes, do: []
      def public_routes, do: [{"/book/slots", Hooks.Live, :index}]
    end

    defp plug_problems(plugins), do: Mix.Tasks.Kiln.Plugins.Doctor.plug_route_problems(plugins)

    test "plug routes: a valid set raises nothing" do
      assert plug_problems([GoodRoutes]) == []
      assert plug_problems([FixturePlugin, KilnDepFixture.Plugin]) == []
    end

    test "plug routes: names every malformed entry" do
      problems = plug_problems([MalformedRoutes])

      assert length(problems) == 8
      assert Enum.all?(problems, &(&1 =~ "malformed_routes: plug route"))
      assert Enum.any?(problems, &(&1 =~ "must be absolute"))
      assert Enum.any?(problems, &(&1 =~ ":fetch"))
      assert Enum.any?(problems, &(&1 =~ "no first segment"))
      assert Enum.any?(problems, &(&1 =~ "starts with a parameter or wildcard"))
      assert Enum.any?(problems, &(&1 =~ "must be static"))
      assert Enum.any?(problems, &(&1 =~ "cannot be compiled"))
      assert Enum.any?(problems, &(&1 =~ "is not a module"))
      assert Enum.any?(problems, &(&1 =~ "is not {verb, path"))
    end

    test "plug routes: reserved roots are refused on segment boundaries" do
      problems = plug_problems([ReservedRoutes])

      for root <- ["/editor", "/api", "/gql", "/mcp"] do
        assert Enum.any?(problems, &(&1 =~ "sits under #{root},")),
               "expected #{root} to be refused in #{inspect(problems)}"
      end

      # /apiary and /editorial only start with a reserved root's letters.
      assert length(problems) == 4
    end

    test "plug routes: a path a core route already owns is refused" do
      assert [up, sitemap] = plug_problems([CoreCollision])

      assert up =~ ~s("/up" sits under /up, which core routes already own)
      assert sitemap =~ "sits under /sitemap.xml"
    end

    test "plug routes: the doctor reads the roots from the compiled router" do
      # Not in the hard-coded reserved list; only the route table knows it.
      refute "sitemap.xml" in Kiln.Plugins.PlugRoute.reserved_roots()
      assert plug_problems([CoreCollision]) != []
    end

    test "plug routes: overlaps between plugins are named, on segment boundaries" do
      problems = plug_problems([GoodRoutes, OverlapsGood])

      assert Enum.any?(
               problems,
               &(&1 =~
                   ~s(good_routes: plug route "/hooks/ping" overlaps overlaps_good's plug route "/hooks/ping"))
             )

      # :match is any method.
      assert Enum.any?(
               problems,
               &(&1 =~ ~s("/hooks/status" overlaps overlaps_good's plug route "/hooks/status"))
             )

      # A forward owns everything below it.
      assert Enum.any?(
               problems,
               &(&1 =~ ~s("/feeds" overlaps overlaps_good's plug route "/feeds/rss"))
             )

      # /hooks-extra shares letters with /hooks, not a segment.
      refute Enum.any?(problems, &(&1 =~ "hooks-extra"))
      assert length(problems) == 3
    end

    test "plug routes: a plugin's own duplicate is an overlap" do
      defmodule Duplicate do
        use Kiln.Plugin
        def plug_routes, do: [{:get, "/dup/a", Hooks, :show}, {:get, "/dup/a", Hooks, :other}]
      end

      assert [problem] = plug_problems([Duplicate])
      assert problem =~ "duplicate: plug route \"/dup/a\" overlaps duplicate's plug route"
    end

    test "plug routes: a public route under a plug route's path overlaps" do
      assert [problem] = plug_problems([PublicOverlap, PublicBooking])
      assert problem =~ ~s(plug route "/book" overlaps)
      assert problem =~ ~s(public route "/book/slots")
    end

    test "plug routes: public routes alone are not this check's business" do
      assert plug_problems([PublicBooking]) == []
    end

    test "plug routes: a plugin without the callback is skipped" do
      assert plug_problems([Kiln.PluginsTest.OldPlugin]) == []
    end

    test "plug routes: the run fails with the problem listed" do
      Application.put_env(:kiln_cms, :plugins, [FixturePlugin, ReservedRoutes])

      assert_raise Mix.Error,
                   ~r/reserved_routes: plug route "\/editor\/hook" sits under \/editor/,
                   fn ->
                     ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end)
                   end
    end

    # A plugin that doesn't say what it does is a gap for operators, not a
    # fault: the doctor names it and still passes.
    test "notes a plugin with no summary, without failing" do
      defmodule UndescribedPlugin do
        use Kiln.Plugin
        def name, do: "undescribed"
      end

      defmodule PlaceholderPlugin do
        use Kiln.Plugin
        def name, do: "placeholder"
        def summary, do: "TODO: say what Placeholder adds to a Kiln site."
      end

      Application.put_env(:kiln_cms, :plugins, [
        FixturePlugin,
        UndescribedPlugin,
        PlaceholderPlugin
      ])

      output =
        ExUnit.CaptureIO.capture_io(fn -> assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok end)

      assert output =~ "note: undescribed has no summary/0"
      assert output =~ "note: placeholder has no summary/0"
      refute output =~ "note: fixture_plugin"
      assert output =~ "3 plugin(s) OK"
    end

    # #1540: a project.exs written before a core domain existed restates a
    # list without it, and `mix ash.codegen` then offers to DROP its tables.
    test "flags a core domain a project's :ash_domains list left out" do
      core = Mix.Tasks.Kiln.Plugins.Doctor.core_domains()

      assert KilnCMS.Notifications in core
      assert KilnCMS.CMS in core
      refute KilnCMS.CountlessVersions.Domain in core

      assert Mix.Tasks.Kiln.Plugins.Doctor.core_domain_problems(core) == []

      assert [problem] =
               Mix.Tasks.Kiln.Plugins.Doctor.core_domain_problems(core -- [KilnCMS.Notifications])

      assert problem =~ "core domain KilnCMS.Notifications is missing from :ash_domains"
    end

    # A downstream overlay registers its own domains through its plugin
    # (`Kiln.Plugin.domains/0`), so those are subtracted by what the installed
    # plugins declare rather than by name: `Example.Catalog` here, a project's
    # own catalog domain in an overlay's composed suite.
    test "the core's configured domains are exactly the ones it compiles" do
      plugin_domains = Enum.flat_map(Kiln.Plugins.all(), & &1.domains())

      assert Enum.sort(Application.get_env(:kiln_cms, :ash_domains)) -- plugin_domains ==
               Mix.Tasks.Kiln.Plugins.Doctor.core_domains()
    end

    test "flags unregistered domains and core block collisions" do
      defmodule BadPlugin do
        use Kiln.Plugin
        def domains, do: [Not.Registered.Domain]
        def blocks, do: [KilnCMS.Blocks.Heading]
      end

      Application.put_env(:kiln_cms, :plugins, [BadPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "missing from :ash_domains"
      assert error.message =~ "missing from :content_domains"
      assert error.message =~ "block :heading collides with a core block"
    end

    test "flags field-type contract violations and name collisions" do
      defmodule NotAFieldType do
      end

      defmodule ShadowString do
        use Kiln.FieldType
        def name, do: :string
        def cast(value, _definition), do: {:ok, value}
      end

      # The in-tree `Kiln.FieldType` implementations (#428/#429) are reserved
      # too: a plugin claiming one would shadow it in the registry.
      defmodule ShadowGeolocation do
        use Kiln.FieldType
        def name, do: :geolocation
        def cast(value, _definition), do: {:ok, value}
      end

      defmodule FieldTypePlugin do
        use Kiln.Plugin
        def field_types, do: [NotAFieldType, ShadowString, ShadowGeolocation]
      end

      Application.put_env(:kiln_cms, :plugins, [FieldTypePlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "does not implement Kiln.FieldType"
      assert error.message =~ "field type :string collides with a built-in field type"
      assert error.message =~ "field type :geolocation collides with a built-in field type"
    end

    # #1918: the fixture's `Lookup` type names a bundled colocated hook, so
    # "passes for the fixture plugin" above already covers the found case.
    test "flags a field type hook that was never bundled, and a malformed or raising input_hook/1" do
      defmodule UnbundledHookType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}

        def input_hook(_definition),
          do: %{hook: Kiln.FieldType.colocated_hook(__MODULE__, "Gone")}
      end

      defmodule MalformedHookType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}
        def input_hook(_definition), do: "NotAMap"
      end

      defmodule RaisingHookType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}
        def input_hook(_definition), do: raise("no hook for you")
      end

      defmodule HookPlugin do
        use Kiln.Plugin

        def field_types,
          do: [
            UnbundledHookType,
            MalformedHookType,
            RaisingHookType,
            KilnCMS.FixturePlugin.FieldTypes.Lookup
          ]
      end

      Application.put_env(:kiln_cms, :plugins, [HookPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ ~s(names hook "#{inspect(UnbundledHookType)}.Gone")
      assert error.message =~ "is not a bundled colocated hook"
      assert error.message =~ ~s(input_hook/1 returned "NotAMap")
      assert error.message =~ "raised while building its input_hook/1 (no hook for you)"
      refute error.message =~ "Lookup.Suggest"
    end

    # #2284: the fixture's `Rating` type declares well-formed widgets, so
    # "passes for the fixture plugin" above covers the clean case.
    test "flags a field type whose widgets/1 is malformed, repeats a name, or raises" do
      defmodule BadEntryWidgetsType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}
        def widgets(_definition), do: [:fine, "string_name", {:labelled, :not_a_string}, :BadName]
      end

      defmodule DuplicateWidgetsType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}
        def widgets(_definition), do: [:twice, {:twice, "Twice"}]
      end

      defmodule NotAListWidgetsType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}
        def widgets(_definition), do: :stars
      end

      defmodule RaisingWidgetsType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}
        def widgets(_definition), do: raise("no widgets for you")
      end

      defmodule EmptyWidgetsType do
        use Kiln.FieldType
        def cast(value, _definition), do: {:ok, value}
        def widgets(_definition), do: []
      end

      defmodule WidgetsPlugin do
        use Kiln.Plugin

        def field_types,
          do: [
            BadEntryWidgetsType,
            DuplicateWidgetsType,
            NotAListWidgetsType,
            RaisingWidgetsType,
            EmptyWidgetsType,
            KilnCMS.FixturePlugin.FieldTypes.Rating
          ]
      end

      Application.put_env(:kiln_cms, :plugins, [WidgetsPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ ~s(widgets/1 has entry "string_name")
      assert error.message =~ ~s(widgets/1 has entry {:labelled, :not_a_string})
      assert error.message =~ ~s(widgets/1 has entry :BadName)
      refute error.message =~ "entry :fine"
      assert error.message =~ ~s(widgets/1 names :twice more than once)
      assert error.message =~ "widgets/1 returned :stars"
      assert error.message =~ "raised while listing its widgets/1 (no widgets for you)"
      refute error.message =~ "empty_widgets_type"
      refute error.message =~ ":rating"
    end

    test "flags queue redefinitions and malformed paths" do
      defmodule RudePlugin do
        use Kiln.Plugin
        def oban_queues, do: [firing: 99]
        def nav_items, do: [%{label: "X", path: "editor/x", role: :admin}]
        def admin_routes, do: [{"/elsewhere", KilnCMS.FixturePlugin.PanelLive, :index}]
      end

      Application.put_env(:kiln_cms, :plugins, [RudePlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "redefines a core Oban queue"
      assert error.message =~ "must be absolute"
      assert error.message =~ "must live under /editor"
    end

    # #1955: `name/0` is written on every image a backend holds, so the doctor
    # holds it to the contract, and the selected backend to an installed plugin.
    test "flags image backends that break the contract, share a name, or aren't installed" do
      defmodule NotABackend do
        def name, do: "not_a_backend"
      end

      defmodule NamelessBackend do
        use Kiln.ImageBackend
        def name, do: ""
        def configured?, do: true
        def accepts?(_candidate), do: true
        def store(key, _path), do: {:ok, key}
        def fetch(_key), do: {:error, :enoent}
        def delete(_key), do: :ok
        def url(key), do: key
      end

      defmodule ImpostorBackend do
        use Kiln.ImageBackend
        def name, do: "fixture_images"
        def configured?, do: true
        def accepts?(_candidate), do: true
        def store(key, _path), do: {:ok, key}
        def fetch(_key), do: {:error, :enoent}
        def delete(_key), do: :ok
        def url(key), do: key
      end

      defmodule BackendPlugin do
        use Kiln.Plugin
        def image_backends, do: [NotABackend, NamelessBackend, ImpostorBackend]
      end

      problems =
        Mix.Tasks.Kiln.Plugins.Doctor.image_backend_problems(
          [KilnCMS.FixturePlugin, BackendPlugin],
          KilnCMS.Media.ImageBackendTest
        )

      assert Enum.any?(problems, &(&1 =~ "NotABackend does not implement Kiln.ImageBackend"))
      assert Enum.any?(problems, &(&1 =~ "NamelessBackend needs a name/0 of 1-64 characters"))
      assert Enum.any?(problems, &(&1 =~ ~s(name "fixture_images" is declared by more than one)))

      assert Enum.any?(
               problems,
               &(&1 =~ ":image_backend — KilnCMS.Media.ImageBackendTest does not")
             )

      # A real backend no plugin declares is reported as exactly that.
      assert [problem] =
               Mix.Tasks.Kiln.Plugins.Doctor.image_backend_problems([], ImpostorBackend)

      assert problem =~ "is not declared by any installed plugin"

      assert Mix.Tasks.Kiln.Plugins.Doctor.image_backend_problems(
               [KilnCMS.FixturePlugin],
               KilnCMS.FixturePlugin.ImageBackend
             ) == []
    end

    # #2249: the core turns verification off for a provider that fails the
    # contract; the doctor says so before deploy, and names the id collisions
    # the registry would resolve silently (a built-in always wins).
    test "flags challenge providers that break the contract, collide, or aren't installed" do
      defmodule NotAProvider do
        def id, do: "not_a_provider"
      end

      defmodule WildcardProvider do
        use Kiln.Challenge.Provider
        def id, do: "wildcard"
        def widget, do: %{script_url: "https://cdn.example/api.js", global: "w"}
        def csp_sources, do: %{script_src: ["https://*.example"], frame_src: [], connect_src: []}
        def verify(_token, _opts), do: {:error, :invalid}
      end

      defmodule ImpostorProvider do
        use Kiln.Challenge.Provider
        def id, do: "turnstile"
        def widget, do: %{script_url: "https://cdn.example/api.js", global: "t"}

        def csp_sources,
          do: %{script_src: ["https://cdn.example"], frame_src: [], connect_src: []}

        def verify(_token, _opts), do: {:error, :invalid}
      end

      defmodule TwinProvider do
        use Kiln.Challenge.Provider
        def id, do: "dep_fixture"
        def widget, do: %{script_url: "https://cdn.example/api.js", global: "t"}

        def csp_sources,
          do: %{script_src: ["https://cdn.example"], frame_src: [], connect_src: []}

        def verify(_token, _opts), do: {:error, :invalid}
      end

      defmodule ProviderPlugin do
        use Kiln.Plugin

        def challenge_providers,
          do: [
            NotAProvider,
            WildcardProvider,
            ImpostorProvider,
            TwinProvider,
            {WildcardProvider, []}
          ]
      end

      alias Mix.Tasks.Kiln.Plugins.Doctor

      problems = Doctor.challenge_provider_problems([KilnDepFixture.Plugin, ProviderPlugin], nil)

      assert Enum.any?(
               problems,
               &(&1 =~ "NotAProvider: " and &1 =~ "does not implement Kiln.Challenge.Provider")
             )

      assert Enum.any?(problems, &(&1 =~ ~s(WildcardProvider: csp_sources/0 script_src entry)))
      assert Enum.any?(problems, &(&1 =~ ~s(takes the id "turnstile", which is a built-in's)))
      assert Enum.any?(problems, &(&1 =~ ~s(id "dep_fixture" is declared by more than one)))

      # An entry that is not a module is named, not silently dropped.
      assert Enum.any?(
               problems,
               &(&1 =~
                   "challenge_providers/0 entry {Kiln.PluginsTest.WildcardProvider, []} is not a module")
             )

      # The operator's selection must be installed; a built-in always is.
      assert [problem] = Doctor.challenge_provider_problems([KilnDepFixture.Plugin], "nope")
      assert problem =~ ~s(CHALLENGE_PROVIDER names "nope")
      assert Doctor.challenge_provider_problems([KilnDepFixture.Plugin], "recaptcha") == []
      assert Doctor.challenge_provider_problems([KilnDepFixture.Plugin], "dep_fixture") == []
      assert Doctor.challenge_provider_problems([FixturePlugin], nil) == []
    end

    # #2252: the core drops a check that fails the contract, takes a `core.`
    # id or repeats another plugin's, with only a log line; the doctor says so
    # before deploy.
    test "flags security checks that break the contract, take a core id, or collide" do
      defmodule NotACheck do
        def id, do: "acme.not_a_check"
      end

      defmodule CoreSquatter do
        use Kiln.Security.Check
        def id, do: "core.transport"
        def title, do: "Transport"
        def scope, do: :deployment
        def run(_context), do: pass("ok")
      end

      defmodule TwinCheck do
        use Kiln.Security.Check
        def id, do: "dep_fixture.build_env"
        def title, do: "Twin"
        def scope, do: :site
        def run(_context), do: pass("ok")
      end

      defmodule BadScopeCheck do
        use Kiln.Security.Check
        def id, do: "acme.bad_scope"
        def title, do: "Bad scope"
        def scope, do: :galaxy
        def run(_context), do: pass("ok")
      end

      defmodule CheckPlugin do
        use Kiln.Plugin

        def security_checks,
          do: [NotACheck, CoreSquatter, TwinCheck, BadScopeCheck, {TwinCheck, []}]
      end

      defmodule BrokenCheckPlugin do
        use Kiln.Plugin
        def security_checks, do: :nope
      end

      defmodule ThrowingCheckPlugin do
        use Kiln.Plugin
        def security_checks, do: throw(:no_checks)
      end

      defmodule ExitingCheckPlugin do
        use Kiln.Plugin
        def security_checks, do: exit(:gone)
      end

      alias Mix.Tasks.Kiln.Plugins.Doctor

      problems =
        Doctor.security_check_problems([KilnDepFixture.Plugin, CheckPlugin, BrokenCheckPlugin])

      assert Enum.any?(
               problems,
               &(&1 =~ "NotACheck: " and &1 =~ "does not implement Kiln.Security.Check")
             )

      assert Enum.any?(problems, &(&1 =~ ~s(takes the id "core.transport", which is reserved)))
      assert Enum.any?(problems, &(&1 =~ ~s(id "dep_fixture.build_env" is declared by more)))
      assert Enum.any?(problems, &(&1 =~ "only kiln_dep_fixture's is shown"))
      assert Enum.any?(problems, &(&1 =~ "BadScopeCheck: scope/0 must return"))

      assert Enum.any?(
               problems,
               &(&1 =~ "security_checks/0 entry {Kiln.PluginsTest.TwinCheck, []}")
             )

      assert Enum.any?(problems, &(&1 =~ "security_checks/0 must return a list, got :nope"))

      # A throw or an exit is a reported problem, not a crashed doctor run.
      assert [thrown, exited] =
               Doctor.security_check_problems([ThrowingCheckPlugin, ExitingCheckPlugin])

      assert thrown =~ "security_checks/0 throw: :no_checks"
      assert exited =~ "security_checks/0 exit: :gone"

      assert Doctor.security_check_problems([KilnDepFixture.Plugin, FixturePlugin]) == []
    end

    # #937: `test/kiln/block/json_schema_test.exs` proves the *core* render/schema
    # agreement, but a hex-dep plugin never runs the core suite — this is the
    # only place a plugin's own `:json` render gets checked against what
    # `GET /api/schema` publishes for it.
    test "passes for a plugin block whose :json render matches its exported schema" do
      defmodule ConformantBlock do
        use Kiln.Block

        block :conformant do
          field :label, :string, required: true
        end

        @impl Kiln.Block.Renderer
        def render(block, :web), do: block.label || ""
        def render(block, :json), do: %{"_type" => "conformant", "label" => block.label}
        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: block.label || ""
      end

      defmodule ConformantBlockPlugin do
        use Kiln.Plugin
        def blocks, do: [ConformantBlock]
      end

      Application.put_env(:kiln_cms, :plugins, [ConformantBlockPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    test "flags a plugin block whose :json render adds a key its schema doesn't declare" do
      defmodule ComputedKeyBlock do
        use Kiln.Block

        block :computed_key do
          field :text, :string, required: true
        end

        # No `json_schema/0` patch declaring `"surprise"` — the exact #937 bug:
        # a computed render key with no field and no patch.
        @impl Kiln.Block.Renderer
        def render(block, :web), do: block.text || ""

        def render(block, :json),
          do: %{"_type" => "computed_key", "text" => block.text, "surprise" => "computed"}

        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: block.text || ""
      end

      defmodule ComputedKeyPlugin do
        use Kiln.Plugin
        def blocks, do: [ComputedKeyBlock]
      end

      Application.put_env(:kiln_cms, :plugins, [ComputedKeyPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end

      assert error.message =~
               "block :computed_key :json render disagrees with its exported schema"

      assert error.message =~ "undeclared property surprise"
    end

    # #937: `KilnCMS.CMS.FieldTypes.Recurrence` is the in-tree reason
    # `c:Kiln.FieldType.json_schema/1` exists — its widget is a text input but
    # `cast/2` stores a list. A plugin type in the same situation that never
    # declares the callback ships a schema `SchemaExport` infers wrong.
    test "flags a plugin field type whose cast/2 output diverges from its widget" do
      defmodule DivergentFieldType do
        use Kiln.FieldType
        # Default (unoverridden) widget is a plain text input — implies a
        # string — but this returns a list, same shape of bug as Recurrence.
        def cast(_value, _definition), do: {:ok, ["a", "b"]}
      end

      defmodule DivergentFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [DivergentFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [DivergentFieldPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "field type :divergent_field_type"
      assert error.message =~ "cast/2 returns array"
      assert error.message =~ "implies string"
      assert error.message =~ "c:Kiln.FieldType.json_schema/1"
    end

    test "passes for a plugin field type whose cast/2 output matches its widget" do
      defmodule ConformantFieldType do
        use Kiln.FieldType
        def input_type, do: "number"
        def cast(value, _definition), do: {:ok, String.to_integer(to_string(value))}
      end

      defmodule ConformantFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [ConformantFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [ConformantFieldPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    # A type that declares `json_schema/1` has already told `SchemaExport` its
    # real delivered shape, so the widget probe would be checking the wrong
    # thing — this proves the check skips it rather than false-positiving on
    # exactly the escape hatch #937 asks plugins to use.
    test "does not probe a field type that already declares json_schema/1" do
      defmodule SelfDescribingFieldType do
        use Kiln.FieldType
        def cast(_value, _definition), do: {:ok, ["a", "b"]}
        def json_schema(_definition), do: %{"type" => "array", "items" => %{"type" => "string"}}
      end

      defmodule SelfDescribingFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [SelfDescribingFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [SelfDescribingFieldPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    # Post-merge review of #937/PR #1251, finding 1: `for_module/1` (called by
    # `JsonSchema.defs/1`, in turn called by `block_schema_problems/2`) has no
    # rescue around a plugin block's own `json_schema/0` — unlike every other
    # call into plugin-authored code in this task. Without a guard, a plugin
    # whose `json_schema/0` raises takes the *entire* doctor run down instead
    # of being reported as that one plugin's own problem.
    test "flags a plugin block whose json_schema/0 raises without crashing the doctor run" do
      defmodule ExplodingSchemaBlock do
        use Kiln.Block

        block :exploding_schema do
          field :text, :string, required: true
        end

        @impl Kiln.Block.Renderer
        def render(block, :web), do: block.text || ""
        def render(block, :json), do: %{"_type" => "exploding_schema", "text" => block.text}
        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: block.text || ""

        @impl Kiln.Block.Renderer
        def json_schema, do: raise("boom")
      end

      defmodule ExplodingSchemaPlugin do
        use Kiln.Plugin
        def blocks, do: [ExplodingSchemaBlock]
      end

      Application.put_env(:kiln_cms, :plugins, [ExplodingSchemaPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end

      assert error.message =~ "ExplodingSchemaBlock"
      assert error.message =~ "json_schema/0 raised"
      assert error.message =~ "boom"
    end

    # Finding 4: the only pre-existing collision test reused the literal same
    # core module as the "plugin" block, which only exercises identity dedup
    # (`Enum.uniq/1` on the candidate list never even sees two entries for
    # `:heading`). This uses a genuinely distinct plugin module with a
    # different field shape, proving `block_schema_problems/2` resolves the
    # collision to the *plugin's own* schema — if it fell back to validating
    # against core Heading's schema (which has no `caption` property and
    # requires `text`), this plugin's conformant render would fail.
    test "a plugin block colliding with a core block's name still validates against its own schema" do
      defmodule DistinctHeadingBlock do
        use Kiln.Block

        block :heading do
          field :caption, :string, required: true
        end

        @impl Kiln.Block.Renderer
        def render(block, :web), do: block.caption || ""
        def render(block, :json), do: %{"_type" => "heading", "caption" => block.caption}
        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: block.caption || ""
      end

      defmodule DistinctHeadingPlugin do
        use Kiln.Plugin
        def blocks, do: [DistinctHeadingBlock]
      end

      Application.put_env(:kiln_cms, :plugins, [DistinctHeadingPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end

      assert error.message =~ "block :heading collides with a core block"
      refute error.message =~ "disagrees with its exported schema"
    end

    # Finding 2: when two *different* plugins declare a block with the same
    # `_type`, the shared `$defs` map only keeps one module's schema
    # (`JsonSchema.block_modules/1`'s `Enum.uniq_by/2`) — but the pre-fix
    # lookup in `block_render_problems/4` matched by name only, so the
    # "losing" plugin's render silently validated against the "winning"
    # plugin's unrelated schema. Both blocks here are internally conformant
    # (each matches its own derived schema) but have disjoint field shapes,
    # so any cross-validation between them fails loudly — this proves neither
    # gets checked against the other's schema.
    test "two different plugins declaring the same block name are not validated against each other's schema" do
      defmodule DuplicateBlockA do
        use Kiln.Block

        block :duplicated_block do
          field :alpha, :string, required: true
        end

        @impl Kiln.Block.Renderer
        def render(block, :web), do: block.alpha || ""
        def render(block, :json), do: %{"_type" => "duplicated_block", "alpha" => block.alpha}
        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: block.alpha || ""
      end

      defmodule DuplicateBlockB do
        use Kiln.Block

        block :duplicated_block do
          field :beta, :integer, required: true
        end

        @impl Kiln.Block.Renderer
        def render(block, :web), do: to_string(block.beta || 0)
        def render(block, :json), do: %{"_type" => "duplicated_block", "beta" => block.beta}
        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: to_string(block.beta || 0)
      end

      defmodule DuplicateBlockAPlugin do
        use Kiln.Plugin
        def blocks, do: [DuplicateBlockA]
      end

      defmodule DuplicateBlockBPlugin do
        use Kiln.Plugin
        def blocks, do: [DuplicateBlockB]
      end

      Application.put_env(:kiln_cms, :plugins, [DuplicateBlockAPlugin, DuplicateBlockBPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end

      assert error.message =~ "block :duplicated_block declared by multiple plugins"
      refute error.message =~ "block :duplicated_block :json render disagrees"
    end

    # Finding 3: `value_kind/1` classified every struct except the date/time
    # family as `"unknown"`, but `widget_kind/1` never returns `"unknown"` —
    # so any field type whose `cast/2` correctly returns another
    # JSON-encodable struct without declaring `json_schema/1` was
    # unconditionally flagged as diverging. `Decimal` is the common case
    # (currency/precision-sensitive amounts); `Jason.Encoder` renders it as a
    # JSON string, matching what the default text-input widget already
    # implies.
    test "does not false-positive on a field type whose cast/2 returns a Decimal" do
      defmodule DecimalFieldType do
        use Kiln.FieldType
        def cast(_value, _definition), do: {:ok, Decimal.new("3.14")}
      end

      defmodule DecimalFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [DecimalFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [DecimalFieldPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    # Same finding, the general case: a struct `value_kind/1` has no specific
    # clause for at all should be inconclusive rather than an automatic
    # mismatch — the doctor task cannot know it's wrong, only that it can't
    # classify it.
    test "does not flag an unrecognized struct return as a divergence" do
      defmodule OpaqueStructFieldType do
        use Kiln.FieldType
        def cast(_value, _definition), do: {:ok, URI.parse("https://example.com")}
      end

      defmodule OpaqueStructFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [OpaqueStructFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [OpaqueStructFieldPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    # Finding 5: every field-type-divergence test up to this point uses a
    # scalar field type — `composite_divergence/4`/`part_divergence/4` (the
    # `input_parts/1` branch, `KilnCMS.CMS.FieldTypes.Geolocation`'s shape)
    # had zero coverage. Covers the pass case, a per-part divergence, and the
    # "declares composite but cast/2 doesn't return a map" branch.
    test "passes for a composite field type whose parts all match their widgets" do
      defmodule ConformantCompositeFieldType do
        use Kiln.FieldType

        def input_parts(_definition) do
          [
            %{key: "amount", label: "Amount", type: "number"},
            %{key: "note", label: "Note", type: "text"}
          ]
        end

        def cast(_value, _definition), do: {:ok, %{"amount" => 3, "note" => "sample"}}
      end

      defmodule ConformantCompositeFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [ConformantCompositeFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [ConformantCompositeFieldPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    test "flags a composite field type whose part kind diverges from its part widget" do
      defmodule DivergentCompositeFieldType do
        use Kiln.FieldType

        def input_parts(_definition) do
          [
            %{key: "amount", label: "Amount", type: "number"},
            %{key: "note", label: "Note", type: "text"}
          ]
        end

        # `amount`'s widget is a number input (implies "number"), but this
        # returns a list — same shape of bug as the scalar case, on one part.
        def cast(_value, _definition), do: {:ok, %{"amount" => ["3"], "note" => "sample"}}
      end

      defmodule DivergentCompositeFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [DivergentCompositeFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [DivergentCompositeFieldPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "field type :divergent_composite_field_type"
      assert error.message =~ "cast/2 returns array"
      assert error.message =~ ~s(for part "amount")
      assert error.message =~ "implies number"
    end

    test "flags a composite field type whose cast/2 doesn't return an object" do
      defmodule NonObjectCompositeFieldType do
        use Kiln.FieldType

        def input_parts(_definition) do
          [%{key: "amount", label: "Amount", type: "number"}]
        end

        def cast(_value, _definition), do: {:ok, "just a string"}
      end

      defmodule NonObjectCompositeFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [NonObjectCompositeFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [NonObjectCompositeFieldPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "declares composite input_parts/1"
      assert error.message =~ "cast/2 returns string, not an object"
    end

    # Finding 6: three rescue clauses added during #937's own review-fix pass
    # had zero test coverage. Each fixture below is designed to raise at
    # exactly the point its rescue guards.
    test "flags a plugin block whose render/2 itself raises, not just json_schema/0" do
      defmodule ExplodingRenderBlock do
        use Kiln.Block

        block :exploding_render do
          field :text, :string, required: true
        end

        @impl Kiln.Block.Renderer
        def render(block, :web), do: block.text || ""
        def render(_block, :json), do: raise("kaboom")
        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: block.text || ""
      end

      defmodule ExplodingRenderPlugin do
        use Kiln.Plugin
        def blocks, do: [ExplodingRenderBlock]
      end

      Application.put_env(:kiln_cms, :plugins, [ExplodingRenderPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "ExplodingRenderBlock"
      assert error.message =~ "raised while checking its :json render against its schema"
      assert error.message =~ "kaboom"
    end

    test "flags a plugin field type whose cast/2 itself raises" do
      defmodule ExplodingCastFieldType do
        use Kiln.FieldType
        def cast(_value, _definition), do: raise("cast blew up")
      end

      defmodule ExplodingCastFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [ExplodingCastFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [ExplodingCastFieldPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "ExplodingCastFieldType"
      assert error.message =~ "raised while checking cast/2"
      assert error.message =~ "cast blew up"
    end

    test "does not crash when a plugin declares a non-atom field type entry" do
      defmodule NonAtomFieldTypePlugin do
        use Kiln.Plugin
        def field_types, do: ["not_a_module"]
      end

      Application.put_env(:kiln_cms, :plugins, [NonAtomFieldTypePlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "does not implement Kiln.FieldType"
    end

    # A synthetic `definition.options` used to always be `[]`, so a select-style
    # cast/2 that validates membership against it — the same pattern the core
    # `:select` custom field uses — always saw `{:error, _}` and was silently
    # exempted from the divergence check, hiding a real bug like this one.
    test "does not silently skip a field type whose cast/2 validates against definition.options" do
      defmodule SelectDivergentFieldType do
        use Kiln.FieldType

        def cast(value, %{options: options}) do
          if value in options,
            do: {:ok, [value]},
            else: {:error, "not one of #{inspect(options)}"}
        end
      end

      defmodule SelectDivergentFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [SelectDivergentFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [SelectDivergentFieldPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "field type :select_divergent_field_type"
      assert error.message =~ "cast/2 returns array"
      assert error.message =~ "implies string"
    end

    # `widget_sample/1` used to hand every non-numeric/checkbox widget the
    # literal "sample", which a real date parser rejects outright — the
    # divergence check never ran for a date-format type as a result.
    test "does not silently skip a field type whose cast/2 parses a real date format" do
      defmodule DateDivergentFieldType do
        use Kiln.FieldType
        def input_type, do: "date"

        def cast(value, _definition) do
          case Date.from_iso8601(value) do
            {:ok, date} -> {:ok, [Date.to_iso8601(date)]}
            {:error, _} = error -> error
          end
        end
      end

      defmodule DateDivergentFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [DateDivergentFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [DateDivergentFieldPlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "field type :date_divergent_field_type"
      assert error.message =~ "cast/2 returns array"
      assert error.message =~ "implies string"
    end

    # cast/2's contract only requires a JSON-native return — nothing requires
    # its composite map to use the exact string keys input_parts/1 declared,
    # and an atom-keyed return round-trips correctly through the real jsonb
    # write path (Jason stringifies atom keys on encode).
    test "accepts an atom-keyed composite cast/2 result" do
      defmodule AtomKeyedCompositeFieldType do
        use Kiln.FieldType
        def input_parts(_definition), do: [%{key: "lat", label: "Lat", type: "number"}]
        def cast(%{"lat" => lat}, _definition), do: {:ok, %{lat: String.to_integer(lat)}}
      end

      defmodule AtomKeyedCompositeFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [AtomKeyedCompositeFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [AtomKeyedCompositeFieldPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end

    # The synthetic probe definition used to leave content_type/type_definition_id
    # both nil — a state a real FieldDefinition never has — so a cast/2 that
    # reasonably reads definition.content_type (the same pattern the core
    # coerce_reference/3 uses) raised and was misreported as a plugin bug.
    test "does not crash the whole run on a field type whose cast/2 reads definition.content_type" do
      defmodule ContentTypeReadingFieldType do
        use Kiln.FieldType

        def cast(value, %{content_type: type}) when is_atom(type) and not is_nil(type) do
          {:ok, value}
        end
      end

      defmodule ContentTypeReadingFieldPlugin do
        use Kiln.Plugin
        def field_types, do: [ContentTypeReadingFieldType]
      end

      Application.put_env(:kiln_cms, :plugins, [ContentTypeReadingFieldPlugin])

      assert Mix.Tasks.Kiln.Plugins.Doctor.run([]) == :ok
    end
  end
end
