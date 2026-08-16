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
  end
end
