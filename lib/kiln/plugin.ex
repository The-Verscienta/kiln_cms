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
  """

  @type nav_item :: %{label: String.t(), path: String.t(), role: :editor | :admin}
  @type admin_route :: {path :: String.t(), live_view :: module(), action :: atom()}

  @doc "Machine name (used in diagnostics). Defaults to the module's last segment."
  @callback name() :: String.t()

  @callback domains() :: [module()]
  @callback blocks() :: [module()]
  @callback nav_items() :: [nav_item()]
  @callback admin_routes() :: [admin_route()]
  @callback children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  @callback oban_queues() :: keyword(pos_integer())

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.Plugin

      @impl Kiln.Plugin
      def name, do: __MODULE__ |> Module.split() |> List.last() |> Macro.underscore()

      @impl Kiln.Plugin
      def domains, do: []

      @impl Kiln.Plugin
      def blocks, do: []

      @impl Kiln.Plugin
      def nav_items, do: []

      @impl Kiln.Plugin
      def admin_routes, do: []

      @impl Kiln.Plugin
      def children, do: []

      @impl Kiln.Plugin
      def oban_queues, do: []

      defoverridable name: 0,
                     domains: 0,
                     blocks: 0,
                     nav_items: 0,
                     admin_routes: 0,
                     children: 0,
                     oban_queues: 0
    end
  end
end
