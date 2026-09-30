defmodule KilnCMSWeb.DevAssets do
  @moduledoc """
  Makes a stale or failed local asset build visible in development (#1761).

  `mix phx.server` in dev serves `priv/static/assets/` and rebuilds it through
  the Tailwind and esbuild watchers. When a watcher dies — macOS killing a
  downloaded Tailwind binary whose signature it no longer trusts (exit 137), a
  missing `assets/node_modules` — the server still boots, and the browser is
  handed whatever was left on disk. A stylesheet built before a layout token
  such as `--side-w` existed collapses the console (#1755), which reads as a
  product bug rather than a build problem.

  So a dev boot starts a one-shot check. It waits out a grace period long
  enough for the watchers' first build, then looks at what is on disk:

    * a missing stylesheet or script bundle;
    * a stylesheet that lacks a custom property `assets/css/app.css` declares
      — the build predates the source. Content, not timestamps: Tailwind does
      not rewrite an output that comes out identical, so a touched or
      comment-only-edited source is newer than a perfectly good build.
      `@theme` blocks are left out, since Tailwind may drop a theme variable
      nothing uses;
    * a missing `assets/node_modules`, without which the editor bundle cannot
      build.

  Anything it finds is logged as a warning with the recovery command, and
  `problems/0` hands it to the console layout, which draws a dev-only banner
  (`KilnCMSWeb.Layouts.dev_assets_banner/1`) — styled inline, since the
  stylesheet is the thing that may be wrong.

  Only a dev build has any of this. The switch is `Mix.env/0` read at compile
  time, so in every other build `start_link/1` returns `:ignore` and
  `problems/0` is a constant `[]`: no timer, no file reads.
  """

  require Logger

  @enabled Mix.env() == :dev
  @root Path.expand("../..", __DIR__)
  @key {__MODULE__, :problems}

  @typedoc "One thing wrong with the local asset build."
  @type problem ::
          {:missing, Path.t()}
          | {:stale, built :: Path.t(), missing_tokens :: [String.t()]}
          | :no_node_modules

  @doc "Whether this build carries the check at all (a dev build only)."
  @spec enabled?() :: boolean()
  def enabled?, do: @enabled

  @doc "The supervisor child for the delayed boot check."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()} | :ignore
  if @enabled do
    def start_link(opts) do
      grace = Keyword.get(opts, :grace, :timer.seconds(20))
      root = Keyword.get(opts, :root, @root)

      Task.start_link(fn ->
        Process.sleep(grace)
        report(check(root))
      end)
    end
  else
    def start_link(_opts), do: :ignore
  end

  @doc """
  What the last boot check found. Always `[]` outside a dev build, and `[]`
  until the check has run.
  """
  @spec problems() :: [problem()]
  if @enabled do
    def problems, do: :persistent_term.get(@key, [])
  else
    def problems, do: []
  end

  @doc """
  Inspects the asset build under `root`, the project root. Reads files and
  nothing else, so it can be pointed at a scratch directory.
  """
  # `root` is the project root fixed at compile time (or a test's scratch
  # directory), joined with constant paths — never request input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec check(Path.t()) :: [problem()]
  def check(root) do
    css_source = Path.join(root, "assets/css/app.css")
    css_built = Path.join(root, "priv/static/assets/css/app.css")
    js_built = Path.join(root, "priv/static/assets/js/app.js")
    node_modules = Path.join(root, "assets/node_modules")

    css =
      with {:ok, built} <- File.read(css_built),
           {:ok, source} <- File.read(css_source) do
        case Enum.reject(declared_tokens(source), &String.contains?(built, &1 <> ":")) do
          [] -> []
          missing -> [{:stale, css_built, missing}]
        end
      else
        _unreadable -> if File.exists?(css_built), do: [], else: [{:missing, css_built}]
      end

    js = if File.exists?(js_built), do: [], else: [{:missing, js_built}]
    deps = if File.dir?(node_modules), do: [], else: [:no_node_modules]

    css ++ js ++ deps
  end

  # Custom properties the source declares outside comments and `@theme` blocks
  # (which hold no nested braces, so one regex takes each out whole).
  defp declared_tokens(source) do
    source =
      ~r{/\*.*?\*/}s
      |> Regex.replace(source, "")
      |> then(&Regex.replace(~r/@theme[^{]*\{[^}]*\}/, &1, ""))

    ~r/(--[A-Za-z0-9_-]+)\s*:/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "The recovery text for `problems` — `nil` when there are none."
  @spec message([problem()]) :: String.t() | nil
  def message([]), do: nil

  def message(problems) do
    fix =
      if :no_node_modules in problems,
        do: "mix assets.setup && mix assets.build",
        else: "mix assets.build"

    """
    The local asset build is stale or missing. Pages render with an old or \
    absent stylesheet or bundle, which looks like a broken UI but is not one:
    #{Enum.map_join(problems, "\n", &("  * " <> describe(&1)))}
    Rebuild with `#{fix}` and reload. If Tailwind exits with 137 on macOS, \
    the downloaded binary's signature is no longer trusted: run \
    `codesign --force -s - _build/tailwind-*` and rebuild. For a beta \
    session, run the published image instead (docs/beta-testing.md).\
    """
  end

  @doc false
  # Public, not private: only a dev build calls it, and a private function
  # nothing calls is a compile warning in every other build.
  @spec report([problem()]) :: :ok
  def report(problems) do
    :persistent_term.put(@key, problems)
    if message = message(problems), do: Logger.warning(message)
    :ok
  end

  defp describe({:missing, path}), do: "#{relative(path)} does not exist"

  defp describe({:stale, built, missing}) do
    shown = missing |> Enum.take(5) |> Enum.join(", ")
    more = if length(missing) > 5, do: " (and #{length(missing) - 5} more)", else: ""

    "#{relative(built)} predates assets/css/app.css — it lacks #{shown}#{more}"
  end

  defp describe(:no_node_modules),
    do: "assets/node_modules is missing (the editor bundle cannot build without it)"

  defp relative(path), do: Path.relative_to(path, @root)
end
