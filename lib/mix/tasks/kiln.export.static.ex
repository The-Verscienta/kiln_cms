defmodule Mix.Tasks.Kiln.Export.Static do
  @shortdoc "Export fired artifacts to a static directory tree for CDN/edge deploys"
  @moduledoc """
  First-class static / edge export (#353). Copies every published document's
  immutable fired `:web`/`:json`/`:json_ld` artifacts to a static directory tree
  you can `rsync` to a CDN, bake into an edge cache, or ship to an air-gapped
  host. Reuses the firing engine — no re-render — so the export is a faithful
  snapshot of what the live headless API serves.

      mix kiln.export.static <out_dir> [--surface web,json,json_ld,llm] [--base-url URL]

  Examples:

      mix kiln.export.static ./_static
      mix kiln.export.static /var/www/edge --surface web
      mix kiln.export.static ./_static --base-url https://cdn.example.com

  Existing files are overwritten; content deleted since a prior export is not
  pruned (diff the written `index.json` to reconcile). See docs/static-export.md.
  """
  use Mix.Task

  alias KilnCMS.Firing.StaticExport

  @requirements ["app.start"]

  @switches [surface: :string, base_url: :string, org_id: :string, all_orgs: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    case positional do
      [out_dir | _] ->
        base_opts =
          []
          |> put_surfaces(opts[:surface])
          |> put_base_url(opts[:base_url])

        # Static export is per-site (#419). Default: the default org. `--org_id`
        # exports one specific site; `--all_orgs` fans out into per-org
        # subtrees so a fleet export can't silently drop non-default sites.
        result = run_export(out_dir, base_opts, opts)

        Mix.shell().info(
          "Exported #{result.count} document(s) " <>
            "(#{Enum.map_join(result.surfaces, "/", &to_string/1)}) to #{result.out_dir}" <>
            skipped_note(result.skipped)
        )

      [] ->
        Mix.raise("Usage: mix kiln.export.static <out_dir> [--surface web,json,json_ld,llm]")
    end
  end

  # `--all_orgs` writes each site into `<out_dir>/<org_id>/`, summing the
  # counts; otherwise one site (`--org_id` or the default org).
  defp run_export(out_dir, base_opts, opts) do
    cond do
      opts[:all_orgs] ->
        KilnCMS.Accounts.list_org_ids()
        |> Enum.map(fn org_id ->
          StaticExport.export(Path.join(out_dir, org_id), Keyword.put(base_opts, :org_id, org_id))
        end)
        |> Enum.reduce(fn {:ok, r}, {:ok, acc} ->
          {:ok, %{acc | count: acc.count + r.count, skipped: acc.skipped + r.skipped}}
        end)
        |> then(fn {:ok, result} -> %{result | out_dir: out_dir} end)

      org_id = opts[:org_id] ->
        {:ok, result} = StaticExport.export(out_dir, Keyword.put(base_opts, :org_id, org_id))
        result

      true ->
        {:ok, result} = StaticExport.export(out_dir, base_opts)
        result
    end
  end

  defp put_surfaces(opts, nil), do: opts

  defp put_surfaces(opts, csv) do
    surfaces =
      csv
      |> String.split(",", trim: true)
      |> Enum.map(&parse_surface/1)

    Keyword.put(opts, :surfaces, surfaces)
  end

  defp parse_surface(name) do
    case StaticExport.parse_surface(name) do
      {:ok, surface} ->
        surface

      :error ->
        Mix.raise(
          "Unknown surface #{inspect(name)} " <>
            "(expected #{Enum.join(KilnCMS.Firing.Surfaces.all(), "|")})"
        )
    end
  end

  defp put_base_url(opts, nil), do: opts
  defp put_base_url(opts, url), do: Keyword.put(opts, :base_url, url)

  defp skipped_note(0), do: "."
  defp skipped_note(n), do: "; skipped #{n} not-yet-fired document(s)."
end
