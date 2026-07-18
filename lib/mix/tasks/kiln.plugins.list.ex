defmodule Mix.Tasks.Kiln.Plugins.List do
  @shortdoc "List installed Kiln plugins with their catalog metadata"

  @moduledoc """
  Prints every plugin in `config :kiln_cms, :plugins` (decision D18) with its
  declared **catalog metadata** (`version`/`summary`/`homepage`) and its
  contribution surface (domains, blocks, field types, nav items, admin routes,
  Oban queues, supervision children).

  This is the local "discovery" half of the vetted-plugin marketplace — the
  data a catalog UI would render, straight from `Kiln.Plugins.manifests/0`
  (see `docs/plugin-extensibility.md`). It never loads or evaluates plugin
  code beyond the compile the build already did; use `mix kiln.plugins.doctor`
  to *verify* the install.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl Mix.Task
  def run(_argv) do
    case Kiln.Plugins.manifests() do
      [] ->
        Mix.shell().info("No plugins installed (config :kiln_cms, :plugins is empty).")

      manifests ->
        Mix.shell().info("#{length(manifests)} plugin(s) installed:\n")
        Enum.each(manifests, &Mix.shell().info(format(&1)))
    end

    :ok
  end

  defp format(m) do
    header = "* #{m.name}#{version(m.version)} — #{inspect(m.module)}"

    lines =
      [
        m.summary && "    #{m.summary}",
        m.homepage && "    #{m.homepage}",
        "    contributes: #{contributions(m)}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join([header | lines], "\n")
  end

  defp version(nil), do: ""
  defp version(v), do: " v#{v}"

  # Only mention what the plugin actually contributes, so the line reads clean
  # for a metadata-only plugin.
  defp contributions(m) do
    parts =
      [
        count("domain", length(m.domains)),
        count("block", length(m.blocks)),
        count("field type", length(m.field_types)),
        count("nav item", m.nav_items),
        count("admin route", m.admin_routes),
        count("Oban queue", length(m.oban_queues)),
        count("child", m.children)
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "nothing (metadata only)"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp count(_label, 0), do: nil
  defp count(label, 1), do: "1 #{label}"
  defp count("child", n), do: "#{n} children"
  defp count(label, n), do: "#{n} #{label}s"
end
