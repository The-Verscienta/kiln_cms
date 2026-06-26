# kiln_plugin_callout — example KilnCMS plugin

A minimal, third-party **KilnCMS plugin package** (issue #63) that contributes a
custom `callout` block. Use it as a template for your own plugins.

## What it shows

- A `Kiln.Block` defined in a *separate* package
  ([`KilnPluginCallout.Blocks.Callout`](lib/kiln_plugin_callout/blocks/callout.ex)) —
  a titled, variant-styled aside.
- A `KilnCMS.Plugin` implementation
  ([`KilnPluginCallout`](lib/kiln_plugin_callout.ex)) that registers the block.

## Install in a host KilnCMS app

1. Add the dependency (Hex, git, or path) in the host's `mix.exs`:

   ```elixir
   {:kiln_plugin_callout, "~> 1.0"}
   # or, during development:
   {:kiln_plugin_callout, path: "../kiln_plugin_callout"}
   ```

2. Enable the plugin in the host's config:

   ```elixir
   # config/config.exs
   config :kiln_cms, plugins: [KilnPluginCallout]
   ```

3. `mix deps.get && mix compile`. The `callout` block now appears in the editor's
   block inserter and renders through the standard KilnCMS pipeline.

## How it works

`KilnCMS.Plugins` reads `config :kiln_cms, :plugins`, collects each plugin's
`blocks/0`, and `KilnCMS.Blocks` merges them into the block registry — the same
registry that drives the editor inserter, render dispatch, and search-text
projection. See [`docs/plugins.md`](../../docs/plugins.md) in the host repo for
the full extension model.

## Writing your own

```elixir
defmodule MyPlugin do
  use KilnCMS.Plugin

  @impl true
  def name, do: "My Plugin"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def blocks, do: [MyPlugin.Blocks.SomeBlock]
end
```

Each block is an ordinary `use Kiln.Block` module — see the callout block for the
shape.
