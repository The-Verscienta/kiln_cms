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

  @surfaces KilnCMS.Firing.Surfaces.all()
  @surface_files %{web: "web.html", json: "json.json", json_ld: "json_ld.json", llm: "llm.md"}
  @surface_names KilnCMS.Firing.Surfaces.name_map()

  @doc "The exportable surfaces."
  @spec surfaces() :: [atom()]
  def surfaces, do: @surfaces

  @doc """
  Parse a surface name to its atom: `{:ok, surface}` or `:error` for an unknown
  one. The single validation point shared by the mix task and the worker (which
  receive surface names as strings). Accepts an already-valid atom too.
  """
  @spec parse_surface(String.t() | atom()) :: {:ok, atom()} | :error
  def parse_surface(name) when is_binary(name), do: Map.fetch(@surface_names, name)
  def parse_surface(name) when name in @surfaces, do: {:ok, name}
  def parse_surface(_), do: :error
  # Every path segment (type, locale, slug) is validated before it's joined into
  # the output path — an export must never escape the output directory. `locale`
  # in particular is an unconstrained content attribute, so a document with a
  # crafted locale (e.g. "../../etc") must not be able to redirect a write.
  # The pattern excludes `/` and `\`; the explicit `.`/`..` reject closes the
  # traversal segments the pattern would otherwise allow.
  @safe_segment ~r/\A[A-Za-z0-9._-]+\z/

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
    # One export = ONE site (#419): the cross-org single-tree behavior is gone
    # (two orgs sharing a slug collided). Pass `:org_id` to export another
    # site; run once per org for a full-fleet export.
    org_id = opts[:org_id] || KilnCMS.Accounts.default_org_id()

    mkdir_p!(out_dir)

    {entries, skipped} =
      (ContentTypes.all() ++ ContentTypes.dynamic_all(org_id))
      |> Enum.flat_map(&published_records(&1, org_id))
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
  defp published_records(ct, org_id) do
    # Tenant-scoped to the export's site (#419) — the read policy returns
    # published records only (same as the sitemap). `:org_id` is selected so
    # `read_surfaces/3` scopes each artifact read to its record's tenant.
    ct
    |> ContentTypes.list!(
      authorize?: true,
      tenant: org_id,
      query: [select: [:id, :slug, :locale, :updated_at, :org_id]]
    )
    |> Enum.map(&{ct, &1})
  end

  defp export_document(out_dir, ct, record, surfaces) do
    public_type = to_string(ct.type)

    with true <- safe_segment?(public_type),
         true <- safe_segment?(record.locale),
         true <- safe_segment?(record.slug),
         bodies when bodies != [] <- read_surfaces(ct, record, surfaces) do
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

  # A path segment is safe to join into the output tree only if it matches the
  # allow-list AND is not a traversal segment (`.`/`..`, which the pattern allows).
  defp safe_segment?(seg) when is_binary(seg),
    do: seg not in [".", ".."] and Regex.match?(@safe_segment, seg)

  defp safe_segment?(_), do: false

  # Read each requested surface's fired body without re-rendering. Dynamic types
  # store under the generic `:entry` tier (D17); compiled types under their atom.
  defp read_surfaces(ct, record, surfaces) do
    storage_type = ContentTypes.storage_type(ct)

    Enum.flat_map(surfaces, fn surface ->
      # `record.org_id` scopes the artifact read to the record's own tenant (#336).
      case Engine.read(record.org_id, storage_type, record.id, surface) do
        {:ok, body} -> [{surface, body}]
        :error -> []
      end
    end)
  end

  defp write_surface(path, :web, %{"html" => html}), do: write!(path, html)
  defp write_surface(path, :web, body), do: write!(path, Map.get(body, "html", ""))
  # The :llm surface is raw Markdown (#357), exported as such.
  defp write_surface(path, :llm, body), do: write!(path, Map.get(body, "markdown", ""))
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
