defmodule KilnCMS.CMS.ReservedPathAudit do
  @moduledoc """
  Find the stored records whose public URL a router-owned path now shadows
  (#2374).

  `ContentTypes.reserved_path_segments/0` grows when the router gains a
  top-level route — `access-denied` joined it in #2143. New writes are checked
  (`Validations.SlugAvailable` for a root-served slug,
  `Validations.PathAliasValid` for an alias's first segment), but both fire
  only when the slug or alias *changes*. A record stored before the segment
  was reserved keeps it, and route order serves the router's page at its URL
  instead of the record.

  `report/0` lists every such record, in every organization and every state:

    * `:slug` — a root-served record (a page, at `/<slug>`) whose slug is a
      segment `Slugs.taken_root_segments/1` holds for its org: a router-owned
      segment or another content type's URL prefix.
    * `:path_alias` — a record whose alias starts with a router-owned segment.

  Nothing is renamed: a record's URL is the operator's to change, and a
  renamed slug needs a redirect decision. `mix kiln.reserved_paths` prints the
  report; in a release, `bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'`.
  """

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  @typedoc "One record whose URL a reserved path shadows."
  @type finding :: %{
          kind: :slug | :path_alias,
          type: String.t(),
          id: Ash.UUID.t(),
          org_id: Ash.UUID.t(),
          locale: String.t() | nil,
          state: atom() | nil,
          title: String.t() | nil,
          path: String.t()
        }

  @doc "Every stored record whose slug or alias a reserved path shadows."
  @spec report() :: [finding()]
  def report do
    # authorize?: false — operator tooling with no actor, run from a Mix task
    # or a release eval; nothing here is reachable from a web surface.
    KilnCMS.Accounts.list_organizations!(authorize?: false)
    |> Enum.flat_map(&org_findings(&1.id))
    |> Enum.sort_by(&{&1.org_id, &1.path, &1.type, &1.id})
  end

  defp org_findings(org_id) do
    slug_findings(org_id) ++ alias_findings(org_id)
  end

  defp slug_findings(org_id) do
    taken = Slugs.taken_root_segments(org_id)

    for ct <- ContentTypes.all(),
        ContentTypes.root_served?(ct.resource),
        record <- read(ct.resource, org_id, &Ash.Query.filter(&1, slug in ^taken)) do
      finding(:slug, ct.type, record, "/" <> record.slug)
    end
  end

  defp alias_findings(org_id) do
    reserved = ContentTypes.reserved_path_segments()

    for {type, resource} <- alias_resources(),
        record <- read(resource, org_id, &Ash.Query.filter(&1, not is_nil(path_alias))),
        reserved_first_segment?(record.path_alias, reserved) do
      finding(:path_alias, type, record, record.path_alias)
    end
  end

  # Every compiled content table plus the shared dynamic entry tier — the
  # tables an alias can live on (`Slugs.alias_taken?/4` reads the same set).
  defp alias_resources do
    Enum.map(ContentTypes.all(), &{to_string(&1.type), &1.resource}) ++
      [{"entry", KilnCMS.CMS.Entry}]
  end

  defp reserved_first_segment?(alias_path, reserved) do
    case String.split(alias_path, "/", trim: true) do
      [first | _rest] -> first in reserved
      [] -> false
    end
  end

  defp read(resource, org_id, filter) do
    resource
    |> Ash.Query.select([:id, :org_id, :slug, :path_alias, :locale, :title, :state])
    |> filter.()
    # authorize?: false — see `report/0`. Every row counts, drafts included:
    # publishing one later keeps its slug, and the validation never fires.
    |> Ash.read!(authorize?: false, tenant: org_id)
  end

  defp finding(kind, type, record, path) do
    %{
      kind: kind,
      type: to_string(type),
      id: record.id,
      org_id: record.org_id,
      locale: Map.get(record, :locale),
      state: Map.get(record, :state),
      title: Map.get(record, :title),
      path: path
    }
  end

  @doc """
  Print the report through `print` (one line each), and return `:ok` when it
  is empty or `{:error, message}` otherwise, so it can gate an upgrade script.
  """
  @spec run_and_report((String.t() -> any())) :: :ok | {:error, String.t()}
  def run_and_report(print) do
    case report() do
      [] ->
        print.("No stored slug or path alias is shadowed by a reserved URL.")
        :ok

      findings ->
        print.("Records whose URL a reserved path shadows (#2374):")
        Enum.each(findings, &print.(line(&1)))

        print.(
          "Give each a new slug (or path alias) in the editor; add a redirect " <>
            "from the old URL if it was ever linked."
        )

        {:error, "#{length(findings)} record(s) shadowed by a reserved URL"}
    end
  end

  defp line(f) do
    "  #{f.path}  #{f.kind} · #{f.type} #{f.id} · #{f.state || "-"} · " <>
      "locale #{f.locale || "-"} · org #{f.org_id} · #{inspect(f.title)}"
  end
end
