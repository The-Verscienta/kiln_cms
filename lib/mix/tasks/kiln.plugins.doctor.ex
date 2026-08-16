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
    # `plugin.blocks()`/`plugin.field_types()` are plain function calls a
    # plugin author can make arbitrarily expensive (a DB lookup, a hex.pm
    # fetch — nothing forbids it); each is otherwise called twice below
    # (once per check that needs it), so every check reads off these instead.
    blocks_by_plugin = Map.new(plugins, &{&1, &1.blocks()})
    field_types_by_plugin = Map.new(plugins, &{&1, &1.field_types()})

    problems =
      Enum.flat_map(plugins, &plugin_problems/1) ++
        block_collisions(plugins, blocks_by_plugin) ++
        field_type_problems(plugins, field_types_by_plugin) ++
        queue_collisions(plugins) ++
        block_schema_problems(plugins, blocks_by_plugin) ++
        field_type_schema_problems(plugins, field_types_by_plugin)

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
