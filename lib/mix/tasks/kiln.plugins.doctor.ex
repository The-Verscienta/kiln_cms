defmodule Mix.Tasks.Kiln.Plugins.Doctor do
  @shortdoc "Verify installed Kiln plugins against the host configuration"

  @moduledoc """
  Sanity-checks every plugin in `config :kiln_cms, :plugins` (decision D18):

    * the module implements `Kiln.Plugin`;
    * every declared domain is registered in **both** `:ash_domains` and
      `:content_domains` (plugins can't auto-wire those — Ash's own mix tasks
      read them straight from config, so the install step must add them);
    * block type names don't collide (across core and all plugins);
    * field-type modules implement `Kiln.FieldType` and their names don't
      collide (across core, the built-in types, and all plugins);
    * plugin Oban queues don't redefine core queues;
    * nav paths and admin routes are well-formed (`/editor/...`);
    * a block's `:json` render agrees with its exported schema (#937) —
      the same conformance check `test/kiln/block/json_schema_test.exs` runs
      for core blocks, which a third-party plugin never executes;
    * a field type whose `cast/2` output doesn't match what its editor widget
      implies declares `c:Kiln.FieldType.json_schema/1` to say so (#937), the
      same reason `KilnCMS.CMS.FieldTypes.Recurrence` has one.

  Exits non-zero with every violation listed, so it can gate CI/precommit.
  """
  use Mix.Task

  alias Kiln.Block.Info
  alias Kiln.Block.JsonSchema
  alias Kiln.Block.Sample
  alias KilnCMS.Blocks
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.JsonSchemaValidator
  alias KilnCMS.SchemaExport

  @requirements ["compile"]

  @impl Mix.Task
  def run(_argv) do
    plugins = Application.get_env(:kiln_cms, :plugins, [])

    problems =
      Enum.flat_map(plugins, &plugin_problems/1) ++
        block_collisions(plugins) ++
        field_type_problems(plugins) ++
        queue_collisions(plugins) ++
        block_schema_problems(plugins) ++ field_type_schema_problems(plugins)

    case problems do
      [] ->
        Mix.shell().info("#{length(plugins)} plugin(s) OK: #{names(plugins)}")

      problems ->
        Mix.raise("""
        Plugin configuration problems:

        #{Enum.map_join(problems, "\n", &bulleted/1)}
        """)
    end
  end

  defp names([]), do: "(none)"
  defp names(plugins), do: Enum.map_join(plugins, ", ", & &1.name())

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

  defp block_collisions(plugins) do
    core = KilnCMS.Blocks.core_types()

    plugins
    |> Enum.flat_map(fn plugin ->
      for mod <- plugin.blocks(), do: {Kiln.Block.Info.name(mod), plugin.name()}
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
  defp field_type_problems(plugins) do
    declared =
      Enum.flat_map(plugins, fn plugin ->
        for mod <- plugin.field_types(), do: {plugin, mod}
      end)

    contract =
      for {plugin, mod} <- declared,
          not (Code.ensure_loaded?(mod) and function_exported?(mod, :cast, 2) and
                 function_exported?(mod, :name, 0)) do
        "#{plugin.name()}: field type #{inspect(mod)} does not implement Kiln.FieldType"
      end

    # Core types *and* the in-tree `Kiln.FieldType` implementations
    # (`:geolocation`, `:computed`) are off limits — a plugin claiming either
    # would shadow it in the registry.
    reserved = KilnCMS.CMS.FieldTypes.reserved()

    collisions =
      declared
      |> Enum.filter(fn {_plugin, mod} ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :name, 0)
      end)
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

  # ── block :json render vs exported schema (#937) ───────────────────────────
  #
  # Mirrors `test/kiln/block/json_schema_test.exs`'s "conformance" describe —
  # build a populated struct, render it to `:json`, validate against the same
  # `$defs` `GET /api/schema` publishes. That test only ever runs core blocks
  # plus the in-repo test-suite fixture plugin; a hex-dep plugin's blocks are
  # in `Blocks.modules()` at boot but never sit in a `mix test` run, so this
  # is the only place the check reaches them.
  #
  # `$defs` is built from `plugins` (this task's own argument) rather than
  # `Kiln.Plugins.blocks()`: the latter is `Application.compile_env`, baked
  # when `lib/kiln/plugins.ex` compiled, so every other check in this task
  # already reads `plugin.blocks()` off the runtime config instead — the same
  # reason `mix kiln.plugins.doctor` is testable via `Application.put_env` at
  # all. `Blocks.core_modules/0` supplies "core blocks" directly rather than
  # backing them out of `Blocks.modules() -- Kiln.Plugins.blocks()`.
  #
  # Plugin blocks are listed *before* the core set in the concatenation:
  # `JsonSchema.block_modules/1` (which `defs/1` calls) dedupes by `_type` via
  # `Enum.uniq_by/2`, which keeps the *first* module for a given name. A
  # plugin block whose `_type` collides with a core block's — already flagged
  # separately by `block_collisions/1` — must still resolve to the plugin's
  # own schema here, not the core block's, or its conformance check would
  # silently validate against the wrong shape.
  defp block_schema_problems(plugins) do
    blocks_by_plugin = Map.new(plugins, &{&1, &1.blocks()})
    plugin_blocks = blocks_by_plugin |> Map.values() |> List.flatten()
    defs = JsonSchema.defs(Enum.uniq(plugin_blocks ++ Blocks.core_modules()))
    document = %{"$defs" => defs}

    Enum.flat_map(plugins, fn plugin ->
      Enum.flat_map(blocks_by_plugin[plugin], &block_render_problems(plugin, &1, defs, document))
    end)
  end

  defp block_render_problems(plugin, module, defs, document) do
    with true <- Code.ensure_loaded?(module) and function_exported?(module, :render, 2),
         name when not is_nil(name) <- Info.name(module),
         schema when not is_nil(schema) <- Map.get(defs, JsonSchema.def_name(name)) do
      # Both the populated branch (every field carrying a value) and the empty
      # branch (`struct(module)`) — a block like `KilnCMS.Blocks.Video` takes a
      # different `:json` path depending on which fields are present, and the
      # core conformance test checks both for exactly that reason.
      [Sample.populated(module), struct(module)]
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
      [
        "#{plugin.name()}: block #{inspect(module)} raised while checking its :json render " <>
          "against its schema (#{Exception.message(e)})"
      ]
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
  defp field_type_schema_problems(plugins) do
    Enum.flat_map(plugins, fn plugin ->
      plugin.field_types()
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

  defp field_type_divergence(plugin, mod) do
    definition =
      struct(FieldDefinition,
        name: "sample_field",
        field_type: mod.name(),
        required: false,
        options: []
      )

    parts = if function_exported?(mod, :input_parts, 1), do: mod.input_parts(definition), else: []

    if parts == [] do
      scalar_divergence(plugin, mod, definition)
    else
      composite_divergence(plugin, mod, definition, parts)
    end
  rescue
    e ->
      # `inspect(mod)` rather than `mod.name()`: the exception being reported
      # may be `mod.name()` itself raising (it runs above, building
      # `definition`), and calling it again here would just raise past the
      # rescue instead of producing a message.
      [
        "#{plugin.name()}: field type #{inspect(mod)} raised while checking cast/2 " <>
          "(#{Exception.message(e)})"
      ]
  end

  defp scalar_divergence(plugin, mod, definition) do
    html_type = if function_exported?(mod, :input_type, 0), do: mod.input_type(), else: "text"

    case mod.cast(widget_sample(html_type), definition) do
      {:ok, value} ->
        expected = widget_kind(html_type)
        actual = value_kind(value)

        if actual == expected do
          []
        else
          [
            "#{plugin.name()}: field type #{inspect(mod.name())}'s cast/2 returns #{actual} for " <>
              "a value its #{inspect(html_type)} widget submits, but that widget implies " <>
              "#{expected} — declare c:Kiln.FieldType.json_schema/1 if this is intentional"
          ]
        end

      _ ->
        []
    end
  end

  defp composite_divergence(plugin, mod, definition, parts) do
    sample =
      Map.new(parts, fn part -> {part.key, widget_sample(Map.get(part, :type, "text"))} end)

    case mod.cast(sample, definition) do
      {:ok, result} when is_map(result) ->
        Enum.flat_map(parts, &part_divergence(plugin, mod, &1, result))

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
    expected = widget_kind(Map.get(part, :type, "text"))
    actual = result |> Map.get(part.key) |> value_kind()

    if actual == expected do
      []
    else
      [
        "#{plugin.name()}: field type #{inspect(mod.name())}'s cast/2 returns #{actual} " <>
          "for part #{inspect(part.key)}, but that part's widget implies #{expected} — " <>
          "declare c:Kiln.FieldType.json_schema/1 if this is intentional"
      ]
    end
  end

  defp widget_sample("number"), do: "3"
  defp widget_sample("range"), do: "3"
  defp widget_sample("checkbox"), do: "true"
  defp widget_sample(_), do: "sample"

  # Delegates to `KilnCMS.SchemaExport.html_input_json_type/1` rather than
  # reimplementing its clause table — that function already answers exactly
  # "what JSON type does this HTML input type imply", the same question this
  # module asks of a widget.
  defp widget_kind(html_type), do: SchemaExport.html_input_json_type(html_type)

  defp value_kind(v) when is_binary(v), do: "string"
  defp value_kind(v) when is_boolean(v), do: "boolean"
  defp value_kind(v) when is_number(v), do: "number"
  defp value_kind(v) when is_list(v), do: "array"
  # `cast/2` may legitimately hand back a native date/time struct rather than
  # the ISO 8601 string it will eventually be delivered as — without this,
  # `is_map/1` below classified it as `"object"`, a false-positive divergence
  # against any ordinary string-typed widget.
  defp value_kind(%mod{}) when mod in [Date, DateTime, NaiveDateTime, Time], do: "string"
  defp value_kind(%_{}), do: "unknown"
  defp value_kind(v) when is_map(v), do: "object"
  defp value_kind(nil), do: "null"
  defp value_kind(_), do: "unknown"
end
