defmodule Kiln.Plugins do
  @moduledoc """
  The registry over installed `Kiln.Plugin`s (decision D18).

  Reads `config :kiln_cms, :plugins` at **compile time** — the block union
  and the router expand plugin contributions during compilation, so the list
  must be static per build (which also keeps D4's compile-time-safety stance:
  no runtime module loading).
  """

  @plugins Application.compile_env(:kiln_cms, :plugins, [])

  # Recompile when a configured plugin's contributions change, not only when
  # the list does — see `Kiln.Plugins.CompileEdges`.
  require Kiln.Plugins.CompileEdges
  Kiln.Plugins.CompileEdges.call_configured()

  # That compile-time edge only works for a plugin compiled in the same
  # project (`projects/`). Mix does not track compile-time edges into a
  # dependency's modules, so an edit to a plugin shipped as a `path:`
  # dependency (#1909) recompiled the plugin and left this module, and every
  # registry baked from it, on the old `blocks/0`. `__mix_recompile__?/0` is
  # Mix's hook for exactly that: it is asked before each compile, and `true`
  # recompiles this module and its compile-time dependents.
  @contributions_digest Kiln.Plugins.CompileEdges.digest(@plugins)

  @doc false
  def __mix_recompile__?,
    do: Kiln.Plugins.CompileEdges.digest(@plugins) != @contributions_digest

  @doc "The installed plugin modules, in registration order."
  @spec all() :: [module()]
  def all, do: @plugins

  @doc "Every plugin-contributed `Kiln.Block` module."
  @spec blocks() :: [module()]
  def blocks, do: Enum.flat_map(all(), & &1.blocks())

  @doc "Every plugin-contributed `Kiln.FieldType` module."
  @spec field_types() :: [module()]
  def field_types, do: Enum.flat_map(all(), & &1.field_types())

  @doc """
  Advisory checks contributed by plugins (`Kiln.Advisory`), appended after the
  core ones so a plugin can add advice without reordering it.
  """
  def advisories, do: Enum.flat_map(all(), & &1.advisories())

  @doc """
  Spam checks contributed by plugins (`Kiln.Forms.SpamCheck`, #477), appended
  after the core scorer's checks the same way `advisories/0` is.
  """
  def spam_checks, do: Enum.flat_map(all(), & &1.spam_checks())

  @doc """
  Image backends contributed by plugins (`Kiln.ImageBackend`, #1955). Which
  one new uploads use is the operator's choice — see
  `Kiln.ImageBackend.Registry`.
  """
  @spec image_backends() :: [module()]
  def image_backends, do: Enum.flat_map(all(), & &1.image_backends())

  @doc """
  Human-verification providers contributed by plugins (`Kiln.Challenge.Provider`,
  #2249). Which one is used is the operator's choice (`CHALLENGE_PROVIDER`) —
  see `KilnCMS.Challenge.Registry`. A plugin compiled against a `kiln_plugin`
  older than 1.4 has no such callback and contributes none.
  """
  @spec challenge_providers() :: [module()]
  def challenge_providers, do: KilnCMS.Challenge.Registry.plugin_providers()

  @doc """
  Security posture checks contributed by plugins (`Kiln.Security.Check`,
  #2252), run on the Security posture page beside the core's own — see
  `KilnCMS.Security.Posture.Registry`. A plugin compiled against a
  `kiln_plugin` older than 1.4 has no such callback and contributes none.
  """
  @spec security_checks() :: [module()]
  def security_checks, do: KilnCMS.Security.Posture.Registry.plugin_checks()

  @doc "Every plugin-declared admin nav item."
  @spec nav_items() :: [Kiln.Plugin.nav_item()]
  def nav_items, do: Enum.flat_map(all(), & &1.nav_items())

  @doc "Every plugin-declared admin route."
  @spec admin_routes() :: [Kiln.Plugin.admin_route()]
  def admin_routes, do: Enum.flat_map(all(), & &1.admin_routes())

  @doc "Every plugin-declared editor route."
  @spec editor_routes() :: [Kiln.Plugin.admin_route()]
  def editor_routes, do: Enum.flat_map(all(), & &1.editor_routes())

  @doc "Every plugin-declared public route."
  @spec public_routes() :: [Kiln.Plugin.admin_route()]
  def public_routes, do: Enum.flat_map(all(), & &1.public_routes())

  @doc """
  Every plugin-declared plug route (`c:Kiln.Plugin.plug_routes/0`, #2272). A
  plugin compiled against a `kiln_plugin` older than 1.4 has no such callback
  and contributes none.
  """
  @spec plug_routes() :: [Kiln.Plugin.plug_route()]
  def plug_routes, do: Enum.flat_map(all(), &Kiln.Plugins.PlugRoute.of/1)

  @doc "Every plugin supervision child, appended to the app tree at boot."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children, do: Enum.flat_map(all(), & &1.children())

  @doc "Plugin Oban queues, merged into the core queue config at boot."
  @spec oban_queues() :: keyword(pos_integer())
  def oban_queues do
    Enum.reduce(all(), [], fn plugin, acc ->
      Keyword.merge(acc, plugin.oban_queues())
    end)
  end

  @typedoc """
  The plain-data catalog view of one installed plugin — its declared metadata
  plus its contribution surface. Rendered by `mix kiln.plugins.list` and the
  natural shape for a marketplace UI (see `docs/plugin-extensibility.md`).
  """
  @type manifest :: %{
          module: module(),
          name: String.t(),
          version: String.t() | nil,
          summary: String.t() | nil,
          homepage: String.t() | nil,
          domains: [module()],
          blocks: [module()],
          field_types: [module()],
          advisories: [module()],
          spam_checks: [module()],
          image_backends: [module()],
          challenge_providers: [module()],
          security_checks: [module()],
          nav_items: non_neg_integer(),
          admin_routes: non_neg_integer(),
          editor_routes: non_neg_integer(),
          public_routes: non_neg_integer(),
          plug_routes: non_neg_integer(),
          oban_queues: keyword(pos_integer()),
          children: non_neg_integer()
        }

  @doc """
  The catalog/registry view: one `t:manifest/0` per installed plugin, in
  registration order. Metadata (`version`/`summary`/`homepage`) is whatever the
  plugin declares (`nil` if it declares nothing); contributions are read from
  the same callbacks the seams use.
  """
  @spec manifests() :: [manifest()]
  def manifests, do: Enum.map(all(), &manifest/1)

  @spec manifest(module()) :: manifest()
  defp manifest(plugin) do
    %{
      module: plugin,
      name: plugin.name(),
      version: plugin.version(),
      summary: plugin.summary(),
      homepage: plugin.homepage(),
      domains: plugin.domains(),
      blocks: plugin.blocks(),
      field_types: plugin.field_types(),
      advisories: plugin.advisories(),
      spam_checks: plugin.spam_checks(),
      image_backends: plugin.image_backends(),
      challenge_providers: KilnCMS.Challenge.Registry.of_plugin(plugin),
      security_checks: KilnCMS.Security.Posture.Registry.of_plugin(plugin),
      nav_items: length(plugin.nav_items()),
      admin_routes: length(plugin.admin_routes()),
      editor_routes: length(plugin.editor_routes()),
      public_routes: length(plugin.public_routes()),
      plug_routes: length(Kiln.Plugins.PlugRoute.of(plugin)),
      oban_queues: plugin.oban_queues(),
      children: length(plugin.children())
    }
  end
end
