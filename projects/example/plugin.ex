defmodule Example.Plugin do
  @moduledoc """
  The fictional "Acme" company's **plugin** (decision D18) — the in-tree
  worked example of building on kiln_cms. Everything it layers on the core
  flows through the standard plugin seams and domain registration:

    * `Example.Catalog` — the content domain (products, team members,
      testimonials, FAQs), all built on `KilnCMS.CMS.Content`. Domains are
      declared here for `mix kiln.plugins.doctor` verification, and registered
      in the host config (`:ash_domains` + `:content_domains`), which is what
      actually activates them — the reusable core ships with this plugin
      dormant.
    * `Example.Blocks.Stat` / `Example.FieldTypes.Money` — a
      plugin-contributed block type and custom field type, the worked
      example of `c:blocks/0`/`c:field_types/0` extending the editor without
      a core edit.
    * `priv/repo/example_field_definitions.exs`,
      `example_dynamic_types.exs`, `example_import.exs`,
      `example_demo_config.exs` (under `projects/example/priv/repo/`) — the
      seed scripts that populate the demo, run in that order (plain scripts
      run with `mix run`; they need no plugin callbacks). See
      `projects/example/README.md` for what each demonstrates.

  Activate in a deployment's config (see `projects/example/project.exs`):

      config :kiln_cms,
        plugins: [Example.Plugin],
        ash_domains: [..., Example.Catalog],
        content_domains: [KilnCMS.CMS, Example.Catalog]
  """
  use Kiln.Plugin

  @impl true
  def name, do: "example"

  @impl true
  def domains, do: [Example.Catalog]

  @impl true
  def blocks, do: [Example.Blocks.Stat]

  @impl true
  def field_types, do: [Example.FieldTypes.Money]
end
