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
      collide (across core and all plugins);
    * plugin Oban queues don't redefine core queues;
    * nav paths and admin routes are well-formed (`/editor/...`).

  Exits non-zero with every violation listed, so it can gate CI/precommit.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl Mix.Task
  def run(_argv) do
    plugins = Application.get_env(:kiln_cms, :plugins, [])

    problems =
      Enum.flat_map(plugins, &plugin_problems/1) ++
        block_collisions(plugins) ++ field_type_problems(plugins) ++ queue_collisions(plugins)

    case problems do
      [] ->
        Mix.shell().info("#{length(plugins)} plugin(s) OK: #{names(plugins)}")

      problems ->
        Mix.raise("""
        Plugin configuration problems:

        #{Enum.map_join(problems, "\n", &("  * " <> &1))}
        """)
    end
  end

  defp names([]), do: "(none)"
  defp names(plugins), do: Enum.map_join(plugins, ", ", & &1.name())

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

    nav ++ routes
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

    core = KilnCMS.CMS.FieldTypes.core()

    collisions =
      declared
      |> Enum.filter(fn {_plugin, mod} ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :name, 0)
      end)
      |> Enum.group_by(fn {_plugin, mod} -> mod.name() end)
      |> Enum.flat_map(fn {name, owners} ->
        cond do
          name in core -> ["field type #{inspect(name)} collides with a core field type"]
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
end
