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
             FixturePlugin.RestrictedRequiredDefaultBlock
           ]

    # Rating is the one with real behaviour; Tokenless and Exploding exist to
    # cover `type_token_definitions/1`'s probe and rescue branches (#804), which
    # no CORE field type can reach.
    assert manifest.field_types == [
             FixturePlugin.FieldTypes.Rating,
             FixturePlugin.FieldTypes.Tokenless,
             FixturePlugin.FieldTypes.Exploding
           ]

    assert manifest.nav_items == 1
    assert manifest.admin_routes == 1
    assert manifest.oban_queues == [fixture: 1]
    assert manifest.children == 1
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
      assert output =~ "3 blocks, 3 field types, 1 nav item, 1 admin route"
    end

    test "the contribution summary counts every route kind" do
      # The fixture declares only an admin route, so the editor- and
      # public-route seams are covered here instead: a plugin whose whole
      # surface is a public booking page must not read as contributing nothing.
      line =
        Mix.Tasks.Kiln.Plugins.List.format(%{
          module: Booking.Plugin,
          name: "booking",
          version: nil,
          summary: nil,
          homepage: nil,
          domains: [],
          blocks: [],
          field_types: [],
          nav_items: 0,
          admin_routes: 0,
          editor_routes: 1,
          public_routes: 2,
          oban_queues: [],
          children: 0
        })

      assert line ==
               "* booking — Booking.Plugin\n    contributes: 1 editor route, 2 public routes"
    end
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
