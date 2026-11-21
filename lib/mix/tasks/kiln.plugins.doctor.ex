defmodule Mix.Tasks.Kiln.Plugins.Doctor do
  @shortdoc "Verify installed Kiln plugins against the host configuration"

  @moduledoc """
  Sanity-checks every plugin in `config :kiln_cms, :plugins` (decision D18),
  and the domain list a project's `config/project.exs` restates:

    * every core domain is still registered in `:ash_domains` — a project's
      list replaces the core's, so a domain a later release adds is missing
      until the project adds it (#1540);
    * the module implements `Kiln.Plugin`;
    * every declared domain is registered in **both** `:ash_domains` and
      `:content_domains` (plugins can't auto-wire those — Ash's own mix tasks
      read them straight from config, so the install step must add them);
    * block type names don't collide (across core and all plugins);
    * field-type modules implement `Kiln.FieldType` and their names don't
      collide (across core, the built-in types, and all plugins);
    * plugin Oban queues don't redefine core queues;
    * image backends (#1955) implement `Kiln.ImageBackend` with a usable,
      unique `name/0` — it is recorded on every image the backend holds — and
      the backend selected in `config :kiln_cms, :image_backend` is one an
      installed plugin declares;
    * backup destinations (#2220) implement `Kiln.BackupDestination` with a
      usable `kind/0` (lowercase letters, digits and `_`, at most 32
      characters) — it is stored on every destination of that adapter — that
      is neither one of Kiln's own (`local`, `rclone`, `s3`) nor another module's,
      and that implement `abort_upload/3` when `supports/0` declares
      `:resume` (#2223);
    * human-verification providers (#2249) pass
      `Kiln.Challenge.Provider.conformance/1`, and their ids collide neither
      with a built-in (`turnstile`, `recaptcha`, which always win) nor with
      each other; when `CHALLENGE_PROVIDER` names a provider, one is
      installed under that id;
    * security posture checks (#2252) pass `Kiln.Security.Check.conformance/1`,
      take no id under `core.` (KilnCMS's own, which a plugin's never
      displaces) and no id another plugin's check already has (the first
      registered is the one shown);
    * nav paths and admin routes are well-formed (`/editor/...`);
    * plug routes (#2272) are well-formed `{verb, path, plug, opts}` /
      `{:forward, path, plug, opts}` tuples, take no first segment a core route
      already owns (`/editor`, `/api`, `/gql`, `/mcp`, and every other static
      root in the compiled router) and no parameter or wildcard first segment,
      and do not overlap another plugin's plug or public routes, compared on
      whole path segments;
    * a block's `:json` render agrees with its exported schema (#937) —
      the same conformance check `test/kiln/block/json_schema_test.exs` runs
      for core blocks, which a third-party plugin never executes;
    * a field type whose `cast/2` output doesn't match what its editor widget
      implies declares `c:Kiln.FieldType.json_schema/1` to say so (#937), the
      same reason `KilnCMS.CMS.FieldTypes.Recurrence` has one;
    * a field type's client hook (`c:Kiln.FieldType.input_hook/1`, #1918)
      was actually bundled: the name it returns is registered in LiveView's
      colocated-hook manifest. A typo, or a `<script>` in a template that never
      compiled, otherwise surfaces only as a silent no-op in the browser;
    * a field type's editor inputs (`c:Kiln.FieldType.widgets/1`, #2284) are
      a list of machine-name atoms or `{name, label}` pairs, with no name
      twice. The host drops a malformed entry without a word, so the fields
      admin would simply not offer it;
    * a field type's list capability (`c:Kiln.FieldType.multiple?/0` and
      `c:Kiln.FieldType.unique_items?/0`, #2680) answers a boolean without
      raising, and one that takes lists is a scalar: its `input_parts/1` is
      `[]` for every editor input it offers, and its `cast/2` of a sample
      value answers one string or number. The host otherwise leaves the type
      single-valued, or refuses every write of the list;
    * a plugin's staging scrub declaration (`c:Kiln.Plugin.staging_scrub/0`,
      #2975) is usable: a list of well-formed entries, each naming an
      AshPostgres resource of the plugin's own domains (not a core table, not
      another plugin's, not one with `:context` multitenancy, no table
      declared twice), a rewrite only of attributes it may change with values
      that cast, and a keep with a reason. `mix kiln.staging.scrub` refuses
      to run on any of these;
    * every dependency that requires `kiln_plugin` (a plugin shipped as a
      Hex, git or `path:` dependency, #1909) accepts the version this core
      bundles. The core takes the package with `override: true`, which is
      what lets a plugin's Hex requirement converge on the bundled copy, and
      Mix does not check an overridden dependency's requirements, so this
      does;
    * with an overlay dependency list (`config/project_deps.exs`, #1967),
      every core dependency in `config/project.lock` is still at the version
      this release's `mix.lock` pins. The overlay lock is where `mix deps.get`
      writes once the overlay has dependencies, so an overlay dependency that
      needs a newer shared dependency would otherwise move a core one past
      what the release was tested with, without a word.

  Exits non-zero with every violation listed, so it can gate CI/precommit.

  It also **notes**, without failing:

    * a field type with `c:Kiln.FieldType.unique_items?/0` but not
      `c:Kiln.FieldType.multiple?/0` (it has no effect), or with both
      `c:Kiln.FieldType.multiple?/0` and `c:Kiln.FieldType.input_hook/1` (the
      hook is not attached to a list field's item inputs) (#2680);

    * a plugin that doesn't say what it does: no `c:Kiln.Plugin.summary/0`,
      or the `TODO:` placeholder `mix kiln.gen.plugin` scaffolds. The
      console's System → Plugins panel still lists such a plugin's
      contributions, but not why it's installed;
    * a plugin installed through the overlay's `config/project_deps.exs`
      (#1967) but missing from `config :kiln_cms, :plugins`. It compiled, but
      nothing it contributes is active until it is listed there;
    * a table of a plugin's or the overlay's domains that no
      `c:Kiln.Plugin.staging_scrub/0` entry names and that is not kept as
      content (#2975). `mix kiln.staging.scrub` refuses to run while it
      exists, but a site that never stages is not broken by it.

  The final line names where each plugin came from: `projects/` (an overlay
  compiled inside the core), `project_deps` (the overlay's dependency list),
  `dependency` (one the core's own mix.exs declares) or `core`.
  """
  use Mix.Task

  alias Kiln.Block.Info
  alias Kiln.Block.JsonSchema
  alias Kiln.Block.Sample
  alias KilnCMS.Backups.Destination
  alias KilnCMS.Blocks
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.JsonSchemaValidator
  alias KilnCMS.SchemaExport
  alias Mix.Kiln.ProjectLock

  @requirements ["compile"]

  @impl Mix.Task
  def run(_argv) do
    plugins = Application.get_env(:kiln_cms, :plugins, [])
    # `plugin.blocks()`/`plugin.field_types()` are plain function calls a
    # plugin author can make arbitrarily expensive (a DB lookup, a hex.pm
    # fetch — nothing forbids it); each is otherwise called twice below
    # (once per check that needs it), so every check reads off these instead.
    blocks_by_plugin = Map.new(plugins, &{&1, &1.blocks()})
    field_types_by_plugin = Map.new(plugins, &{&1, &1.field_types()})

    problems =
      core_domain_problems(Application.get_env(:kiln_cms, :ash_domains, [])) ++
        Enum.flat_map(plugins, &plugin_problems/1) ++
        block_collisions(plugins, blocks_by_plugin) ++
        field_type_problems(plugins, field_types_by_plugin) ++
        queue_collisions(plugins) ++
        plug_route_problems(plugins) ++
        image_backend_problems(plugins, Application.get_env(:kiln_cms, :image_backend)) ++
        backup_destination_problems(plugins) ++
        challenge_provider_problems(plugins, selected_challenge_provider()) ++
        security_check_problems(plugins) ++
        staging_scrub_problems(plugins, Application.get_env(:kiln_cms, :ash_domains, [])) ++
        block_schema_problems(plugins, blocks_by_plugin) ++
        field_type_schema_problems(plugins, field_types_by_plugin) ++
        field_type_hook_problems(plugins, field_types_by_plugin) ++
        field_type_widget_problems(plugins, field_types_by_plugin) ++
        field_type_list_problems(plugins, field_types_by_plugin) ++
        sdk_requirement_problems(sdk_version(), sdk_requirements(declared_deps())) ++
        project_lock_problems(File.cwd!())

    # Printed before the verdict so a failing run still shows them, and never
    # a problem: a missing description is a gap for operators, not a fault.
    Enum.each(undescribed(plugins), fn plugin ->
      Mix.shell().info(
        "note: #{plugin.name()} has no summary/0 — add one line saying what it " <>
          "adds; it's shown in System → Plugins and by mix kiln.plugins.list"
      )
    end)

    plugins
    |> field_type_list_notes(field_types_by_plugin)
    |> Enum.each(&Mix.shell().info("note: " <> &1))

    project_deps = Mix.Project.config()[:kiln_project_deps] || []

    Enum.each(unregistered(project_deps, plugins), fn plugin ->
      Mix.shell().info(
        "note: #{inspect(plugin)} is installed from config/project_deps.exs but not " <>
          "listed in config :kiln_cms, :plugins, so nothing it contributes is active"
      )
    end)

    plugins
    |> undeclared_scrub_tables(Application.get_env(:kiln_cms, :ash_domains, []))
    |> Enum.each(fn table ->
      Mix.shell().info(
        "note: no staging_scrub/0 entry for #{table}. mix kiln.staging.scrub refuses " <>
          "to run while the table exists: declare it {:purge, ...}, " <>
          "{:rewrite, ..., set: [...]} or {:keep, ..., reason}"
      )
    end)

    case problems do
      [] ->
        Mix.shell().info("#{length(plugins)} plugin(s) OK: #{names(plugins, project_deps)}")

      problems ->
        Mix.raise("""
        Plugin configuration problems:

        #{Enum.map_join(problems, "\n", &bulleted/1)}
        """)
    end
  end

  @doc false
  # Plugins with no usable summary. The generator's `"TODO: …"` placeholder
  # counts as none — otherwise every scaffolded plugin would pass for described.
  # Skips a module that isn't a plugin at all; `plugin_problems/1` reports it.
  def undescribed(plugins) do
    Enum.filter(plugins, fn plugin ->
      Code.ensure_loaded?(plugin) and function_exported?(plugin, :summary, 0) and
        blank_summary?(plugin.summary())
    end)
  end

  defp blank_summary?(summary) when is_binary(summary) do
    trimmed = String.trim(summary)
    trimmed == "" or String.starts_with?(trimmed, "TODO")
  end

  defp blank_summary?(_summary), do: true

  defp names([], _project_deps), do: "(none)"

  defp names(plugins, project_deps),
    do: Enum.map_join(plugins, ", ", &"#{&1.name()} (#{source(&1, project_deps)})")

  @doc false
  # Core entries of the overlay lock that moved away from mix.lock (#1967).
  # Public so the test can point it at any directory.
  @spec project_lock_problems(Path.t()) :: [String.t()]
  def project_lock_problems(root) do
    if ProjectLock.present?(root) do
      root
      |> ProjectLock.lock_path()
      |> ProjectLock.read()
      |> ProjectLock.drift(root |> ProjectLock.core_lock_path() |> ProjectLock.read())
      |> Enum.map(fn {app, project_entry, core_entry} ->
        "config/project.lock has #{app} at #{lock_version(project_entry)}, but this " <>
          "release's mix.lock pins #{lock_version(core_entry)}. Core dependencies stay at " <>
          "the release's versions: delete config/project.lock and run mix deps.get to " <>
          "re-seed it, and if an overlay dependency then fails to resolve, use a version " <>
          "of it built for this core"
      end)
    else
      []
    end
  end

  defp lock_version({:hex, _app, version, _inner, _managers, _deps, _repo, _outer}), do: version
  defp lock_version({:git, _url, ref, _opts}) when is_binary(ref), do: String.slice(ref, 0, 7)
  defp lock_version(entry), do: inspect(entry)

  @doc false
  # Where a plugin module came from (#1967), for the summary line. Public for
  # testing; `project_deps` is the app list mix.exs read from the overlay.
  @spec source(module(), [atom()]) :: String.t()
  def source(plugin, project_deps) do
    case :application.get_application(plugin) do
      {:ok, :kiln_cms} -> if overlay_source?(plugin), do: "projects/", else: "core"
      {:ok, app} -> if app in project_deps, do: "project_deps", else: "dependency"
      :undefined -> "unknown"
    end
  end

  defp overlay_source?(module) do
    source = module.module_info(:compile) |> Keyword.get(:source, ~c"") |> to_string()
    String.contains?(source, "/projects/")
  end

  @doc false
  # Plugin entry modules shipped by the overlay's dependencies that
  # `config :kiln_cms, :plugins` doesn't list. Public for testing.
  @spec unregistered([atom()], [module()]) :: [module()]
  def unregistered(project_deps, plugins) do
    for app <- project_deps,
        Application.load(app) in [:ok, {:error, {:already_loaded, app}}],
        {:ok, modules} = :application.get_key(app, :modules),
        module <- modules,
        plugin_module?(module),
        module not in plugins,
        do: module
  end

  defp plugin_module?(module) do
    Code.ensure_loaded?(module) and
      Kiln.Plugin in (module.module_info(:attributes)
                      |> Keyword.get_values(:behaviour)
                      |> List.flatten())
  end

  # A rescued exception's `Exception.message/1` can itself be multi-line
  # (`Protocol.UndefinedError`, for one) — only the first line would land
  # under the bullet and the rest would print flush against the margin.
  # Collapsing to one line keeps every problem exactly one bulleted entry.
  defp bulleted(problem), do: "  * " <> String.replace(problem, "\n", " ")

  defp plugin_problems(plugin) do
    if Code.ensure_loaded?(plugin) and function_exported?(plugin, :domains, 0) do
      domain_problems(plugin) ++ path_problems(plugin)
    else
      ["#{inspect(plugin)} is not a Kiln.Plugin (module missing or contract not implemented)"]
    end
  end

  # Declared domains must be registered where Ash reads them from.
  defp domain_problems(plugin) do
    ash = Application.get_env(:kiln_cms, :ash_domains, [])
    content = Application.get_env(:kiln_cms, :content_domains, [])

    Enum.flat_map(plugin.domains(), fn domain ->
      Enum.reject(
        [
          domain not in ash &&
            "#{plugin.name()}: domain #{inspect(domain)} missing from :ash_domains",
          domain not in content &&
            "#{plugin.name()}: domain #{inspect(domain)} missing from :content_domains"
        ],
        &(&1 == false)
      )
    end)
  end

  @doc false
  # A project's `config/project.exs` REPLACES the core's `:ash_domains` list
  # rather than appending to it, so a core domain added in a later release is
  # missing from every overlay that restated the list before it existed —
  # `KilnCMS.Notifications` (0.9) was missing even from the in-tree example
  # until the upgrade rehearsal (#1540) ran codegen against it. Such a domain's
  # tables then look orphaned to `mix ash.codegen`, which offers to DROP them
  # with "yes" as the default answer.
  #
  # The core's domains are found rather than listed, so this cannot drift from
  # `config/config.exs`: every `Ash.Domain` compiled from the core's own `lib/`.
  # Public, taking the list, so it can be tested without `put_env` on a key
  # every other test reads.
  def core_domain_problems(ash_domains) do
    for domain <- core_domains(), domain not in ash_domains do
      "core domain #{inspect(domain)} is missing from :ash_domains. A project's " <>
        "config/project.exs replaces the core list, so restate every domain in " <>
        "config/config.exs; otherwise mix ash.codegen offers to DROP its tables"
    end
  end

  @doc false
  # `{app, requirement}` for every dependency that declares one on
  # `kiln_plugin`. Takes `{app, [{child_app, requirement}]}` pairs (what
  # `declared_deps/0` reads) so the test can hand it any shape.
  @spec sdk_requirements([{atom(), [{atom(), String.t() | nil}]}]) :: [{atom(), String.t()}]
  def sdk_requirements(declared) do
    for {app, children} <- declared,
        {:kiln_plugin, requirement} <- children,
        is_binary(requirement),
        do: {app, requirement}
  end

  @doc false
  # Each loaded dependency with the requirements it declares on its own
  # dependencies, from the dependency graph Mix already resolved for this
  # build. `Mix.Dep` is Mix's own (undocumented) graph. The public alternative,
  # `Mix.Project.in_project/3` on each dependency's mix.exs, `cd`s the whole VM
  # into that directory, which breaks every async test that reads a relative
  # path while this task runs.
  @spec declared_deps() :: [{atom(), [{atom(), String.t() | nil}]}]
  def declared_deps do
    for dep <- Mix.Dep.cached(), do: {dep.app, Enum.map(dep.deps, &{&1.app, &1.requirement})}
  end

  @doc false
  # Public so it can be tested with any version and requirement list.
  @spec sdk_requirement_problems(String.t(), [{atom(), String.t()}]) :: [String.t()]
  def sdk_requirement_problems(sdk_version, requirements) do
    for {app, requirement} <- requirements,
        problem = sdk_requirement_problem(sdk_version, requirement),
        problem != nil do
      "#{app} requires kiln_plugin #{problem}, but this core bundles kiln_plugin " <>
        "#{sdk_version} (sdk/kiln_plugin). Use a version of #{app} built for this " <>
        "core, or a core that bundles a matching kiln_plugin"
    end
  end

  defp sdk_requirement_problem(sdk_version, requirement) do
    case Version.parse_requirement(requirement) do
      {:ok, parsed} ->
        if Version.match?(sdk_version, parsed), do: nil, else: requirement

      :error ->
        "#{inspect(requirement)} (not a valid version requirement)"
    end
  end

  defp sdk_version do
    _ = Application.load(:kiln_plugin)
    :kiln_plugin |> Application.spec(:vsn) |> to_string()
  end

  @doc false
  def core_domains do
    {:ok, modules} = :application.get_key(:kiln_cms, :modules)

    modules
    |> Enum.filter(&(core_source?(&1) and Spark.Dsl.is?(&1, Ash.Domain)))
    |> Enum.sort()
  end

  defp core_source?(module) do
    source = module.module_info(:compile) |> Keyword.get(:source, ~c"") |> to_string()
    String.contains?(source, "/lib/kiln_cms/")
  end

  defp path_problems(plugin) do
    nav =
      for %{path: path} <- plugin.nav_items(), not String.starts_with?(path, "/") do
        "#{plugin.name()}: nav path #{inspect(path)} must be absolute"
      end

    routes =
      for {path, _lv, _action} <- plugin.admin_routes(),
          not String.starts_with?(path, "/editor") do
        "#{plugin.name()}: admin route #{inspect(path)} must live under /editor"
      end

    editor_routes =
      for {path, _lv, _action} <- plugin.editor_routes(),
          not String.starts_with?(path, "/editor") do
        "#{plugin.name()}: editor route #{inspect(path)} must live under /editor"
      end

    public_routes =
      for {path, _lv, _action} <- plugin.public_routes(),
          not String.starts_with?(path, "/") or
            Enum.any?(
              ["/editor", "/api", "/gql", "/mcp"],
              &String.starts_with?(path, &1)
            ) do
        "#{plugin.name()}: public route #{inspect(path)} must be absolute and outside /editor, /api, /gql, /mcp"
      end

    nav ++ routes ++ editor_routes ++ public_routes
  end

  @doc false
  # Plug routes (#2272). `core_roots` is injectable so a test can pass a table
  # without compiling a router; by default it is read from the compiled
  # `KilnCMSWeb.Router`, minus the routes plugins themselves mounted there.
  def plug_route_problems(plugins, core_roots \\ core_route_roots()) do
    claims =
      for plugin <- plugins,
          Code.ensure_loaded?(plugin),
          route <- Kiln.Plugins.PlugRoute.of(plugin),
          do: {plugin, route}

    {valid, shape_problems} =
      Enum.reduce(claims, {[], []}, fn {plugin, route} = claim, {valid, problems} ->
        case plug_route_problem(plugin, route, core_roots) do
          nil -> {[claim | valid], problems}
          problem -> {valid, [problem | problems]}
        end
      end)

    public =
      for plugin <- plugins,
          Code.ensure_loaded?(plugin),
          function_exported?(plugin, :public_routes, 0),
          {path, _lv, _action} <- plugin.public_routes(),
          do: {plugin, {:get, path, :public_route, nil}}

    valid = Enum.reverse(valid)

    Enum.reverse(shape_problems) ++ plug_route_overlaps(valid ++ public)
  end

  defp plug_route_problem(plugin, route, core_roots) do
    case Kiln.Plugins.PlugRoute.validate(route) do
      {:error, reason} ->
        "#{plugin.name()}: plug route #{reason}"

      :ok ->
        {_verb, path, _plug, _opts} = route
        root = Kiln.Plugins.PlugRoute.root(path)

        if root in core_roots do
          "#{plugin.name()}: plug route #{inspect(path)} sits under /#{root}, " <>
            "which core routes already own"
        end
    end
  end

  # Every pair that can answer the same request. At least one side must be a
  # plug route: public routes are not this check's business among themselves.
  defp plug_route_overlaps(claims) do
    for {{plugin_a, {verb_a, path_a, plug_a, _}}, index} <- Enum.with_index(claims),
        {plugin_b, {verb_b, path_b, plug_b, _}} <- Enum.drop(claims, index + 1),
        :public_route != plug_a or :public_route != plug_b,
        Kiln.Plugins.PlugRoute.overlap?({verb_a, path_a}, {verb_b, path_b}) do
      "#{plugin_a.name()}: plug route #{inspect(path_a)} overlaps #{plugin_b.name()}'s " <>
        "#{route_kind(plug_b)} #{inspect(path_b)}"
    end
  end

  defp route_kind(:public_route), do: "public route"
  defp route_kind(_plug), do: "plug route"

  # The static first segments of the compiled core route table. Routes a plugin
  # mounted itself are left out (they would collide with their own plugin), and
  # the roots the endpoint answers outside the router are always included.
  defp core_route_roots do
    plugin_modules =
      Kiln.Plugins.all()
      |> Enum.flat_map(fn plugin ->
        for {_verb, _path, mod, _opts} <- Kiln.Plugins.PlugRoute.of(plugin), do: mod
      end)

    live_views =
      for {_path, lv, _action} <-
            Kiln.Plugins.admin_routes() ++
              Kiln.Plugins.editor_routes() ++ Kiln.Plugins.public_routes(),
          do: lv

    roots =
      for route <- Phoenix.Router.routes(KilnCMSWeb.Router),
          not plugin_mounted?(route, plugin_modules, live_views),
          root = Kiln.Plugins.PlugRoute.root(route.path),
          not String.starts_with?(root, [":", "*"]),
          do: root

    Enum.uniq(roots ++ Kiln.Plugins.PlugRoute.reserved_roots())
  end

  defp plugin_mounted?(route, plugin_modules, live_views) do
    live_view =
      case route.metadata do
        %{phoenix_live_view: {view, _action, _opts, _session}} -> view
        _ -> nil
      end

    route.plug in plugin_modules or live_view in live_views
  end

  defp block_collisions(plugins, blocks_by_plugin) do
    core = KilnCMS.Blocks.core_types()

    plugins
    |> Enum.flat_map(fn plugin ->
      for mod <- blocks_by_plugin[plugin], do: {Kiln.Block.Info.name(mod), plugin.name()}
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, owners} ->
      cond do
        name in core -> ["block #{inspect(name)} collides with a core block"]
        length(owners) > 1 -> ["block #{inspect(name)} declared by multiple plugins"]
        true -> []
      end
    end)
  end

  # Field types must implement the contract; names must be unique across core
  # and all plugins (same stance as blocks).
  defp field_type_problems(plugins, field_types_by_plugin) do
    declared =
      Enum.flat_map(plugins, fn plugin ->
        for mod <- field_types_by_plugin[plugin], do: {plugin, mod}
      end)

    # `field_type_module?/1` (below) is the one place this contract check
    # lives — it also carries the `rescue` a non-atom `field_types()` entry
    # needs, so this can't safely duplicate the check inline without losing it.
    contract =
      for {plugin, mod} <- declared, not field_type_module?(mod) do
        "#{plugin.name()}: field type #{inspect(mod)} does not implement Kiln.FieldType"
      end

    # Core types *and* the in-tree `Kiln.FieldType` implementations
    # (`:geolocation`, `:computed`) are off limits — a plugin claiming either
    # would shadow it in the registry.
    reserved = KilnCMS.CMS.FieldTypes.reserved()

    collisions =
      declared
      |> Enum.filter(fn {_plugin, mod} -> field_type_named?(mod) end)
      |> Enum.group_by(fn {_plugin, mod} -> mod.name() end)
      |> Enum.flat_map(fn {name, owners} ->
        cond do
          name in reserved -> ["field type #{inspect(name)} collides with a built-in field type"]
          length(owners) > 1 -> ["field type #{inspect(name)} declared by multiple plugins"]
          true -> []
        end
      end)

    contract ++ collisions
  end

  defp queue_collisions(plugins) do
    core =
      :kiln_cms |> Application.get_env(Oban, []) |> Keyword.get(:queues, []) |> Keyword.keys()

    Enum.flat_map(plugins, fn plugin ->
      for {queue, _limit} <- plugin.oban_queues(), queue in core do
        "#{plugin.name()}: queue #{inspect(queue)} redefines a core Oban queue"
      end
    end)
  end

  # ── image backends (#1955) ──────────────────────────────────────────────────
  #
  # `name/0` is the one thing that has to be right forever: it is written on
  # every row the backend holds, and an item whose name no installed backend
  # answers to cannot be read until one does. Hence a usable, unique name, and
  # a selected backend that a plugin actually declares — a module wired
  # straight into config works, but the System page and this check can't see
  # where it came from.
  @doc false
  def image_backend_problems(plugins, selected) do
    # `ensure_loaded?` first: `function_exported?/3` is false for a module
    # that isn't loaded yet, which would report a plugin's backend as
    # undeclared. Inside `mix kiln.plugins.doctor` an earlier check happens
    # to load every plugin; a direct call (a plugin's own test) gets no such
    # help.
    declared =
      for plugin <- plugins,
          Code.ensure_loaded?(plugin),
          function_exported?(plugin, :image_backends, 0),
          mod <- plugin.image_backends(),
          do: {plugin, mod}

    {backends, contract} =
      Enum.split_with(declared, fn {_plugin, mod} -> Kiln.ImageBackend.Registry.backend?(mod) end)

    contract =
      for {plugin, mod} <- contract do
        "#{plugin.name()}: image backend #{inspect(mod)} does not implement Kiln.ImageBackend"
      end

    named = for {plugin, mod} <- backends, do: {plugin, mod, backend_name(mod)}

    names =
      for {plugin, mod, name} <- named, not usable_backend_name?(name) do
        "#{plugin.name()}: image backend #{inspect(mod)} needs a name/0 of 1-64 characters, " <>
          "got #{inspect(name)}"
      end

    collisions =
      named
      |> Enum.filter(fn {_plugin, _mod, name} -> usable_backend_name?(name) end)
      |> Enum.uniq_by(fn {_plugin, mod, _name} -> mod end)
      |> Enum.group_by(fn {_plugin, _mod, name} -> name end)
      |> Enum.flat_map(fn
        {_name, [_one]} ->
          []

        {name, _many} ->
          ["image backend name #{inspect(name)} is declared by more than one module"]
      end)

    contract ++ names ++ collisions ++ selected_backend_problems(selected, backends)
  end

  # ── backup destinations (#2220) ─────────────────────────────────────────────
  #
  # `kind/0` is what every stored destination of the adapter carries, so like
  # an image backend's name it has to be usable and unique. The registry
  # keeps the first module of a kind and drops the rest without a word; this
  # is where the operator hears about it.
  @doc false
  def backup_destination_problems(plugins) do
    declared =
      for plugin <- plugins,
          Code.ensure_loaded?(plugin),
          mod <- Kiln.Plugins.backup_destinations_of(plugin),
          do: {plugin, mod}

    {adapters, contract} =
      Enum.split_with(declared, fn {_plugin, mod} -> Destination.adapter?(mod) end)

    contract =
      for {plugin, mod} <- contract do
        "#{plugin.name()}: backup destination #{inspect(mod)} does not implement " <>
          "Kiln.BackupDestination"
      end

    {kinded, unkinded} =
      adapters
      |> Enum.map(fn {plugin, mod} -> {plugin, mod, Destination.kind_of(mod)} end)
      |> Enum.split_with(fn {_plugin, _mod, kind} -> match?({:ok, _}, kind) end)

    kinds =
      for {plugin, mod, :error} <- unkinded do
        "#{plugin.name()}: backup destination #{inspect(mod)} needs a kind/0 of lowercase " <>
          "letters, digits and _, at most 32 characters"
      end

    core = MapSet.new(Destination.core_kinds())

    taken =
      for {plugin, mod, {:ok, kind}} <- kinded, kind in core do
        "#{plugin.name()}: backup destination #{inspect(mod)} takes the kind " <>
          "#{inspect(kind)} of one of Kiln's own destinations"
      end

    collisions =
      kinded
      |> Enum.reject(fn {_plugin, _mod, {:ok, kind}} -> kind in core end)
      |> Enum.uniq_by(fn {_plugin, mod, _kind} -> mod end)
      |> Enum.group_by(fn {_plugin, _mod, {:ok, kind}} -> kind end)
      |> Enum.flat_map(fn
        {_kind, [_one]} ->
          []

        {kind, _many} ->
          ["backup destination kind #{inspect(kind)} is declared by more than one module"]
      end)

    # #2223: without `abort_upload/3` an upload it started could never be
    # freed, so the core never resumes it; the operator hears why here.
    unabortable =
      for {plugin, mod, {:ok, _kind}} <- kinded,
          :resume in declared_supports(mod),
          not function_exported?(mod, :abort_upload, 3) do
        "#{plugin.name()}: backup destination #{inspect(mod)} declares :resume in supports/0 " <>
          "but does not implement abort_upload/3, so its uploads are never resumed"
      end

    contract ++ kinds ++ taken ++ collisions ++ unabortable
  end

  # A plugin's `supports/0`, or `[]` when it has none or it misbehaves.
  defp declared_supports(mod) do
    with true <- function_exported?(mod, :supports, 0),
         list when is_list(list) <- mod.supports() do
      list
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  # ── staging scrub (#2975) ────────────────────────────────────────────────
  #
  # The same checks `KilnCMS.Staging.PluginScrub.plan!/1` refuses on, minus
  # the ones that need the database (which tables exist, foreign keys), so a
  # bad declaration is heard about at precommit rather than mid-staging.
  @doc false
  def staging_scrub_problems(plugins, ash_domains) do
    plugins
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> KilnCMS.Staging.PluginScrub.problems(ash_domains)
  end

  @doc false
  def undeclared_scrub_tables(plugins, ash_domains) do
    plugins
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> KilnCMS.Staging.PluginScrub.undeclared(ash_domains)
  end

  defp selected_backend_problems(nil, _backends), do: []

  defp selected_backend_problems(selected, backends) do
    cond do
      not Kiln.ImageBackend.Registry.backend?(selected) ->
        [
          "config :kiln_cms, :image_backend — #{inspect(selected)} does not implement Kiln.ImageBackend"
        ]

      not Enum.any?(backends, fn {_plugin, mod} -> mod == selected end) ->
        [
          "config :kiln_cms, :image_backend — #{inspect(selected)} is not declared by any " <>
            "installed plugin's image_backends/0"
        ]

      true ->
        []
    end
  end

  defp backend_name(mod) do
    mod.name()
  rescue
    error -> {:raised, Exception.message(error)}
  end

  defp usable_backend_name?(name),
    do: is_binary(name) and String.trim(name) != "" and String.length(name) <= 64

  # ── human-verification providers (#2249) ───────────────────────────────────
  #
  # The core checks a provider the same way before it uses one, and turns
  # verification off when it fails — safe, but silent until a page asks. This
  # says so before deploy. A plugin id equal to a built-in's is a problem even
  # though the built-in wins: the plugin's provider can never be selected.
  @doc false
  def challenge_provider_problems(plugins, selected) do
    # The raw list, not the registry's tolerant reading of it: the registry
    # drops an entry that is not a module, which is right at run time and
    # exactly what an author needs to hear about here.
    raw = for plugin <- plugins, do: {plugin, raw_challenge_providers(plugin)}

    malformed =
      for {plugin, {:error, message}} <- raw,
          do: "#{plugin.name()}: challenge_providers/0 #{message}"

    entries =
      for {plugin, {:ok, list}} <- raw,
          entry <- list,
          do: {plugin, entry}

    {declared, not_modules} = Enum.split_with(entries, fn {_plugin, entry} -> is_atom(entry) end)

    malformed =
      malformed ++
        for {plugin, entry} <- not_modules do
          "#{plugin.name()}: challenge_providers/0 entry #{inspect(entry)} is not a module"
        end

    conformance =
      for {plugin, mod} <- declared,
          {:error, problems} <- [Kiln.Challenge.Provider.conformance(mod)],
          problem <- problems do
        "#{plugin.name()}: challenge provider #{inspect(mod)}: #{problem}"
      end

    built_in_ids = Enum.map(KilnCMS.Challenge.Registry.built_in(), & &1.id())

    named =
      for {plugin, mod} <- Enum.uniq_by(declared, &elem(&1, 1)),
          id <- [KilnCMS.Challenge.Registry.id_of(mod)],
          is_binary(id),
          do: {plugin, mod, id}

    built_in_collisions =
      for {plugin, mod, id} <- named, id in built_in_ids do
        "#{plugin.name()}: challenge provider #{inspect(mod)} takes the id #{inspect(id)}, " <>
          "which is a built-in's: it can never be selected"
      end

    collisions =
      named
      |> Enum.reject(fn {_plugin, _mod, id} -> id in built_in_ids end)
      |> Enum.group_by(fn {_plugin, _mod, id} -> id end)
      |> Enum.flat_map(fn
        {_id, [_one]} ->
          []

        {id, _many} ->
          ["challenge provider id #{inspect(id)} is declared by more than one module"]
      end)

    installed_ids = built_in_ids ++ Enum.map(named, fn {_plugin, _mod, id} -> id end)

    malformed ++
      conformance ++
      built_in_collisions ++ collisions ++ selected_provider_problems(selected, installed_ids)
  end

  # `{:ok, list}`, or `{:error, why}` for a callback that raises or answers
  # something other than a list; `{:ok, []}` for a plugin built against an
  # SDK without the callback.
  defp raw_challenge_providers(plugin) do
    if Code.ensure_loaded?(plugin) and function_exported?(plugin, :challenge_providers, 0) do
      case plugin.challenge_providers() do
        list when is_list(list) -> {:ok, list}
        other -> {:error, "must return a list, got #{inspect(other)}"}
      end
    else
      {:ok, []}
    end
  rescue
    error -> {:error, "raised: " <> Exception.message(error)}
  end

  defp selected_provider_problems(nil, _installed_ids), do: []

  defp selected_provider_problems(id, installed_ids) do
    if id in installed_ids,
      do: [],
      else: ["CHALLENGE_PROVIDER names #{inspect(id)}, which no installed provider answers to"]
  end

  # Only what the operator set: a provider configured in a config file is the
  # project's own business, and an unset variable selects nothing.
  defp selected_challenge_provider do
    case KilnCMS.Challenge.parse_provider_id(System.get_env("CHALLENGE_PROVIDER")) do
      {:ok, id} -> id
      _unset_or_invalid -> nil
    end
  end

  # ── security posture checks (#2252) ────────────────────────────────────────
  #
  # The core resolves checks the same way at run time and drops a bad one with
  # a log line, so the page just shows one line fewer. This says so before
  # deploy, and names the collision the registry settles silently.
  @doc false
  def security_check_problems(plugins) do
    raw = for plugin <- plugins, do: {plugin, raw_security_checks(plugin)}

    malformed =
      for {plugin, {:error, message}} <- raw,
          do: "#{plugin.name()}: security_checks/0 #{message}"

    entries =
      for {plugin, {:ok, list}} <- raw,
          entry <- list,
          do: {plugin, entry}

    {declared, not_modules} = Enum.split_with(entries, fn {_plugin, entry} -> is_atom(entry) end)

    malformed =
      malformed ++
        for {plugin, entry} <- not_modules do
          "#{plugin.name()}: security_checks/0 entry #{inspect(entry)} is not a module"
        end

    described =
      for {plugin, mod} <- Enum.uniq_by(declared, &elem(&1, 1)),
          do: {plugin, mod, Kiln.Security.Check.describe(mod)}

    conformance =
      for {plugin, mod, {:error, problems}} <- described, problem <- problems do
        "#{plugin.name()}: security check #{inspect(mod)}: #{problem}"
      end

    named = for {plugin, mod, {:ok, %{id: id}}} <- described, do: {plugin, mod, id}

    reserved =
      for {plugin, mod, id} <- named, String.starts_with?(id, "core.") do
        "#{plugin.name()}: security check #{inspect(mod)} takes the id #{inspect(id)}, " <>
          "which is reserved for KilnCMS's own checks: it is never shown"
      end

    collisions =
      named
      |> Enum.reject(fn {_plugin, _mod, id} -> String.starts_with?(id, "core.") end)
      |> Enum.group_by(fn {_plugin, _mod, id} -> id end)
      |> Enum.flat_map(fn
        {_id, [_one]} ->
          []

        {id, [{first, _mod, _id} | _rest] = many} ->
          [
            "security check id #{inspect(id)} is declared by more than one module " <>
              "(#{Enum.map_join(many, ", ", fn {_p, mod, _id} -> inspect(mod) end)}); " <>
              "only #{first.name()}'s is shown"
          ]
      end)

    malformed ++ conformance ++ reserved ++ collisions
  end

  # `{:ok, list}`, or `{:error, why}` for a callback that raises or answers
  # something other than a list; `{:ok, []}` for a plugin built against an
  # SDK without the callback.
  defp raw_security_checks(plugin) do
    if Code.ensure_loaded?(plugin) and function_exported?(plugin, :security_checks, 0) do
      case plugin.security_checks() do
        list when is_list(list) -> {:ok, list}
        other -> {:error, "must return a list, got #{inspect(other)}"}
      end
    else
      {:ok, []}
    end
  rescue
    error -> {:error, "raised: " <> Exception.message(error)}
  catch
    # A throw or an exit is the plugin's fault too: reported, not a crash of
    # the whole doctor run.
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # ── block :json render vs exported schema (#937) ───────────────────────────
  #
  # Mirrors `test/kiln/block/json_schema_test.exs`'s "conformance" describe —
  # build a populated struct, render it to `:json`, validate against the same
  # `$defs` `GET /api/schema` publishes. That test only ever runs core blocks
  # plus the in-repo test-suite fixture plugin; a downstream overlay's plugin
  # blocks are in `Blocks.modules()` at boot but never sit in this repo's
  # `mix test` run, so this is the only place the check reaches them.
  #
  # `$defs` is built from `plugins` (this task's own argument) rather than
  # `Kiln.Plugins.blocks()`: the latter is `Application.compile_env`, baked
  # when `lib/kiln/plugins.ex` compiled, so every other check in this task
  # already reads `plugin.blocks()` off the runtime config instead — the same
  # reason `mix kiln.plugins.doctor` is testable via `Application.put_env` at
  # all. `Blocks.core_modules/0` supplies "core blocks" directly rather than
  # backing them out of `Blocks.modules() -- Kiln.Plugins.blocks()`.
  #
  # Two failure modes need guarding against before `JsonSchema.defs/1` runs:
  #
  #   * a plugin block's own `c:Kiln.Block.Renderer.json_schema/0` raising —
  #     `for_module/1` calls it with no rescue of its own, unlike every other
  #     call into plugin-authored code in this file (see `field_type_module?/1`
  #     below), so unguarded it would take the whole doctor run down instead
  #     of being reported as that plugin's own problem. Each plugin block's
  #     callback is probed first; one that raises is excluded from the `$defs`
  #     build entirely (core blocks aren't probed — a raise there is a core
  #     bug, already covered by `test/kiln/block/json_schema_test.exs`, not a
  #     plugin's).
  #
  #   * two *different* plugins declaring a block with the same `_type` name —
  #     `JsonSchema.block_modules/1` (which `defs/1` calls) dedupes by `_type`
  #     via `Enum.uniq_by/2`, keeping only the first module for a given name.
  #     Plugin blocks are listed *before* the core set in the concatenation so
  #     a plugin/core collision always resolves to the plugin's own schema
  #     rather than the core block's (needed so that check isn't silently
  #     validated against the wrong shape either). But which of *two* plugin
  #     modules sharing a name comes first is decided by Erlang map iteration
  #     order over `blocks_by_plugin`, not declaration order — nondeterministic.
  #     `winners` is exactly the module set `JsonSchema.block_modules/1` kept,
  #     so only the module that actually produced the `$defs` entry for its
  #     name gets its render checked against it; the other is already flagged
  #     as a naming conflict by `block_collisions/1` and skipped here rather
  #     than validated against a schema that isn't its own.
  defp block_schema_problems(plugins, blocks_by_plugin) do
    probed =
      for plugin <- plugins, module <- blocks_by_plugin[plugin] do
        {plugin, module, probe_block_json_schema(module)}
      end

    schema_raise_problems =
      for {plugin, module, {:error, message}} <- probed do
        "#{plugin.name()}: block #{inspect(module)}'s json_schema/0 raised (#{message})"
      end

    unsound = MapSet.new(for {_plugin, module, {:error, _}} <- probed, do: module)

    plugin_blocks =
      blocks_by_plugin
      |> Map.values()
      |> List.flatten()
      |> Enum.reject(&MapSet.member?(unsound, &1))

    candidates = Enum.uniq(plugin_blocks ++ Blocks.core_modules())
    defs = JsonSchema.defs(candidates)
    winners = MapSet.new(JsonSchema.block_modules(candidates))
    document = %{"$defs" => defs}

    schema_raise_problems ++
      Enum.flat_map(plugins, fn plugin ->
        blocks_by_plugin[plugin]
        |> Enum.reject(&MapSet.member?(unsound, &1))
        |> Enum.filter(&MapSet.member?(winners, &1))
        |> Enum.flat_map(&block_render_problems(plugin, &1, defs, document))
      end)
  end

  defp probe_block_json_schema(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :json_schema, 0) do
      module.json_schema()
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp block_render_problems(plugin, module, defs, document) do
    with true <- Code.ensure_loaded?(module) and function_exported?(module, :render, 2),
         name when not is_nil(name) <- Info.name(module),
         schema when not is_nil(schema) <- Map.get(defs, JsonSchema.def_name(name)) do
      # Both the populated branch (every field carrying a value) and the
      # required-only branch (`Sample.required_only/3` — the emptiest a block
      # can legitimately be post-#935, not a bare `struct(module)` with every
      # field nil, which a required field can no longer actually reach) — a
      # block like `KilnCMS.Blocks.Video` takes a different `:json` path
      # depending on which *optional* fields are present, and the core
      # conformance test checks both branches for exactly that reason.
      [Sample.populated(module), Sample.required_only(module)]
      |> Enum.flat_map(fn block ->
        rendered = Blocks.render(block, :json)
        validation = JsonSchemaValidator.validate(rendered, schema, document)
        block_validation_problems(plugin, name, validation)
      end)
    else
      _ -> []
    end
  rescue
    e ->
      raised_problem(
        plugin,
        "block #{inspect(module)}",
        "checking its :json render against its schema",
        e
      )
  end

  defp block_validation_problems(_plugin, _name, :ok), do: []

  defp block_validation_problems(plugin, name, {:error, errors}) do
    for error <- errors do
      "#{plugin.name()}: block #{inspect(name)} :json render disagrees with its " <>
        "exported schema (#{error}) — reconcile via c:Kiln.Block.Renderer.json_schema/0"
    end
  end

  # ── field type cast/2 vs its widget's implied shape (#937) ─────────────────
  #
  # `KilnCMS.SchemaExport` infers a field type's delivered JSON shape from its
  # editor widget (`c:Kiln.FieldType.input_type/0` / `c:input_parts/1`) unless
  # the type overrides `c:Kiln.FieldType.json_schema/1` to say otherwise —
  # `KilnCMS.CMS.FieldTypes.Recurrence` is the in-tree example: its widget is a
  # text input, but `cast/2` stores a list, so it declares the callback rather
  # than shipping a schema `SchemaExport` would infer wrong.
  #
  # This probes every plugin type that has *not* declared the callback by
  # casting a value shaped like what its own widget would submit, and
  # comparing the returned value's JSON kind against what the widget implies.
  # It is necessarily best-effort: a type whose `cast/2` rejects a generic
  # placeholder (a date format, an enum) answers `{:error, _}` and is skipped
  # rather than flagged — this catches a type that silently returns the wrong
  # *shape*, not one that merely dislikes the probe's sample value.
  defp field_type_schema_problems(plugins, field_types_by_plugin) do
    Enum.flat_map(plugins, fn plugin ->
      field_types_by_plugin[plugin]
      |> Enum.filter(&field_type_module?/1)
      # `field_type_module?/1` already established `mod` is loaded, so this
      # doesn't need to re-check — just read the callback off it.
      |> Enum.reject(&function_exported?(&1, :json_schema, 1))
      |> Enum.flat_map(&field_type_divergence(plugin, &1))
    end)
  end

  # `plugin.field_types()` is unvalidated third-party input — a non-atom entry
  # crashes `Code.ensure_loaded?/1` with a `FunctionClauseError` that isn't
  # about *this* module at all, and without a rescue here it takes the whole
  # doctor run down instead of being reported as that plugin's own problem.
  defp field_type_module?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :cast, 2) and
      function_exported?(mod, :name, 0)
  rescue
    _ -> false
  end

  # Same unvalidated-input hazard as `field_type_module?/1` above (a non-atom
  # `mod` crashes `Code.ensure_loaded?/1`), but for the collision check, which
  # only needs `name/0` — not the full contract `field_type_module?/1` checks.
  defp field_type_named?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :name, 0)
  rescue
    _ -> false
  end

  defp field_type_divergence(plugin, mod) do
    html_type = if function_exported?(mod, :input_type, 0), do: mod.input_type(), else: "text"

    definition =
      struct(FieldDefinition,
        name: "sample_field",
        field_type: mod.name(),
        required: false,
        content_type: probe_content_type(),
        # A select/enum-style `cast/2` legitimately validates its input against
        # `definition.options` (the real struct field this stands in for) —
        # an empty list would refuse every possible probe value unconditionally
        # and this check would never actually run for such a type, so it
        # carries the one value `scalar_divergence` is about to try.
        options: [widget_sample(html_type)]
      )

    case SchemaExport.parts(mod, definition) do
      [] -> scalar_divergence(plugin, mod, html_type, definition)
      parts -> composite_divergence(plugin, mod, definition, parts)
    end
  rescue
    # `inspect(mod)` rather than `mod.name()`: the exception being reported
    # may be `mod.name()` itself raising (it runs above, building
    # `definition`), and calling it again here would just raise past the
    # rescue instead of producing a message.
    e -> raised_problem(plugin, "field type #{inspect(mod)}", "checking cast/2", e)
  end

  # #1918: every hook a field type names must be in the colocated manifest
  # LiveView wrote at compile time (`@requirements ["compile"]` above). The
  # manifest is read as text — it is generated JS, one
  # `imp_…["<Module>.<Name>"] = …;` line per hook — because LiveView offers
  # no API listing the hooks it collected.
  defp field_type_hook_problems(plugins, field_types_by_plugin) do
    hooked =
      for plugin <- plugins,
          mod <- field_types_by_plugin[plugin],
          field_type_module?(mod),
          function_exported?(mod, :input_hook, 1),
          do: {plugin, mod}

    case hooked do
      [] ->
        []

      hooked ->
        manifest = colocated_manifest()
        Enum.flat_map(hooked, fn {plugin, mod} -> hook_problems(plugin, mod, manifest) end)
    end
  end

  defp hook_problems(plugin, mod, manifest) do
    definition =
      struct(FieldDefinition,
        name: "sample_field",
        field_type: mod.name(),
        required: false,
        content_type: probe_content_type()
      )

    case mod.input_hook(definition) do
      nil ->
        []

      %{hook: hook} when is_binary(hook) and hook != "" ->
        cond do
          is_nil(manifest) ->
            [
              "#{plugin.name()}: field type #{inspect(mod.name())} names hook #{inspect(hook)}, " <>
                "but no colocated-hook manifest was found at #{colocated_manifest_path()}"
            ]

          String.contains?(manifest, "[#{inspect(hook)}]") ->
            []

          true ->
            [
              "#{plugin.name()}: field type #{inspect(mod.name())} names hook #{inspect(hook)}, " <>
                "which is not a bundled colocated hook (declare it as " <>
                ~s(<script :type={ColocatedHook} name=".Name"> in a template of a module that ) <>
                "uses Phoenix.Component, " <>
                "and build the name with Kiln.FieldType.colocated_hook/2)"
            ]
        end

      other ->
        [
          "#{plugin.name()}: field type #{inspect(mod.name())} input_hook/1 returned " <>
            "#{inspect(other)}; expected %{hook: name, data: map} or nil"
        ]
    end
  rescue
    e -> raised_problem(plugin, "field type #{inspect(mod)}", "building its input_hook/1", e)
  end

  # #2284: `widgets/1` is read by the host on every field-definition write and
  # editor render, where a malformed entry is dropped silently (a plugin must
  # not be able to fail a save). This is where it gets named instead.
  defp field_type_widget_problems(plugins, field_types_by_plugin) do
    for plugin <- plugins,
        mod <- field_types_by_plugin[plugin],
        field_type_module?(mod),
        function_exported?(mod, :widgets, 1),
        problem <- widget_problems(plugin, mod),
        do: problem
  end

  defp widget_problems(plugin, mod) do
    definition =
      struct(FieldDefinition,
        name: "sample_field",
        field_type: mod.name(),
        required: false,
        content_type: probe_content_type()
      )

    subject = "#{plugin.name()}: field type #{inspect(mod.name())} widgets/1"

    case mod.widgets(definition) do
      widgets when is_list(widgets) ->
        names = Enum.map(widgets, &widget_entry_name/1)

        malformed =
          for {entry, nil} <- Enum.zip(widgets, names) do
            "#{subject} has entry #{inspect(entry)}; expected a machine-name atom " <>
              ~s[(lowercase letters, digits and underscores) or {name, "Label"}]
          end

        duplicates =
          names
          |> Enum.reject(&is_nil/1)
          |> Enum.frequencies()
          |> Enum.filter(fn {_name, count} -> count > 1 end)
          |> Enum.map(fn {name, _count} -> "#{subject} names #{inspect(name)} more than once" end)

        malformed ++ duplicates

      other ->
        ["#{subject} returned #{inspect(other)}; expected a list of names or {name, label} pairs"]
    end
  rescue
    e -> raised_problem(plugin, "field type #{inspect(mod)}", "listing its widgets/1", e)
  end

  @doc false
  # #2680: `multiple?/0` and `unique_items?/0` are read once, at compile time
  # (`KilnCMS.CMS.FieldTypes.list_capable/0`), where a raise or an answer that
  # is not `true` quietly leaves the type single-valued. A type that does take
  # lists must be a scalar for every editor input it offers, and cast a sample
  # to one string or number — the write path refuses a list whose items cast
  # to anything else. Public so a test can hand it inline modules.
  @spec field_type_list_problems([module()], %{module() => [module()]}) :: [String.t()]
  def field_type_list_problems(plugins, field_types_by_plugin) do
    for plugin <- plugins,
        mod <- Map.get(field_types_by_plugin, plugin, []),
        field_type_module?(mod),
        problem <- list_problems(plugin, mod),
        do: problem
  end

  defp list_problems(plugin, mod) do
    subject = "#{plugin.name()}: field type #{inspect(mod.name())}"

    answers =
      for callback <- [:multiple?, :unique_items?],
          function_exported?(mod, callback, 0),
          do: {callback, list_answer(plugin, mod, callback)}

    shape_problems =
      for {callback, {:ok, other}} <- answers, not is_boolean(other) do
        "#{subject} #{callback}/0 returned #{inspect(other)}; expected true or false"
      end

    raised = for {_callback, {:raised, problem}} <- answers, do: problem

    list? = match?({:ok, true}, Keyword.get(answers, :multiple?))

    problems =
      shape_problems ++
        raised ++ if(list?, do: scalar_list_problems(plugin, mod, subject), else: [])

    problems ++ probe_problems(list?, problems, mod, subject)
  end

  # The host decides list capability once, at compile time, probing
  # `input_parts/1` with a bare definition map rather than a
  # `FieldDefinition` struct; a type whose `input_parts/1` raises on that map
  # is quietly left single-valued. Say so, since nothing else would.
  defp probe_problems(true = _list?, [] = _problems, mod, subject) do
    if KilnCMS.CMS.FieldTypes.Capability.list_capable?(mod),
      do: [],
      else: [
        "#{subject} multiple?/0 returns true, but the host's probe of input_parts/1 " <>
          "(a definition map with only name, label, field_type, widget and multiple) " <>
          "raised or returned parts, so the type stays single-valued; make input_parts/1 " <>
          "return [] without reading other definition keys"
      ]
  end

  defp probe_problems(_list?, _problems, _mod, _subject), do: []

  defp list_answer(plugin, mod, callback) do
    {:ok, apply(mod, callback, [])}
  rescue
    e ->
      {:raised,
       hd(raised_problem(plugin, "field type #{inspect(mod)}", "answering #{callback}/0", e))}
  end

  # Every editor input the type offers, and none: `input_parts/1` must be `[]`
  # under each (a composite value is a repeating group's job), and a sample
  # of its single input must cast to one string or number.
  defp scalar_list_problems(plugin, mod, subject) do
    definitions =
      for widget <- [nil | offered_widget_names(mod)] do
        struct(FieldDefinition,
          name: "sample_field",
          label: "Sample field",
          field_type: mod.name(),
          required: false,
          multiple: false,
          widget: widget,
          content_type: probe_content_type()
        )
      end

    composite =
      for definition <- definitions,
          SchemaExport.parts(mod, %{definition | multiple: true}) != [] do
        "#{subject} multiple?/0 is true, but its input_parts/1 is not [] " <>
          if(definition.widget, do: "for its #{inspect(definition.widget)} input", else: "") <>
          "; a list holds one scalar per item — use a repeating group field for composite values"
      end

    case Enum.uniq(composite) do
      [] -> sample_cast_problems(mod, hd(definitions), subject)
      composite -> composite
    end
  rescue
    e -> raised_problem(plugin, "field type #{inspect(mod)}", "checking it can hold a list", e)
  end

  # A sample of the type's single input, cast as one item of a list is: it
  # must answer one string or number. A refusal is the sample's fault, not a
  # problem (`field_type_divergence/2` says the same).
  defp sample_cast_problems(mod, definition, subject) do
    html_type = if function_exported?(mod, :input_type, 0), do: mod.input_type(), else: "text"

    case mod.cast(widget_sample(html_type), definition) do
      {:ok, value} when not (is_binary(value) or is_number(value)) ->
        [
          "#{subject} multiple?/0 is true, but cast/2 of a sample value returned " <>
            "#{inspect(value)}; each item of a list must cast to one string or number"
        ]

      _scalar_or_refused ->
        []
    end
  end

  defp offered_widget_names(mod) do
    if function_exported?(mod, :widgets, 1) do
      probe = struct(FieldDefinition, name: "sample_field", field_type: mod.name())

      for entry <- List.wrap(mod.widgets(probe)),
          name = widget_entry_name(entry),
          name != nil,
          uniq: true,
          do: Atom.to_string(name)
    else
      []
    end
  rescue
    _exception -> []
  end

  @doc false
  # #2680: what `field_type_list_problems/2` does not fail on but an author
  # should hear. Public for the same reason.
  @spec field_type_list_notes([module()], %{module() => [module()]}) :: [String.t()]
  def field_type_list_notes(plugins, field_types_by_plugin) do
    for plugin <- plugins,
        mod <- Map.get(field_types_by_plugin, plugin, []),
        field_type_module?(mod),
        note <- list_notes(plugin, mod),
        do: note
  end

  defp list_notes(plugin, mod) do
    subject = "#{plugin.name()}: field type #{inspect(mod.name())}"
    list? = KilnCMS.CMS.FieldTypes.Capability.list_capable?(mod)

    unique? =
      function_exported?(mod, :unique_items?, 0) and
        KilnCMS.CMS.FieldTypes.Capability.unique_items?(mod)

    hooked? = list? and hook?(mod)

    Enum.reject(
      [
        (unique? and not list?) &&
          "#{subject} has unique_items?/0 but does not take lists (multiple?/0), so it has no effect",
        hooked? &&
          "#{subject} takes lists and has an input_hook/1; the hook is not attached to a list " <>
            "field's item inputs, so a list field of it works without it"
      ],
      &(&1 == false)
    )
  end

  defp hook?(mod) do
    function_exported?(mod, :input_hook, 1) and
      mod.input_hook(struct(FieldDefinition, name: "sample_field", field_type: mod.name())) != nil
  rescue
    _exception -> false
  end

  # The widget's name when `entry` is one the SDK allows, else nil.
  defp widget_entry_name({name, label}) when is_binary(label), do: widget_entry_name(name)

  defp widget_entry_name(name) when is_atom(name) and name not in [nil, true, false] do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, Atom.to_string(name)), do: name
  end

  defp widget_entry_name(_entry), do: nil

  defp colocated_manifest do
    case File.read(colocated_manifest_path()) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  # Where `Phoenix.LiveView.ColocatedAssets` writes it: the configured
  # `:target_directory` (or `<build>/phoenix-colocated`), then the app name.
  defp colocated_manifest_path do
    settings =
      Application.get_env(
        :phoenix_live_view,
        :colocated_assets,
        Application.get_env(:phoenix_live_view, :colocated_js, [])
      )

    settings
    |> Keyword.get(:target_directory, Path.join(Mix.Project.build_path(), "phoenix-colocated"))
    |> Path.join(to_string(Mix.Project.config()[:app]))
    |> Path.join("index.js")
  end

  # Shared "this plugin's own code raised" message, used by every rescue in
  # this task that reports one (`block_render_problems/4`,
  # `field_type_divergence/2`) — kept as one template so the phrasing doesn't
  # drift between them.
  defp raised_problem(plugin, subject, action, exception) do
    ["#{plugin.name()}: #{subject} raised while #{action} (#{Exception.message(exception)})"]
  end

  # A synthetic probe `definition` inevitably leaves most `FieldDefinition`
  # fields unset (there's no real content write to draw them from), but
  # `content_type`/`type_definition_id` being BOTH nil is a state a real
  # definition never has (see `FieldDefinition`'s own moduledoc) — and a
  # `cast/2` that reasonably reads `definition.content_type` (the core
  # `coerce_reference/3` does exactly this) raises on it, which this check's
  # `rescue` then reports as a plugin problem for a plugin that works
  # correctly against every real definition it's ever actually called with.
  # Picking a real, compiled content type closes that gap without needing to
  # guess anything content-type-specific about what the plugin itself does.
  defp probe_content_type do
    case KilnCMS.CMS.ContentTypes.types() do
      [type | _] -> type
      [] -> nil
    end
  end

  defp scalar_divergence(plugin, mod, html_type, definition) do
    case mod.cast(widget_sample(html_type), definition) do
      {:ok, value} ->
        divergence_problem(
          plugin,
          mod,
          value_kind(value),
          widget_kind(html_type),
          "for a value its #{inspect(html_type)} widget submits",
          "that widget"
        )

      _ ->
        []
    end
  end

  defp composite_divergence(plugin, mod, definition, parts) do
    sample =
      Map.new(parts, fn part -> {part.key, widget_sample(Map.get(part, :type, "text"))} end)

    case mod.cast(sample, definition) do
      {:ok, result} when is_map(result) ->
        # `cast/2`'s contract only requires a JSON-native return, not that its
        # keys match `input_parts/1`'s exact key type — an idiomatic
        # atom-keyed composite return (e.g. `%{lat: 1.0}`) is JSON-native too
        # (Jason stringifies atom keys on encode, so it round-trips correctly
        # through the real jsonb write path) and must not read as "missing".
        stringified = Map.new(result, fn {k, v} -> {to_string(k), v} end)
        Enum.flat_map(parts, &part_divergence(plugin, mod, &1, stringified))

      {:ok, other} ->
        [
          "#{plugin.name()}: field type #{inspect(mod.name())} declares composite input_parts/1 " <>
            "but cast/2 returns #{value_kind(other)}, not an object — declare " <>
            "c:Kiln.FieldType.json_schema/1 to describe the delivered shape"
        ]

      _ ->
        []
    end
  end

  defp part_divergence(plugin, mod, part, result) do
    # `to_string/1` on the lookup key: `c:Kiln.FieldType.input_part/0`'s `:key`
    # is typed as a `String.t()`, but nothing at runtime enforces a plugin
    # actually declares one — coercing here keeps the lookup working against
    # `composite_divergence/4`'s now-stringified `result` even if it doesn't.
    actual = result |> Map.get(to_string(part.key)) |> value_kind()
    expected = widget_kind(Map.get(part, :type, "text"))

    divergence_problem(
      plugin,
      mod,
      actual,
      expected,
      "for part #{inspect(part.key)}",
      "that part's widget"
    )
  end

  # Shared "cast/2 returns the wrong JSON kind" message, used by both the
  # scalar (`scalar_divergence/4`) and composite-part (`part_divergence/4`)
  # checks — `location`/`widget_ref` are the only wording that differs
  # between them ("a value its ... widget submits" vs "part ...").
  defp divergence_problem(plugin, mod, actual, expected, location, widget_ref) do
    if divergent?(actual, expected) do
      [
        "#{plugin.name()}: field type #{inspect(mod.name())}'s cast/2 returns #{actual} " <>
          "#{location}, but #{widget_ref} implies #{expected} — declare " <>
          "c:Kiln.FieldType.json_schema/1 if this is intentional"
      ]
    else
      []
    end
  end

  # `"unknown"` means `value_kind/1` couldn't classify `actual` at all (some
  # JSON-encodable struct neither it nor `widget_kind/1` has a case for, since
  # the latter never returns `"unknown"` itself) — that's inconclusive, not a
  # mismatch. Flagging it would false-positive on any plugin struct this table
  # simply hasn't been taught about yet, the same reason `Decimal` earned an
  # explicit `value_kind/1` clause instead of being left to fall through here.
  defp divergent?("unknown", _expected), do: false
  defp divergent?(actual, expected), do: actual != expected

  defp widget_sample("number"), do: "3"
  defp widget_sample("range"), do: "3"
  defp widget_sample("checkbox"), do: "true"
  defp widget_sample("date"), do: "2026-01-01"
  defp widget_sample("datetime-local"), do: "2026-01-01T00:00:00"
  defp widget_sample("month"), do: "2026-01"
  defp widget_sample("week"), do: "2026-W01"
  defp widget_sample("time"), do: "00:00"
  defp widget_sample("email"), do: "sample@example.com"
  defp widget_sample("url"), do: "https://example.com"
  defp widget_sample("color"), do: "#112233"
  defp widget_sample("tel"), do: "+15555550100"
  defp widget_sample(_), do: "sample"

  # Delegates to `KilnCMS.SchemaExport.html_input_json_type/1` rather than
  # reimplementing its clause table — that function already answers exactly
  # "what JSON type does this HTML input type imply", the same question this
  # module asks of a widget.
  defp widget_kind(html_type), do: SchemaExport.html_input_json_type(html_type)

  # Not the same question `KilnCMS.JsonSchemaValidator.type_matches?/2` answers,
  # despite the overlapping is_binary/is_boolean/is_number/is_list/is_map
  # cases: that function tests a value against one *named* schema type from an
  # already-JSON-serialized `:json` render; this classifies a *raw* value
  # straight off `cast/2`, which can still be a native `Date`/`DateTime`
  # struct (never a bare struct once it's gone through JSON). Two different
  # value domains, so not consolidated.
  defp value_kind(v) when is_binary(v), do: "string"
  defp value_kind(v) when is_boolean(v), do: "boolean"
  defp value_kind(v) when is_number(v), do: "number"
  defp value_kind(v) when is_list(v), do: "array"
  # `cast/2` may legitimately hand back a native date/time struct rather than
  # the ISO 8601 string it will eventually be delivered as — without this,
  # `is_map/1` below classified it as `"object"`, a false-positive divergence
  # against any ordinary string-typed widget.
  defp value_kind(%mod{}) when mod in [Date, DateTime, NaiveDateTime, Time], do: "string"
  # `Decimal` is the common non-builtin numeric struct a field type's cast/2
  # returns (currency, precision-sensitive amounts) without declaring
  # `json_schema/1` — `Jason.Encoder` renders it as a JSON *string*
  # (`Decimal.to_string/1`), matching what an ordinary text-input widget
  # already implies, so it belongs with the date/time family above rather
  # than falling through to `"unknown"`.
  defp value_kind(%Decimal{}), do: "string"
  defp value_kind(%_{}), do: "unknown"
  defp value_kind(v) when is_map(v), do: "object"
  defp value_kind(nil), do: "null"
  defp value_kind(_), do: "unknown"
end
