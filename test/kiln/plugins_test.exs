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

  test "the registry reflects the installed plugin" do
    assert FixturePlugin in Kiln.Plugins.all()
    assert FixturePlugin.CalloutBlock in Kiln.Plugins.blocks()
    assert Kiln.Plugins.oban_queues() == [fixture: 1]

    assert [%{label: "Fixture", path: "/editor/fixture", role: :admin}] =
             Kiln.Plugins.nav_items()
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

  describe "the Verscienta retrofit (the plan's 'first plugin/consumer')" do
    test "Verscienta is an installed plugin declaring its catalog domain" do
      assert Verscienta.Plugin in Kiln.Plugins.all()
      assert Verscienta.Plugin.name() == "verscienta"
      assert Verscienta.Plugin.domains() == [Verscienta.Catalog]
      # Its domains are registered where the doctor demands (test config).
      assert Verscienta.Catalog in Application.get_env(:kiln_cms, :ash_domains)
      assert Verscienta.Catalog in Application.get_env(:kiln_cms, :content_domains)
    end
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

      defmodule FieldTypePlugin do
        use Kiln.Plugin
        def field_types, do: [NotAFieldType, ShadowString]
      end

      Application.put_env(:kiln_cms, :plugins, [FieldTypePlugin])

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Kiln.Plugins.Doctor.run([]) end
      assert error.message =~ "does not implement Kiln.FieldType"
      assert error.message =~ "field type :string collides with a core field type"
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
  end
end
