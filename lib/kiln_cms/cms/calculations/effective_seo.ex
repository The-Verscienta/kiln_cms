defmodule KilnCMS.CMS.Calculations.EffectiveSeo do
  @moduledoc """
  The record's `seo_title` / `seo_description` as anything *rendering* it should
  read them: the author's own value where there is one, else the content type's
  #805 pattern expanded (#1102).

  Registered by the `Content` macro as the public `effective_seo_title` and
  `effective_seo_description` fields, the same shape
  `KilnCMS.CMS.Calculations.PublicPath` gives `path` — a per-type-configured
  derived value that resolves through the type registry and so reaches every
  read API at once, instead of each of nine surfaces re-applying
  `KilnCMS.Seo.Patterns` by hand and drifting apart.

  The stored attributes keep their meaning: `seo_description` is still exactly
  what a human typed, and still blank when nobody typed one. That distinction is
  what the editor's SEO panel, `KilnCMS.Seo.Analyzer` and the export read, so it
  could not simply be overwritten — hence a second, differently named field
  rather than a change to the first.

  ## `load/3` is the point, not an implementation detail

  A pattern's tokens resolve from the record: `[category]` needs the
  relationship, `[field:<name>]` needs `custom_fields`, `[yyyy]` needs the date
  chain. Delivery reads pin their column sets (a feed selecting `blocks` would
  drag every entry's union tree into memory), so before this those tokens
  expanded empty wherever the surface had not been told to select them.

  Declaring them here fixes that: `Ash.Query.ensure_selected/2` folds them into
  whatever `select:` the caller pinned, so a surface asks for the value and gets
  a correct one.

  That widening is also the reason **the paywall teaser and lock reads do not
  name these calculations**, and resolve through `KilnCMS.Seo.Patterns.effective/3`
  on the pinned record instead. Their select omits `custom_fields` on purpose,
  and it is not only this module that reads what lands there:
  `KilnCMSWeb.StructuredData.teaser/3` is handed the raw record and pulls a
  gated document's schedule out of `custom_fields` for the paywall page's public
  JSON-LD. Widening the select to fill in two tokens would have disclosed that
  as a side effect, so on a teaser those two tokens stay quiet — as
  `docs/seo.md` says, and as they did before #1102.

  The loads are unconditional rather than derived from the type's own pattern.
  One resource (`KilnCMS.CMS.Entry`) backs every dynamic type, so "does a
  pattern name `[category]`" has no single answer at load time — and #805
  already learned the sharper version of this: a load decided per request lands
  inside a cached payload, where it renders the shorter title until the TTL with
  nothing to explain why.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.Branding
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.Seo.Patterns

  @fields [:seo_title, :seo_description]

  @impl true
  def init(opts) do
    case Keyword.get(opts, :field) do
      field when field in @fields -> {:ok, opts}
      other -> {:error, "field must be one of #{inspect(@fields)}, got #{inspect(other)}"}
    end
  end

  @impl true
  def load(query, opts, _context) do
    resource = query.resource

    # Everything but the two below is unconditional in the `Content` macro.
    [opts[:field], :title, :custom_fields, :org_id, :published_at, :scheduled_at, :inserted_at]
    # `excerpt` is behind the macro's `excerpt?:` option, and naming an
    # attribute a resource does not have raises `NoSuchAttribute` rather than
    # resolving to nil — the branch `FeedController.select_fields/1` makes for
    # the same reason.
    |> maybe(resource, :excerpt)
    |> maybe(resource, :type_definition_id)
    |> category(resource)
  end

  @impl true
  def calculate(records, opts, _context) do
    field = opts[:field]

    # One registry lookup per distinct type and one branding read per org, not
    # one of each per record. A feed page is fifty records of one type and one
    # site name, and `descriptor_for_record/1` scans the org's dynamic type list
    # while `Branding.for_org/1` is a cache read (a query on a miss).
    {values, _seen} =
      Enum.map_reduce(records, %{}, fn record, seen ->
        {ct, seen} = memo(seen, type_key(record), fn -> Slugs.descriptor_for_record(record) end)
        org_id = Map.get(record, :org_id)
        {branding, seen} = memo(seen, {:branding, org_id}, fn -> Branding.for_org(org_id) end)

        {Patterns.resolve(record, ct, field, branding), seen}
      end)

    values
  end

  defp type_key(record) do
    {record.__struct__, Map.get(record, :org_id), Map.get(record, :type_definition_id)}
  end

  defp memo(seen, key, build) do
    case seen do
      %{^key => value} ->
        {value, seen}

      _miss ->
        value = build.()
        {value, Map.put(seen, key, value)}
    end
  end

  defp maybe(loads, resource, name) do
    if Ash.Resource.Info.attribute(resource, name), do: [name | loads], else: loads
  end

  # `[:name]` rather than the bare relationship: the name is the only thing
  # `[category]` expands to, and a delivery read has no business pulling a
  # category's description and block tree along with it.
  defp category(loads, resource) do
    if Ash.Resource.Info.relationship(resource, :category),
      do: [{:category, [:name]} | loads],
      else: loads
  end
end
