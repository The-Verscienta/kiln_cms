defmodule KilnPluginCallout do
  @moduledoc """
  Example third-party KilnCMS plugin (issue #63). Contributes the `callout`
  block to a host KilnCMS application.

  Install in the host app's config:

      config :kiln_cms, plugins: [KilnPluginCallout]

  The block then appears in the editor's block inserter and renders through the
  same pipeline as built-in blocks.
  """
  use KilnCMS.Plugin

  @impl true
  def name, do: "Callout"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def blocks, do: [KilnPluginCallout.Blocks.Callout]
end
