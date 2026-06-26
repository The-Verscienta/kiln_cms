defmodule KilnCMS.PluginsTest do
  @moduledoc """
  The plugin registry aggregates blocks from configured plugins and feeds them
  into the block registry (issue #63).
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Plugins
  alias KilnCMS.TestSupport.{BadPlugin, ExamplePlugin}

  setup do
    original = Application.get_env(:kiln_cms, :plugins)
    on_exit(fn -> Application.put_env(:kiln_cms, :plugins, original) end)
    :ok
  end

  test "no plugins configured by default" do
    Application.put_env(:kiln_cms, :plugins, [])
    assert Plugins.all() == []
    assert Plugins.block_modules() == []
  end

  test "lists configured plugins and their metadata" do
    Application.put_env(:kiln_cms, :plugins, [ExamplePlugin])

    assert Plugins.all() == [ExamplePlugin]

    assert [%{module: ExamplePlugin, name: "Example", version: "9.9.9", blocks: [_]}] =
             Plugins.info()
  end

  test "block_modules returns plugin-contributed blocks, filtering non-blocks" do
    Application.put_env(:kiln_cms, :plugins, [ExamplePlugin, BadPlugin])

    blocks = Plugins.block_modules()
    assert KilnCMS.Blocks.Quote in blocks
    # BadPlugin contributed a non-block module, which must be filtered out.
    refute KilnCMS.AI in blocks
  end

  test "ignores configured modules that aren't plugins" do
    Application.put_env(:kiln_cms, :plugins, [KilnCMS.AI, ExamplePlugin])
    assert Plugins.all() == [ExamplePlugin]
  end

  test "KilnCMS.Blocks.modules merges plugin blocks (deduped)" do
    Application.put_env(:kiln_cms, :plugins, [ExamplePlugin])

    mods = KilnCMS.Blocks.modules()
    assert KilnCMS.Blocks.Quote in mods
    # Quote is also auto-discovered in-app; the merge must not duplicate it.
    assert Enum.count(mods, &(&1 == KilnCMS.Blocks.Quote)) == 1
  end
end
