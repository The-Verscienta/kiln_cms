# Plugin / module system

Stretch issue #63. KilnCMS has a registry-driven block system: in-app blocks
(`use Kiln.Block`) are auto-discovered from the application and drive the editor
inserter, render dispatch, and search-text projection. The plugin system extends
that registry to **external packages**, so a third party can ship new block types
(and, in future, more) without modifying KilnCMS.

## Registries

| Registry | What it holds | Source |
|----------|---------------|--------|
| [`KilnCMS.Blocks`](../lib/kiln_cms/blocks.ex) | All block modules + serializer dispatch | In-app `Kiln.Block` modules **plus** plugin blocks |
| [`KilnCMS.Plugins`](../lib/kiln_cms/plugins.ex) | Installed plugins and their extensions | The `:plugins` config list |

`KilnCMS.Blocks.modules/0` merges the in-app blocks with
`KilnCMS.Plugins.block_modules/0` (deduped), so a plugin block is a first-class
citizen everywhere blocks are used.

## Defining a plugin

A plugin is its own package whose module implements
[`KilnCMS.Plugin`](../lib/kiln_cms/plugin.ex):

```elixir
defmodule KilnPluginCallout do
  use KilnCMS.Plugin

  @impl true
  def name, do: "Callout"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def blocks, do: [KilnPluginCallout.Blocks.Callout]
end
```

`use KilnCMS.Plugin` provides defaults (`name` from the module, `version`
`"0.0.0"`, `blocks` `[]`) so a plugin overrides only what it provides.

Each contributed block is an ordinary `Kiln.Block`:

```elixir
defmodule KilnPluginCallout.Blocks.Callout do
  use Kiln.Block

  block :callout do
    field :title, :string
    field :body, :string, required: true
    field :variant, :string, default: "info"
  end

  def render(%__MODULE__{} = b, :web), do: # ...
  def search_text(%__MODULE__{} = b), do: # ...
end
```

A full, runnable example package lives at
[`examples/kiln-plugin-callout`](../examples/kiln-plugin-callout) — use it as a
template.

## Installing a plugin

In the host app:

```elixir
# mix.exs
{:kiln_plugin_callout, "~> 1.0"}

# config/config.exs
config :kiln_cms, plugins: [KilnPluginCallout]
```

After `mix deps.get && mix compile`, the plugin's blocks appear in the editor's
block inserter and render through the standard pipeline. The registry validates
that each contributed block is a real `Kiln.Block` and silently ignores anything
that isn't, so a misconfigured plugin can't inject an arbitrary module.

`KilnCMS.Plugins.info/0` returns `%{module, name, version, blocks}` per installed
plugin — useful for an admin "installed plugins" view.

## Scope & roadmap

- **Today:** plugins contribute **block types** — the most common third-party
  extension. The `KilnCMS.Plugin` behaviour is the seam for more.
- **Storage note:** plugin blocks render, edit, and serialize through the
  registry. The persisted `Ash.Type.Union` of built-in block members is
  compile-time; content authored with a plugin block whose package is later
  removed falls back to the `custom` block so delivery never breaks (decision
  A4 — see `KilnCMS.CMS.TypedBlocks`).
- **Future extension points** (resources, LiveView hooks, API extensions) can be
  added as new `KilnCMS.Plugin` callbacks and corresponding registry merges,
  following the block pattern. A marketplace / git-based discovery layer would
  build on this registry.
