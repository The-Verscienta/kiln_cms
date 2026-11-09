defmodule Kiln.Plugin do
  @moduledoc """
  The KilnCMS **plugin contract** (decision D18, `docs/plugin-system-plan.md`).

  A plugin is compile-time OTP code — a `projects/<name>/` directory, or a Mix
  dependency (see below) — whose entry module `use`s this and overrides only
  the callbacks it needs. One config line activates it:

      config :kiln_cms, :plugins, [MyPlugin]

  ## What a plugin can contribute

    * `blocks/0` — `Kiln.Block` modules: joined into the block union, the
      editor palette, firing/search serialization, automatically.
    * `field_types/0` — `Kiln.FieldType` modules: custom-field value types
      admins can pick in the fields admin, coerced/validated by the plugin's
      `cast/2` on every content write.
    * `spam_checks/0` — `Kiln.Forms.SpamCheck` modules (#477): a plugin's own
      heuristic (or an external-provider check) run alongside the core scorer
      on every public form submission, appended after the core checks.
    * `image_backends/0` — `Kiln.ImageBackend` modules (#1955): an external
      image service (Cloudflare Images, imgix, …) that new image uploads can
      go to instead of the operator's store. Installing one changes nothing
      until the operator selects it
      (`config :kiln_cms, :image_backend, Module`).
    * `challenge_providers/0` — `Kiln.Challenge.Provider` modules
      (kiln_cms#2249): a human-verification widget and its check, offered
      beside the built-in Turnstile and reCAPTCHA. Installing one changes
      nothing until the operator names it (`CHALLENGE_PROVIDER`). Since 1.4.
    * `security_checks/0` — `Kiln.Security.Check` modules (kiln_cms#2252):
      lines on the console's Security posture page, run beside the core's own
      checks, each under its own deadline. Since 1.4.
    * `nav_items/0` — links in the admin top nav
      (`%{label: "...", path: "/editor/...", role: :editor | :admin}`).
    * `admin_routes/0` — LiveViews mounted in the admin-gated live session
      (`{"/editor/my-plugin", MyPlugin.PanelLive, :index}`).
    * `editor_routes/0` — LiveViews mounted in the editor-gated live session,
      for plugin surfaces org editors (not only admins) may use. Same route
      shape as `admin_routes/0`.
    * `public_routes/0` — anonymous LiveViews mounted in the browser
      pipeline BEFORE the content-delivery catch-alls (booking pages,
      signup flows). Same route shape; paths must not sit under `/editor`,
      `/api`, `/gql`, or `/mcp`, and shadow same-named content slugs.
    * `plug_routes/0` — controller-style routes and `forward`s to a Plug,
      mounted BEFORE the content-delivery catch-alls in a scope with no
      session, no CSRF check and no content negotiation (a JSON endpoint, a
      webhook receiver, a form handler, a feed variant). Paths must not sit
      under a core root (`/editor`, `/api`, `/gql`, `/mcp`, …); shadowing
      follows `public_routes/0`. See `t:plug_route/0`.
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
  behavior. Screenshots and long-form docs live in the plugin's own
  repository / README — `homepage/0` is the pointer to them, so the running
  node carries a URL, not a media library.

  ## As a Mix dependency, or as a `projects/` overlay

  This module ships in the `kiln_plugin` package (#1909), which the core
  depends on, so a plugin that depends on `{:kiln_plugin, "~> 1.0"}` can be a
  Hex, `git:` or `path:` dependency of a KilnCMS project. Mix compiles a
  dependency before the project that uses it, with only the dependency's own
  dependencies loaded, so what a dependency plugin can contribute is what it
  can build from this package alone:

    * blocks, field types, spam checks, advisory checks, image backends,
      human-verification providers and security posture checks;
    * nav items, supervision children and Oban queues;
    * routes, but only to a LiveView that depends on `phoenix_live_view`
      directly — one that does `use KilnCMSWeb, :live_view` needs the core.

  A plugin that defines content types (`use KilnCMS.CMS.Content`) or Ash
  domains, uses `KilnCMSWeb`, or gives a field type a colocated client hook
  has to be a `projects/<name>/` overlay, which is compiled inside the core.
  A site installs a dependency plugin through its overlay's
  `config/project_deps.exs`, never the core's `mix.exs`; see
  `docs/plugin-extensibility.md`.
  """

  @type nav_item :: %{label: String.t(), path: String.t(), role: :editor | :admin}
  @type admin_route :: {path :: String.t(), live_view :: module(), action :: atom()}

  @typedoc """
  A route to a plain Plug, for `c:plug_routes/0`:

    * `{verb, path, plug_module, plug_opts}` — `verb` is `:get`, `:post`,
      `:put`, `:patch`, `:delete` or `:match` (any method). A Phoenix
      controller is a Plug whose `plug_opts` is the action atom, so
      `{:post, "/hooks/ping", MyPlugin.PingController, :create}` works with no
      dependency on Phoenix in this package. `:get` also answers `HEAD`.
    * `{:forward, path, plug_module, plug_opts}` — hands every request under
      `path` to the Plug (a `Plug.Router`, say), with `path` stripped.

  `plug_opts` must survive `Macro.escape/1` (atoms, strings, numbers, lists,
  keyword lists, maps of those): it is baked into the router at compile time.
  """
  @type plug_route ::
          {:get | :post | :put | :patch | :delete | :match, path :: String.t(), plug :: module(),
           plug_opts :: term()}
          | {:forward, path :: String.t(), plug :: module(), plug_opts :: term()}

  @doc "Machine name (used in diagnostics). Defaults to the module's last segment."
  @callback name() :: String.t()

  @doc "Version string for the catalog/`mix kiln.plugins.list`. Defaults to `nil`."
  @callback version() :: String.t() | nil

  @doc "One-line catalog description. Defaults to `nil`."
  @callback summary() :: String.t() | nil

  @doc "Repo/docs URL — where screenshots and docs live. Defaults to `nil`."
  @callback homepage() :: String.t() | nil

  @callback domains() :: [module()]
  @callback blocks() :: [module()]
  @callback field_types() :: [module()]
  @callback advisories() :: [module()]
  @callback spam_checks() :: [module()]
  @callback image_backends() :: [module()]
  @callback challenge_providers() :: [module()]

  @doc """
  `Kiln.Security.Check` modules shown on the Security posture page. Defaults
  to `[]`. Since 1.4.
  """
  @callback security_checks() :: [module()]
  @callback nav_items() :: [nav_item()]
  @callback admin_routes() :: [admin_route()]
  @callback editor_routes() :: [admin_route()]
  @callback public_routes() :: [admin_route()]
  @callback plug_routes() :: [plug_route()]
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
      def advisories, do: []

      @impl Kiln.Plugin
      def spam_checks, do: []

      @impl Kiln.Plugin
      def image_backends, do: []

      @impl Kiln.Plugin
      def challenge_providers, do: []

      @impl Kiln.Plugin
      def security_checks, do: []

      @impl Kiln.Plugin
      def nav_items, do: []

      @impl Kiln.Plugin
      def admin_routes, do: []

      @impl Kiln.Plugin
      def editor_routes, do: []

      @impl Kiln.Plugin
      def public_routes, do: []

      @impl Kiln.Plugin
      def plug_routes, do: []

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
                     advisories: 0,
                     spam_checks: 0,
                     image_backends: 0,
                     challenge_providers: 0,
                     security_checks: 0,
                     nav_items: 0,
                     admin_routes: 0,
                     editor_routes: 0,
                     public_routes: 0,
                     plug_routes: 0,
                     children: 0,
                     oban_queues: 0
    end
  end
end
