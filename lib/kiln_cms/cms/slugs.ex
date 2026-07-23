defmodule KilnCMS.CMS.Slugs do
  @moduledoc """
  Pathauto-style URL helpers for content records.

  `public_path/2` assembles the full public path for a record — the type's
  delivery prefix plus the slug (`/blog/guide-kiln` for a post, `/about` for a
  root-served page) — from `ContentTypes.public_prefix/1`, the same authority
  the delivery routes use.

  `ensure_unique/2` returns the first collision-free variant of a derived slug
  (`base`, then `base-2`, `base-3`, …), scoped exactly like the `unique_slug`
  identity (locale, org, and `type_definition_id` on the dynamic entry tier).
  Root-served types additionally treat router-owned first segments and every
  other content type's URL prefix as taken (`taken_root_segments/1`), so a
  derived slug can never mint an unreachable URL — a page slugged "blog"
  would be permanently shadowed by the `/blog` section by route order.
  """

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes

  @doc "Full public path for a type descriptor + slug (`/blog/guide-kiln`, `/about`)."
  @spec public_path(ContentTypes.t(), String.t() | nil) :: String.t()
  def public_path(ct, slug), do: ContentTypes.public_prefix(ct) <> "/" <> to_string(slug || "")

  @doc "The storage resource behind a registry descriptor (dynamic types → the entry tier)."
  @spec storage_resource(ContentTypes.t()) :: module()
  def storage_resource(%{source: :dynamic}), do: KilnCMS.CMS.Entry
  def storage_resource(%{resource: resource}), do: resource

  @doc """
  The registry descriptor for a **stored** content record: dynamic entries
  resolve through their `type_definition_id`, compiled records through their
  resource's type marker. `nil` when the type is no longer registered.
  """
  @spec descriptor_for_record(struct()) :: ContentTypes.t() | nil
  def descriptor_for_record(record) do
    org_id = Map.get(record, :org_id) || KilnCMS.Accounts.default_org_id()

    case record do
      %{type_definition_id: definition_id} when not is_nil(definition_id) ->
        Enum.find(
          ContentTypes.dynamic_all(org_id),
          &(&1.definition && &1.definition.id == definition_id)
        )

      %struct{} ->
        case ContentTypes.type_name(struct) do
          nil -> nil
          type -> ContentTypes.get(type, org_id)
        end
    end
  end

  @doc """
  First URL segments a **root-served** slug may not use: segments the router
  owns plus every content type's public prefix (compiled + the org's dynamic
  types) — a root `/<slug>` equal to any of these is unreachable.
  """
  @spec taken_root_segments(Ash.UUID.t()) :: [String.t()]
  def taken_root_segments(org_id) do
    compiled = Enum.map(ContentTypes.all(), & &1.path_segment)
    dynamic = Enum.map(ContentTypes.dynamic_all(org_id), & &1.path_segment)

    Enum.reject(ContentTypes.reserved_path_segments() ++ compiled ++ dynamic, &is_nil/1)
  end

  @doc """
  The first variant of `base` whose URL is free: `base`, then `base-2`,
  `base-3`, … (pathauto-style dedupe).

  Options:

    * `:resource` (required) — the storage resource to check against
    * `:locale`, `:org_id`, `:type_definition_id` — uniqueness scope; `nil`
      values are skipped (matching the `unique_slug` identity fields present
      on the resource)
    * `:exclude_id` — the record being edited, so its own saved slug doesn't
      count as a collision
    * `:tenant` — passed through to the read (strict tenancy)
    * `:root?` — also avoid `taken_root_segments/1` (root-served types)
  """
  @spec ensure_unique(String.t(), keyword()) :: String.t()
  def ensure_unique(base, opts) when is_binary(base) and base != "" do
    root =
      if Keyword.get(opts, :root?, false),
        do: taken_root_segments(opts[:org_id] || KilnCMS.Accounts.default_org_id()),
        else: []

    taken = MapSet.new(existing_variants(base, opts) ++ root)

    [base]
    |> Stream.concat(Stream.map(2..1_000, &"#{base}-#{&1}"))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
    |> Kernel.||("#{base}-#{System.unique_integer([:positive])}")
  end

  # Every existing slug that could collide with `base` or its numbered
  # variants, in one indexed read (rather than an exists?-query per candidate).
  defp existing_variants(base, opts) do
    Keyword.fetch!(opts, :resource)
    |> Ash.Query.select([:slug])
    |> Ash.Query.filter(like(slug, ^(base <> "%")))
    |> maybe_filter(:locale, opts[:locale])
    |> maybe_filter(:org_id, opts[:org_id])
    |> maybe_filter(:type_definition_id, opts[:type_definition_id])
    |> exclude_record(opts[:exclude_id])
    |> Ash.read!(authorize?: false, tenant: opts[:tenant])
    |> Enum.map(& &1.slug)
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value),
    do: Ash.Query.filter(query, ^Ash.Expr.ref(field) == ^value)

  defp exclude_record(query, nil), do: query
  defp exclude_record(query, id), do: Ash.Query.filter(query, id != ^id)
end
