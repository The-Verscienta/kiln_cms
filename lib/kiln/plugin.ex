defmodule Kiln.Plugin do
  @moduledoc """
  The KilnCMS **plugin contract** (decision D18, `docs/plugin-system-plan.md`).

  A plugin is compile-time OTP code — a hex dependency or a `projects/`
  directory — whose entry module `use`s this and overrides only the callbacks
  it needs. One config line activates it:

      config :kiln_cms, :plugins, [MyPlugin]

  ## What a plugin can contribute

    * `blocks/0` — `Kiln.Block` modules: joined into the block union, the
      editor palette, firing/search serialization, automatically.
    * `field_types/0` — `Kiln.FieldType` modules: custom-field value types
      admins can pick in the fields admin, coerced/validated by the plugin's
      `cast/2` on every content write.
    * `nav_items/0` — links in the admin top nav
      (`%{label: "...", path: "/editor/...", role: :editor | :admin}`).
    * `admin_routes/0` — LiveViews mounted in the admin-gated live session
      (`{"/editor/my-plugin", MyPlugin.PanelLive, :index}`).
    * `children/0` — supervision child specs appended to the app tree.
    * `oban_queues/0` — background queues merged into the Oban config at
      boot (`[my_queue: 3]`).
    * `domains/0` — the plugin's Ash domains. These are **documentation +
      verification**, not auto-wiring: Ash's own mix tasks read
      `:ash_domains`/`:content_domains` straight from config, so the plugin's
      install step must add them there — `mix kiln.plugins.doctor` fails
      loudly when a declared domain is missing from either list.

  Content types, admin CRUD, webhook events, delivery routes and Oban
  workers need no plugin callbacks at all — they flow from the registered
  domains through the existing registries.

  ## Catalog metadata

  A plugin may also carry cheap, declarative **catalog metadata** —
  `version/0`, `summary/0`, `homepage/0` — surfaced by
  `Kiln.Plugins.manifests/0` and `mix kiln.plugins.list` (see
  `docs/plugin-extensibility.md`). All three are optional and default to
  `nil`: they are the "registry" for the vetted-plugin marketplace, not
  behavior. Screenshots and long-form docs live in the plugin's own hex
  package / README — `homepage/0` is the pointer to them, so the running node
  carries a URL, not a media library.
  """

  @type nav_item :: %{label: String.t(), path: String.t(), role: :editor | :admin}
  @type admin_route :: {path :: String.t(), live_view :: module(), action :: atom()}

  @doc "Machine name (used in diagnostics). Defaults to the module's last segment."
  @callback name() :: String.t()

  @doc "Version string for the catalog/`mix kiln.plugins.list`. Defaults to `nil`."
  @callback version() :: String.t() | nil

  @doc "One-line catalog description. Defaults to `nil`."
  @callback summary() :: String.t() | nil

  @doc "Hexdocs/repo URL — where screenshots and docs live. Defaults to `nil`."
  @callback homepage() :: String.t() | nil

  @callback domains() :: [module()]
  @callback blocks() :: [module()]
  @callback field_types() :: [module()]
  @callback nav_items() :: [nav_item()]
  @callback admin_routes() :: [admin_route()]
  @callback children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  @callback oban_queues() :: keyword(pos_integer())

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.Plugin

      @impl Kiln.Plugin
      def name do
        # `MyThing.Plugin` → "my_thing" (a trailing `Plugin` segment names the
        # convention, not the plugin).
        case __MODULE__ |> Module.split() |> Enum.reverse() do
          ["Plugin", parent | _] -> Macro.underscore(parent)
          [last | _] -> Macro.underscore(last)
        end
      end

      @impl Kiln.Plugin
      def version, do: nil

      @impl Kiln.Plugin
      def summary, do: nil

      @impl Kiln.Plugin
      def homepage, do: nil

      @impl Kiln.Plugin
      def domains, do: []

      @impl Kiln.Plugin
      def blocks, do: []

      @impl Kiln.Plugin
      def field_types, do: []

      @impl Kiln.Plugin
      def nav_items, do: []

      @impl Kiln.Plugin
      def admin_routes, do: []

      @impl Kiln.Plugin
      def children, do: []

      @impl Kiln.Plugin
      def oban_queues, do: []

      defoverridable name: 0,
                     version: 0,
                     summary: 0,
                     homepage: 0,
                     domains: 0,
                     blocks: 0,
                     field_types: 0,
                     nav_items: 0,
                     admin_routes: 0,
                     children: 0,
                     oban_queues: 0
    end
  end
end
