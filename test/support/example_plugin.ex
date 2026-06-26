defmodule KilnCMS.TestSupport.ExamplePlugin do
  @moduledoc false
  # Returns an existing block module so the test exercises the plugin-merge path
  # without registering a brand-new block that would leak into the global block
  # registry for every other test.
  use KilnCMS.Plugin

  @impl true
  def name, do: "Example"

  @impl true
  def version, do: "9.9.9"

  @impl true
  def blocks, do: [KilnCMS.Blocks.Quote]
end

defmodule KilnCMS.TestSupport.BadPlugin do
  @moduledoc false
  # Contributes a module that is NOT a Kiln block — the registry must filter it.
  use KilnCMS.Plugin

  @impl true
  def blocks, do: [KilnCMS.AI]
end
