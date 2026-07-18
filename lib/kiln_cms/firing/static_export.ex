defmodule KilnCMS.Firing.StaticExport do
  @moduledoc """
  First-class static / edge export of fired artifacts (Kiln v2 — #353).

  The firing engine already produces immutable, pre-rendered per-surface
  artifacts (`:web`/`:json`/`:json_ld`) with targeted invalidation — this *is*
  static generation, better than a bolt-on SSG because re-firing is precise.
  This module is the missing *output surface*: it copies those already-fired
  artifacts to a static directory tree you can `rsync` to a CDN, bake into an
  edge cache, or ship to an air-gapped host. The live CMS stays authoritative;
  the export is a snapshot, **not** a fork.

  **No re-render.** Bodies are read through `KilnCMS.Firing.Engine.read/3` (cache
  → artifact table), exactly the delivery read path — never the live block tree.
  A published document that has never been fired is skipped and counted (run a
  publish/backfill first); nothing is compiled on the export path.

  ## Layout

      <out>/
        index.json                                     # export manifest
        content/<type>/<locale>/<slug>/
          web.html                                     # :web surface (html body)
          json.json                                    # :json surface
          json_ld.json                                 # :json_ld surface

  `<type>` is the public content type (`page`/`post`/dynamic name); `<locale>`
  is always present. `index.json` lists every exported document with its path,
  surfaces, and `fired_at`, so an edge deploy can diff/prune deterministically.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.Engine

  @surfaces [:web, :json, :json_ld]
  @surface_files %{web: "web.html", json: "json.json", json_ld: "json_ld.json"}
  # Slugs are validated on write, but guard the path we build from them anyway —
  # an export must never escape the output directory.
  @safe_slug ~r/\A[A-Za-z0-9._-]+\z/

  @type result :: %{
          out_dir: String.t(),
          count: non_neg_integer(),
          skipped: non_neg_integer(),
          surfaces: [atom()],
          entries: [map()]
        }

  @doc """
  Export every published document's fired artifacts to `out_dir`.

  Options:
    * `:surfaces` — which surfaces to write (default `#{inspect(@surfaces)}`).
    * `:base_url` — recorded in the manifest (default `:public_base_url` config).
    * `:generated_at` — manifest timestamp (default `DateTime.utc_now/0`).

  Returns `{:ok, result}` where `result` counts exported vs skipped documents.
  Existing files are overwritten; files for content deleted since a prior export
  are **not** pruned (diff `index.json` to reconcile).
  """
  @spec export(String.t(), keyword()) :: {:ok, result()}
  def export(out_dir, opts \\ []) do
    surfaces = opts[:surfaces] || @surfaces
    base_url = opts[:base_url] || Application.get_env(:kiln_cms, :public_base_url)
    generated_at = opts[:generated_at] || DateTime.utc_now()

    mkdir_p!(out_dir)

    {entries, skipped} =
      (ContentTypes.all() ++ ContentTypes.dynamic_all())
      |> Enum.flat_map(&published_records/1)
      |> Enum.reduce({[], 0}, fn {ct, record}, {acc, skipped} ->
        case export_document(out_dir, ct, record, surfaces) do
          {:ok, entry} -> {[entry | acc], skipped}
          :skip -> {acc, skipped + 1}
        end
      end)

    entries = Enum.reverse(entries)

    write_json(Path.join(out_dir, "index.json"), %{
      "generator" => "kiln-static-export",
      "version" => 1,
      "generated_at" => DateTime.to_iso8601(generated_at),
      "base_url" => base_url,
      "surfaces" => Enum.map(surfaces, &to_string/1),
      "count" => length(entries),
      "entries" => entries
    })

    {:ok,
     %{
       out_dir: out_dir,
       count: length(entries),
       skipped: skipped,
       surfaces: surfaces,
       entries: entries
     }}
  end

  # Published records for a content type, paired with their descriptor. No actor
  # + authorize?: true ⇒ the read policy returns published records only (same as
  # the sitemap). Minimal select — bodies come from the artifact store, not here.
  defp published_records(ct) do
    ct
    |> ContentTypes.list!(authorize?: true, query: [select: [:id, :slug, :locale, :updated_at]])
    |> Enum.map(&{ct, &1})
  end

  defp export_document(out_dir, ct, record, surfaces) do
    with true <- Regex.match?(@safe_slug, record.slug),
         bodies when bodies != [] <- read_surfaces(ct, record, surfaces) do
      public_type = to_string(ct.type)
      rel_dir = Path.join(["content", public_type, record.locale, record.slug])
      dir = Path.join(out_dir, rel_dir)
      mkdir_p!(dir)

      Enum.each(bodies, fn {surface, body} ->
        write_surface(Path.join(dir, @surface_files[surface]), surface, body)
      end)

      {:ok,
       %{
         "type" => public_type,
         "slug" => record.slug,
         "locale" => record.locale,
         "path" => rel_dir,
         "surfaces" => bodies |> Enum.map(&to_string(elem(&1, 0))) |> Enum.sort()
       }}
    else
      _ -> :skip
    end
  end

  # Read each requested surface's fired body without re-rendering. Dynamic types
  # store under the generic `:entry` tier (D17); compiled types under their atom.
  defp read_surfaces(ct, record, surfaces) do
    storage_type = if ct.source == :dynamic, do: :entry, else: ct.type

    Enum.flat_map(surfaces, fn surface ->
      case Engine.read(storage_type, record.id, surface) do
        {:ok, body} -> [{surface, body}]
        :error -> []
      end
    end)
  end

  defp write_surface(path, :web, %{"html" => html}), do: write!(path, html)
  defp write_surface(path, :web, body), do: write!(path, Map.get(body, "html", ""))
  defp write_surface(path, _surface, body), do: write_json(path, body)

  defp write_json(path, term), do: write!(path, Jason.encode!(term))

  # All filesystem writes funnel through these two helpers. Paths are built from
  # validated slugs/types under an operator-supplied output directory — an
  # offline CLI/admin batch operation, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir_p!(dir), do: File.mkdir_p!(dir)

  # sobelow_skip ["Traversal.FileModule"]
  defp write!(path, content), do: File.write!(path, content)
end
