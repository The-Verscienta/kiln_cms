defmodule KilnCMS.Staging.PluginScrub do
  @moduledoc """
  The staging scrub's rule for tables the core does not own (#2975): every
  table a plugin's or an overlay's Ash domains put in the database is purged,
  rewritten or kept with a reason, as the plugin declares in
  `c:Kiln.Plugin.staging_scrub/0`, or the scrub refuses to run.

  `KilnCMS.Staging.Scrub.dispositions/0` and its coverage test hold the core
  to the same rule; a plugin's tables are not in the core's schema, so they
  are checked here, against the database the scrub is about to change.

  ## Which tables are a plugin's

  The AshPostgres resources of each plugin's `c:Kiln.Plugin.domains/0`, and
  their AshPaperTrail version resources (a table of its own, holding every
  value a rewrite clears). A domain in `:ash_domains` that is neither the
  core's nor any plugin's is an overlay's: its tables are checked the same
  way and listed under "(no plugin)", and the only way to declare one is to
  move the domain into a plugin's `domains/0`.

  ## What is kept without an entry

  Content: a content type's table (`__kiln_content_type__/0`), its version
  table, and a graduated join table (`__kiln_join__/0`,
  `KilnCMS.CMS.JoinGraduation`), as long as no column looks personal
  (`personal_column?/2`). The core keeps its own content the same way.

  ## Before anything changes

  `plan!/1` reads every declaration strictly and checks it, then refuses,
  with nothing changed, when:

    * a callback raises, returns something other than a list, or returns an
      entry of the wrong shape;
    * an entry names a core table, a resource of another plugin, a resource
      not stored in Postgres, or one with `:context` multitenancy;
    * a rewrite names an attribute the resource lacks, its primary key, an
      identity's attribute, the tenant attribute or a `belongs_to` attribute,
      or a value that does not cast, or `nil` where `nil` is not allowed;
    * a table the plugins own exists and no entry names it;
    * a table the scrub keeps or rewrites has a foreign key that would block
      a purge (`ON DELETE RESTRICT` / `NO ACTION`), or one purge would be
      blocked by a table purged after it.

  A table that does not exist (a plugin installed but not migrated) is
  skipped and counts 0.

  Raw-migration tables with no Ash resource are not seen here: the scrub
  cannot know of them.
  """
  alias KilnCMS.Repo
  alias KilnCMS.Staging.Scrub

  # The core's domains, the ones `config/config.exs` registers. Listed rather
  # than found: `Mix.Tasks.Kiln.Plugins.Doctor.core_domains/0` finds them by
  # each module's source path, which a release strips from its BEAM files, so
  # in a release it finds none and every core table would read as an
  # overlay's. `test/kiln_cms/staging/plugin_scrub_test.exs` holds this list
  # to the doctor's.
  @core_domains [
    KilnCMS.Accounts,
    KilnCMS.Analytics,
    KilnCMS.Automation,
    KilnCMS.Backups,
    KilnCMS.Billing,
    KilnCMS.CMS,
    KilnCMS.Experiments,
    KilnCMS.Federation,
    KilnCMS.Firing,
    KilnCMS.History,
    KilnCMS.Mail,
    KilnCMS.Newsletter,
    KilnCMS.Notifications,
    KilnCMS.SearchIndex,
    KilnCMS.Security,
    KilnCMS.Social
  ]

  @typedoc "The summary key a plugin table's count is reported under."
  @type key :: {:plugin, plugin_name :: String.t(), table :: String.t()}

  @typedoc """
  One checked declaration, in the order `execute/1` runs it. `exists?` is set
  by `plan!/1`, which looked.
  """
  @type step :: %{
          optional(:exists?) => boolean(),
          plugin: module(),
          plugin_name: String.t(),
          resource: module(),
          schema: String.t(),
          table: String.t(),
          action: :purge | {:rewrite, keyword()} | {:keep, String.t()}
        }

  @doc "The core's Ash domains, whose tables `KilnCMS.Staging.Scrub` decides."
  @spec core_domains() :: [module()]
  def core_domains, do: @core_domains

  @doc """
  Whether a column's name or Postgres type (`udt_name`) says it may hold
  personal data: an address, an IP or network, a user agent, a phone, a
  remote actor. Shared by the coverage test's check of the core's kept
  tables and by the default that keeps a plugin's content tables.
  """
  @spec personal_column?(String.t(), String.t() | nil) :: boolean()
  def personal_column?(_name, udt) when udt in ["bool", "boolean"], do: false

  def personal_column?(name, udt) do
    udt in ["inet", "cidr", "_inet", "_cidr"] or Regex.match?(personal_column_pattern(), name)
  end

  # Anchored at the end so `membership` is not an `ip` and `name` is not an
  # address; plural forms included (`cidrs`, `contacts`).
  defp personal_column_pattern do
    ~r/(^|_)(emails?|ips?|cidrs?|user_agents?|actor_uris?|inbox_uris?|endpoints?|p256dh|grantors?|actor_names?|phones?|contacts?)$/
  end

  @doc """
  Check every plugin's declaration against the database and return the steps
  to run, in order. Raises, having changed nothing, on any reason listed in
  the moduledoc.

  ## Options

    * `:plugins` — default `Kiln.Plugins.all/0`.
    * `:ash_domains` — default `config :kiln_cms, :ash_domains`.
  """
  @spec plan!(keyword()) :: [step()]
  def plan!(opts \\ []) do
    analysis = opts |> plugins() |> analyze(ash_domains(opts))
    refuse!(analysis.problems, "these staging_scrub/0 declarations are not usable")

    existing = analysis |> existing_tables() |> MapSet.new()
    exists? = &MapSet.member?(existing, qualified(&1))

    undeclared = Enum.filter(analysis.undeclared, exists?)
    refuse!(Enum.map(undeclared, &undeclared_problem/1), undeclared_heading())

    steps = Enum.map(analysis.steps, &Map.put(&1, :exists?, exists?.(&1)))
    refuse!(foreign_key_problems(steps, Enum.filter(analysis.defaults, exists?)), fk_heading())

    steps
  end

  @doc """
  Run checked steps (`plan!/1`), returning each purged or rewritten table's
  row count under its `t:key/0`. A kept table, and one that does not exist,
  is not touched.
  """
  @spec execute([step()]) :: %{key() => non_neg_integer()}
  def execute(steps) do
    Enum.reduce(steps, %{}, fn
      %{action: {:keep, _reason}}, acc ->
        acc

      # Two resources over one table share its key. Each purge or rewrite
      # reaches every row, so the larger count is the table's.
      step, acc ->
        count = run_step(step)
        Map.update(acc, key(step), count, &max(&1, count))
    end)
  end

  defp run_step(%{exists?: false}), do: 0

  defp run_step(%{action: :purge} = step) do
    {count, _} = Repo.delete_all(step.table, prefix: step.schema)
    count
  end

  defp run_step(%{action: {:rewrite, set}} = step) do
    {count, _} = Repo.update_all(step.table, [set: set], prefix: step.schema)
    count
  end

  @doc """
  The checked declarations, without the database: `KilnCMS.Staging.Scrub.dispositions/1`
  reads its plugin rows from these. Raises on a declaration `plan!/1` would
  refuse.
  """
  @spec steps!([module()], [module()]) :: [step()]
  def steps!(plugins, ash_domains) do
    analysis = analyze(plugins, ash_domains)
    refuse!(analysis.problems, "these staging_scrub/0 declarations are not usable")
    analysis.steps
  end

  @doc """
  Every plugin table a scrubbed clone keeps, mapped to the reason: the
  declared `:keep` entries and the content tables kept without one.
  """
  @spec kept([module()], [module()]) :: %{String.t() => String.t()}
  def kept(plugins, ash_domains) do
    analysis = analyze(plugins, ash_domains)

    declared =
      for %{action: {:keep, reason}} = step <- analysis.steps,
          into: %{},
          do: {display(step), reason}

    analysis.defaults
    |> Map.new(&{display(&1), &1.reason})
    |> Map.merge(declared)
  end

  @doc """
  What is wrong with the plugins' declarations, one line each; `[]` when they
  are usable. `mix kiln.plugins.doctor` reports these.
  """
  @spec problems([module()], [module()]) :: [String.t()]
  def problems(plugins, ash_domains), do: analyze(plugins, ash_domains).problems

  @doc """
  The tables the plugins and overlays own that no entry names and that are
  not kept as content. `plan!/1` refuses while one exists; the doctor notes
  them.
  """
  @spec undeclared([module()], [module()]) :: [String.t()]
  def undeclared(plugins, ash_domains),
    do: Enum.map(analyze(plugins, ash_domains).undeclared, &undeclared_problem/1)

  @doc "The summary key `step`'s count is reported under."
  @spec key(step()) :: key()
  def key(step), do: {:plugin, step.plugin_name, display(step)}

  # ── analysis ──────────────────────────────────────────────────────────────

  defp plugins(opts), do: Keyword.get_lazy(opts, :plugins, &Kiln.Plugins.all/0)

  defp ash_domains(opts),
    do:
      Keyword.get_lazy(opts, :ash_domains, fn ->
        Application.get_env(:kiln_cms, :ash_domains, [])
      end)

  defp analyze(plugins, ash_domains) do
    core_tables = core_tables()
    owned = owned(plugins, ash_domains, core_tables)
    by_resource = Map.new(owned, &{&1.resource, &1})

    {steps, entry_problems} =
      plugins
      |> Enum.flat_map(&declarations(&1, by_resource, core_tables))
      |> Enum.split_with(&match?({:ok, _}, &1))

    steps = Enum.map(steps, fn {:ok, step} -> step end)
    declared = MapSet.new(steps, &qualified/1)

    {defaults, undeclared} =
      owned
      |> Enum.reject(&(qualified(&1) in declared))
      |> Enum.split_with(&(&1.reason != nil))

    problems =
      Enum.map(entry_problems, fn {:error, problem} -> problem end) ++
        context_problems(owned) ++ duplicate_problems(steps)

    %{steps: steps, problems: problems, defaults: defaults, undeclared: undeclared}
  end

  # Every table the plugins and the overlay's own domains put in the database.
  defp owned(plugins, ash_domains, core_tables) do
    claimed =
      for plugin <- plugins,
          domain <- plugin_domains(plugin),
          domain not in @core_domains,
          do: {domain, plugin}

    claimed_domains = Enum.map(claimed, &elem(&1, 0))

    unclaimed =
      for domain <- ash_domains,
          domain not in @core_domains and domain not in claimed_domains,
          do: {domain, nil}

    (claimed ++ unclaimed)
    |> Enum.filter(fn {domain, _plugin} -> domain?(domain) end)
    |> Enum.flat_map(fn {domain, plugin} ->
      domain |> Ash.Domain.Info.resources() |> with_versions() |> Enum.map(&{&1, plugin})
    end)
    |> Enum.uniq_by(fn {resource, _plugin} -> resource end)
    |> Enum.filter(fn {resource, _plugin} -> postgres?(resource) and table(resource) end)
    |> Enum.map(fn {resource, plugin} -> owned_table(resource, plugin) end)
    # An overlay resource over a core table (a report over `entries`, say) is
    # the core's to scrub, not the overlay's to declare.
    |> Enum.reject(&(&1.schema == "public" and MapSet.member?(core_tables, &1.table)))
  end

  defp plugin_domains(plugin) do
    if Code.ensure_loaded?(plugin) and function_exported?(plugin, :domains, 0),
      do: plugin.domains(),
      else: []
  end

  defp domain?(domain), do: Code.ensure_loaded?(domain) and Spark.Dsl.is?(domain, Ash.Domain)

  defp with_versions(resources) do
    Enum.flat_map(resources, fn resource ->
      case version_resource(resource) do
        nil -> [resource]
        version -> [resource, version]
      end
    end)
  end

  defp version_resource(resource) do
    if AshPaperTrail.Resource in Spark.extensions(resource) and
         AshPaperTrail.Resource.Info.version_resource?(resource) do
      AshPaperTrail.Resource.Info.version_resource(resource)
    end
  end

  defp owned_table(resource, plugin) do
    %{
      resource: resource,
      plugin: plugin,
      plugin_name: plugin && plugin_name(plugin),
      schema: schema(resource),
      table: table(resource),
      reason: content_reason(resource)
    }
  end

  # Content is kept as the core keeps its own, unless a column says otherwise.
  defp content_reason(resource) do
    reason =
      cond do
        content_type?(resource) -> "content"
        content_type?(version_source(resource)) -> "content history"
        exports?(resource, :__kiln_join__) -> "content: graduated join"
        true -> nil
      end

    if reason && not personal_columns?(resource), do: reason
  end

  defp content_type?(nil), do: false
  defp content_type?(resource), do: exports?(resource, :__kiln_content_type__)

  defp exports?(module, function),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, 0)

  # AshPaperTrail names the twin `Source.Version` unless told otherwise.
  defp version_source(resource) do
    with ["Version" | rest] when rest != [] <- resource |> Module.split() |> Enum.reverse(),
         source = rest |> Enum.reverse() |> Module.concat(),
         true <- Code.ensure_loaded?(source) and Ash.Resource.Info.resource?(source),
         ^resource <- version_resource(source) do
      source
    else
      _ -> nil
    end
  end

  defp personal_columns?(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.any?(fn attribute ->
      column = to_string(attribute.source || attribute.name)
      personal_column?(column, udt(Ash.Type.storage_type(attribute.type, attribute.constraints)))
    end)
  end

  defp udt({:array, type}), do: "_" <> udt(type)
  defp udt(type), do: to_string(type)

  # ── declarations ──────────────────────────────────────────────────────────

  defp declarations(plugin, by_resource, core_tables) do
    name = plugin_name(plugin)

    case read_declaration(plugin) do
      {:ok, entries} ->
        Enum.map(entries, &entry(&1, plugin, name, by_resource, core_tables))

      {:error, problem} ->
        [{:error, "#{name}: #{problem}"}]
    end
  end

  # Strict, unlike the display read (`Kiln.Plugins.staging_scrub_of/1`): a
  # declaration that cannot be read is a refusal, never "nothing to scrub".
  # The rescue turns a plugin's crash into one line of the refusal, beside
  # every other plugin's.
  defp read_declaration(plugin) do
    if exports?(plugin, :staging_scrub) do
      case plugin.staging_scrub() do
        entries when is_list(entries) -> {:ok, entries}
        other -> {:error, "staging_scrub/0 must return a list, not #{inspect(other)}"}
      end
    else
      # A plugin built against kiln_plugin before 1.5 declares nothing; its
      # tables, if it has any, are then undeclared.
      {:ok, []}
    end
  rescue
    error -> {:error, "staging_scrub/0 raised: " <> Exception.message(error)}
  catch
    kind, reason -> {:error, "staging_scrub/0 failed: #{inspect(kind)} #{inspect(reason)}"}
  end

  defp entry({:purge, resource}, plugin, name, by_resource, core_tables) when is_atom(resource) do
    with {:ok, owned} <- own(resource, plugin, name, by_resource, core_tables) do
      {:ok, step(owned, plugin, name, :purge)}
    end
  end

  defp entry({:rewrite, resource, [set: set]}, plugin, name, by_resource, core_tables)
       when is_atom(resource) do
    with {:ok, owned} <- own(resource, plugin, name, by_resource, core_tables),
         {:ok, columns} <- rewrite_set(resource, set, name) do
      {:ok, step(owned, plugin, name, {:rewrite, columns})}
    end
  end

  defp entry({:keep, resource, reason}, plugin, name, by_resource, core_tables)
       when is_atom(resource) and is_binary(reason) do
    with {:ok, owned} <- own(resource, plugin, name, by_resource, core_tables) do
      if String.trim(reason) == "" do
        {:error,
         "#{name}: {:keep, #{inspect(resource)}, reason} needs a reason saying why a clone may keep its rows"}
      else
        {:ok, step(owned, plugin, name, {:keep, reason})}
      end
    end
  end

  defp entry(other, _plugin, name, _by_resource, _core_tables) do
    {:error,
     "#{name}: staging_scrub/0 entry #{inspect(other)} is not {:purge, Resource}, " <>
       ~s|{:rewrite, Resource, set: [attribute: value]} or {:keep, Resource, "reason"}|}
  end

  defp step(owned, plugin, name, action) do
    %{
      plugin: plugin,
      plugin_name: name,
      resource: owned.resource,
      schema: owned.schema,
      table: owned.table,
      action: action
    }
  end

  defp own(resource, plugin, name, by_resource, core_tables) do
    with :ok <- postgres_table(resource, name) do
      owned_by(resource, plugin, name, Map.get(by_resource, resource), core_tables)
    end
  end

  defp postgres_table(resource, name) do
    cond do
      not (Code.ensure_loaded?(resource) and Ash.Resource.Info.resource?(resource)) ->
        {:error, "#{name}: #{inspect(resource)} in staging_scrub/0 is not an Ash resource"}

      not postgres?(resource) or is_nil(table(resource)) ->
        {:error, "#{name}: #{inspect(resource)} is not stored in a Postgres table (AshPostgres)"}

      true ->
        :ok
    end
  end

  defp owned_by(resource, plugin, name, owned, core_tables) do
    cond do
      Ash.Resource.Info.domain(resource) in @core_domains or
          MapSet.member?(core_tables, table(resource)) ->
        {:error,
         "#{name}: #{inspect(resource)} is the core table #{table(resource)}; " <>
           "the core scrub decides what happens to its own tables"}

      owned == nil or owned.plugin != plugin ->
        {:error,
         "#{name}: #{inspect(resource)} is not a resource of #{name}'s domains/0" <>
           owner_note(owned)}

      true ->
        {:ok, owned}
    end
  end

  defp owner_note(%{plugin_name: other}) when is_binary(other), do: " (it is #{other}'s)"
  defp owner_note(_owned), do: ""

  # ── rewrites ──────────────────────────────────────────────────────────────

  defp rewrite_set(resource, set, name) do
    cond do
      not Keyword.keyword?(set) or set == [] ->
        {:error,
         "#{name}: the rewrite of #{inspect(resource)} needs set: [attribute: value, ...], " <>
           "not #{inspect(set)}"}

      length(Enum.uniq(Keyword.keys(set))) != length(set) ->
        {:error, "#{name}: the rewrite of #{inspect(resource)} sets an attribute twice"}

      true ->
        set
        |> Enum.map(fn {attribute, value} -> column(resource, attribute, value, name) end)
        |> collect()
    end
  end

  defp collect(results) do
    case for({:error, problem} <- results, do: problem) do
      [] -> {:ok, Enum.map(results, fn {:ok, column} -> column end)}
      problems -> {:error, Enum.join(problems, "; ")}
    end
  end

  # A rewrite cannot change what identifies a row or ties it to another: the
  # result would collide with a constraint, or point at nothing. Those tables
  # are purged instead.
  defp column(resource, name_of_attribute, value, name) do
    attribute = Ash.Resource.Info.attribute(resource, name_of_attribute)
    subject = "#{name}: #{inspect(resource)}.#{name_of_attribute}"

    with :ok <- rewritable(resource, attribute, name_of_attribute),
         {:ok, native} <- native_value(attribute, value) do
      {:ok, {attribute.source || attribute.name, native}}
    else
      {:error, why} -> {:error, "#{subject} cannot be rewritten: #{why}"}
    end
  end

  defp rewritable(_resource, nil, _attribute), do: {:error, "no such attribute"}

  defp rewritable(resource, attribute, name) do
    identity = Enum.find(Ash.Resource.Info.identities(resource), &(name in &1.keys))

    belongs_to =
      Enum.find(
        Ash.Resource.Info.relationships(resource),
        &(&1.type == :belongs_to and &1.source_attribute == name)
      )

    cond do
      attribute.primary_key? ->
        {:error, "it is the primary key; purge the table instead"}

      identity ->
        {:error, "it is part of the identity #{inspect(identity.name)}; purge the table instead"}

      Ash.Resource.Info.multitenancy_attribute(resource) == name ->
        {:error, "it is the tenant attribute; purge the table instead"}

      belongs_to ->
        {:error,
         "it is the belongs_to attribute of #{inspect(belongs_to.name)}; purge the table instead"}

      true ->
        :ok
    end
  end

  defp native_value(attribute, nil) do
    if attribute.allow_nil?, do: {:ok, nil}, else: {:error, "it does not allow nil"}
  end

  defp native_value(attribute, value) do
    %{type: type, constraints: constraints} = attribute

    with {:ok, cast} <- cast(type, value, constraints),
         {:ok, cast} <- Ash.Type.apply_constraints(type, cast, constraints),
         {:ok, native} <- Ash.Type.dump_to_native(type, cast, constraints) do
      native_value(attribute, native, value)
    else
      _ -> {:error, "#{inspect(value)} is not a valid #{inspect(type)}"}
    end
  end

  # A value that casts to nil (an empty string, say) is held to allow_nil? too.
  defp native_value(%{allow_nil?: false}, nil, value),
    do: {:error, "#{inspect(value)} casts to nil, which it does not allow"}

  defp native_value(_attribute, native, _value), do: {:ok, native}

  defp cast(type, value, constraints) do
    case Ash.Type.cast_input(type, value, constraints) do
      {:ok, cast} -> {:ok, cast}
      _invalid -> :error
    end
  end

  # ── checks over the whole declaration ─────────────────────────────────────

  defp context_problems(owned) do
    for %{resource: resource} = table <- owned,
        Ash.Resource.Info.multitenancy_strategy(resource) == :context do
      "#{table.plugin_name || "(no plugin)"}: #{inspect(resource)} uses :context multitenancy " <>
        "(a schema per tenant), which the staging scrub cannot reach"
    end
  end

  # One table, one decision: two plugins on a table, one resource declared
  # twice, or a table both purged and kept would leave the outcome to the
  # order. Two resources of one plugin over one table, declared alike, are fine.
  defp duplicate_problems(steps) do
    steps
    |> Enum.group_by(&qualified/1)
    |> Enum.flat_map(fn {_table, [first | _] = entries} ->
      plugins = entries |> Enum.map(& &1.plugin_name) |> Enum.uniq()
      resources = Enum.map(entries, & &1.resource)
      kinds = entries |> Enum.map(&kind/1) |> Enum.uniq()

      cond do
        length(plugins) > 1 ->
          [
            "table #{display(first)} is declared by more than one plugin: #{Enum.join(plugins, ", ")}"
          ]

        length(Enum.uniq(resources)) < length(resources) ->
          [
            "#{first.plugin_name}: #{inspect(first.resource)} has more than one staging_scrub/0 entry"
          ]

        length(kinds) > 1 ->
          [
            "#{first.plugin_name}: table #{display(first)} is declared as both #{Enum.join(kinds, " and ")}"
          ]

        true ->
          []
      end
    end)
  end

  defp kind(%{action: :purge}), do: :purge
  defp kind(%{action: {kind, _}}), do: kind

  # ── the database ──────────────────────────────────────────────────────────

  defp existing_tables(analysis) do
    case (analysis.steps ++ analysis.defaults ++ analysis.undeclared)
         |> Enum.map(&qualified/1)
         |> Enum.uniq() do
      [] -> []
      names -> existing_base_tables(names)
    end
  end

  defp existing_base_tables(names) do
    # Base tables only: a resource over a view has no rows of its own.
    %{rows: rows} =
      Repo.query!(
        """
        SELECT n.nspname || '.' || c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p') AND n.nspname || '.' || c.relname = ANY($1)
        """,
        [names]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  # A purge that a foreign key blocks fails half-way through the scrub, with
  # some tables emptied and others not, so it is refused before anything runs.
  defp foreign_key_problems(steps, defaults) do
    existing_steps = Enum.filter(steps, & &1.exists?)

    plugin_purges =
      existing_steps
      |> Enum.filter(&(&1.action == :purge))
      |> Enum.with_index()
      |> Map.new(fn {step, index} -> {qualified(step), index} end)

    kept =
      existing_steps
      |> Enum.reject(&(&1.action == :purge))
      |> Enum.concat(defaults)
      |> MapSet.new(&qualified/1)

    emptied_by_core = core_emptied_tables()

    for [child, parent, constraint] <-
          blocking_foreign_keys(Map.keys(plugin_purges) ++ MapSet.to_list(kept)),
        child != parent,
        problem =
          foreign_key_problem(child, parent, constraint, kept, plugin_purges, emptied_by_core),
        do: problem
  end

  defp foreign_key_problem(child, parent, constraint, kept, plugin_purges, emptied_by_core) do
    emptied? = Map.has_key?(plugin_purges, parent) or MapSet.member?(emptied_by_core, parent)

    cond do
      MapSet.member?(kept, child) and emptied? ->
        "#{child} is kept, but its foreign key #{constraint} to #{parent}, which the scrub " <>
          "empties, blocks the delete (ON DELETE RESTRICT / NO ACTION). Purge #{child} too, " <>
          "or make the key ON DELETE CASCADE or SET NULL"

      Map.has_key?(plugin_purges, child) and Map.has_key?(plugin_purges, parent) and
          plugin_purges[parent] < plugin_purges[child] ->
        "#{child} is purged after #{parent}, and its foreign key #{constraint} blocks " <>
          "purging #{parent} first. Put {:purge, ...} for #{child} before #{parent}'s entry"

      true ->
        nil
    end
  end

  defp blocking_foreign_keys([]), do: []

  defp blocking_foreign_keys(children) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT cn.nspname || '.' || c.relname, fn.nspname || '.' || f.relname, con.conname
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace cn ON cn.oid = c.relnamespace
        JOIN pg_class f ON f.oid = con.confrelid
        JOIN pg_namespace fn ON fn.oid = f.relnamespace
        WHERE con.contype = 'f' AND con.confdeltype IN ('r', 'a')
          AND cn.nspname || '.' || c.relname = ANY($1)
        ORDER BY 1, 2, 3
        """,
        [children]
      )

    rows
  end

  # The core tables the scrub deletes rows from: its purges, and what
  # anonymizing every account deletes.
  defp core_emptied_tables do
    for {table, {kind, _key}} <- Scrub.core_dispositions(),
        kind in [:purged, :via_anonymization],
        into: MapSet.new(),
        do: qualified_core(table)
  end

  defp qualified_core("oban_jobs" = table) do
    prefix = :kiln_cms |> Application.get_env(Oban, []) |> Keyword.get(:prefix, "public")
    prefix <> "." <> table
  end

  defp qualified_core(table), do: "public." <> table

  defp core_tables do
    core_resources =
      for domain <- @core_domains,
          domain?(domain),
          resource <- Ash.Domain.Info.resources(domain),
          postgres?(resource),
          table = table(resource),
          do: table

    Scrub.core_dispositions() |> Map.keys() |> Enum.concat(core_resources) |> MapSet.new()
  end

  # ── refusals ──────────────────────────────────────────────────────────────

  defp refuse!([], _heading), do: :ok

  defp refuse!(problems, heading) do
    raise """
    Refusing to scrub: #{heading}.

      * #{Enum.join(problems, "\n  * ")}

    Nothing has been changed. See c:Kiln.Plugin.staging_scrub/0 and
    docs/staging-environments.md.
    """
  end

  defp undeclared_heading do
    "these tables of installed plugins and of the overlay have no staging_scrub/0 entry, " <>
      "so the scrub cannot tell whether a production clone may keep their rows. Add " <>
      ~s|{:purge, Resource}, {:rewrite, Resource, set: [...]} or {:keep, Resource, "reason"} | <>
      "for each to its plugin's staging_scrub/0"
  end

  defp fk_heading, do: "a foreign key would stop the scrub half-way"

  defp undeclared_problem(%{plugin_name: nil} = table) do
    "(no plugin): #{inspect(table.resource)} (table #{display(table)}). No plugin's domains/0 " <>
      "claims its domain #{inspect(Ash.Resource.Info.domain(table.resource))}, so nothing can " <>
      "declare it: move the domain into a plugin's domains/0 and declare the table there"
  end

  defp undeclared_problem(table),
    do: "#{table.plugin_name}: #{inspect(table.resource)} (table #{display(table)})"

  # ── helpers ───────────────────────────────────────────────────────────────

  defp plugin_name(plugin) do
    if exports?(plugin, :name), do: plugin.name(), else: inspect(plugin)
  end

  defp postgres?(resource), do: Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp schema(resource), do: AshPostgres.DataLayer.Info.schema(resource) || "public"

  defp qualified(%{schema: schema, table: table}), do: schema <> "." <> table

  # The name a table is reported under: bare in `public`, as the core's are.
  defp display(%{schema: "public", table: table}), do: table
  defp display(table), do: qualified(table)
end
