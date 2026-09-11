defmodule KilnCMS.CMS.NameFields do
  @moduledoc """
  The custom fields that *name* a record — `names_record: true` on their
  `KilnCMS.CMS.FieldDefinition` — per content type, for one site.

  A content type's title is not always the only name its records answer
  to: an herb has a Latin binomial and a pinyin spelling, a product a trade
  name, a person a former name. Those live in `custom_fields`, which the
  keyword leg indexes as prose but which nothing treated as a *name* — so
  "astragalus membranaceus" found nothing that "Huang Qi" found, although
  both name one record. The alias leg of `KilnCMS.Search.hybrid/3` runs the
  title leg's phrase match over every field flagged here, and the per-type
  semantic routes exempt a record so named from the relevance floor, as
  they do for its title (the "Why Shen Beat Huang Qi" report's entity case,
  generalized past the title column).

  Read per search, so cached per site the way the dynamic-type registry is,
  under the same TTL and busted by the same write hook
  (`KilnCMS.CMS.Changes.BustTypeRegistry` runs on every field-definition
  write) — a flag flipped in the editor takes effect on the next search.
  """

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes

  @ttl :timer.minutes(5)

  @doc """
  The flagged field names for `resource` on the site `tenant` (an org, an id,
  or nil for the default org) — `[]` when none is flagged, which is what
  keeps the alias leg free for every type that has no aliases.

  A compiled type's fields are keyed by its type atom; the shared entry tier
  answers with every flagged field of every dynamic type on the site, since
  `Entry` rows of every type share one table and a field a row does not
  carry simply matches nothing.
  """
  @spec for_resource(module(), KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          [String.t()]
  def for_resource(resource, tenant) do
    case ContentTypes.type_atom(resource) do
      nil -> []
      type -> Map.get(all(KilnCMS.Accounts.org_id(tenant)), type, [])
    end
  end

  @doc "Every flagged field on the site, grouped by content type atom (`:entry` for dynamic types)."
  @spec all(Ash.UUID.t()) :: %{optional(atom()) => [String.t()]}
  def all(org_id) do
    if ContentTypes.cache_registry?() do
      Cache.fetch(Cache.name_fields_key(org_id), @ttl, fn -> load(org_id) end)
    else
      load(org_id)
    end
  end

  # System read: this is the schema of the site's fields, not content, and
  # the search legs that consult it run under their own read policies.
  defp load(org_id) do
    KilnCMS.CMS.list_field_definitions!(
      query: [filter: [names_record: true]],
      authorize?: false,
      tenant: org_id
    )
    |> Enum.group_by(&owner/1, & &1.name)
    |> Map.new(fn {type, names} -> {type, Enum.uniq(names)} end)
  end

  defp owner(%{type_definition_id: nil, content_type: type}), do: type
  defp owner(_dynamic), do: :entry
end
