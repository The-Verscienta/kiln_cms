defmodule KilnCMS.CMS.PrivateFields do
  @moduledoc """
  **Private** custom fields (#2044): values for the site's editors and admins
  only.

  A `FieldDefinition` with `private: true` is filled and read in the editor
  like any other field, and its value is stored in `custom_fields` with the
  rest. What changes is who sees it. It is left out of:

    * every fired artifact (`KilnCMS.Firing.CustomFields.resolve/3`), so the
      delivery API, `/api/sync`, `?expand=`, static export, webhooks and every
      other consumer of an artifact never carry it;
    * every content read by anyone below editor — anonymous callers, viewers,
      API keys without editor rights — through JSON:API, GraphQL and MCP
      (`KilnCMS.CMS.Preparations.MaskPrivateFields`);
    * what is derived from a document for the public: computed fields, slug
      and SEO patterns (`[field:<name>]` reads as empty).

  A non-editor cannot probe a value through `custom_filter` / `custom_sort`
  either: naming a private field there is refused as an unknown field.

  Only plain, top-level types can be private (`types/0`), and a private field
  cannot be searchable, a name of the record, or delivered as plain text —
  `KilnCMS.CMS.Validations.PrivateField` says why. A `:user` field (a console
  account) is always private.
  """

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes

  @ttl :timer.minutes(5)

  # The types whose stored value stays where it is put. See
  # `Validations.PrivateField` for why the others cannot be private.
  @types [:string, :text, :integer, :float, :boolean, :date, :datetime, :url, :select, :user]

  @doc "The field types a private field may have."
  @spec types() :: [atom()]
  def types, do: @types

  @doc "The names of the private fields among `definitions`."
  @spec names([struct()]) :: [String.t()]
  def names(definitions), do: for(%{private: true, name: name} <- definitions, do: name)

  @doc """
  `values` without the private fields among `definitions`. A non-map (an
  unselected `%Ash.NotLoaded{}`, `nil`) passes through.
  """
  @spec drop(term(), [struct()]) :: term()
  def drop(values, definitions) when is_map(values) and not is_struct(values) do
    case names(definitions) do
      [] -> values
      names -> Map.drop(values, names)
    end
  end

  def drop(values, _definitions), do: values

  @doc """
  The private field names of `document`'s own type, from the site's cached
  map (`all/1`) rather than a definitions read — for the paths that run per
  record in a batch (patterns, feeds, the read mask).

  The site is the document's `org_id`, else `tenant` (a read that did not
  select `org_id`), else the default org.
  """
  @spec names_for(struct(), term()) :: [String.t()]
  def names_for(document, tenant \\ nil) do
    org_id =
      case Map.get(document, :org_id) do
        id when is_binary(id) -> id
        _ -> KilnCMS.Accounts.org_id(tenant)
      end

    Map.get(all(org_id), scope(document), [])
  end

  @doc "`values` without `document`'s private fields (`names_for/2`)."
  @spec drop_for(term(), struct(), term()) :: term()
  def drop_for(values, document, tenant \\ nil)

  # Nothing to drop, so nothing to look up: an empty map costs no read.
  def drop_for(values, _document, _tenant) when values == %{}, do: values

  def drop_for(values, document, tenant) when is_map(values) and not is_struct(values) do
    case names_for(document, tenant) do
      [] -> values
      names -> Map.drop(values, names)
    end
  end

  def drop_for(values, _document, _tenant), do: values

  @doc """
  Every private field on the site, keyed by its owner: a compiled type's atom,
  or a dynamic type's definition id.

  Cached per site like `KilnCMS.CMS.NameFields`, and busted with the type
  registry by the same hook (`KilnCMS.CMS.Changes.BustTypeRegistry`), after
  the write commits — so a read racing the write cannot re-cache "not
  private", and a field made private is private on the next read.
  """
  @spec all(Ash.UUID.t()) :: %{optional(atom() | Ash.UUID.t()) => [String.t()]}
  def all(org_id) do
    if ContentTypes.cache_registry?() do
      Cache.fetch(Cache.private_fields_key(org_id), @ttl, fn -> load(org_id) end)
    else
      load(org_id)
    end
  end

  defp load(org_id) do
    KilnCMS.CMS.list_field_definitions!(
      query: [filter: [private: true, link_of_id: [is_nil: true], group_of_id: [is_nil: true]]],
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: org_id
    )
    |> Enum.reject(&KilnCMS.CMS.FieldDefinition.orphaned?/1)
    |> Enum.group_by(&owner/1, & &1.name)
    |> Map.new(fn {owner, names} -> {owner, Enum.uniq(names)} end)
  end

  defp owner(%{type_definition_id: nil, content_type: type}), do: type
  defp owner(%{type_definition_id: id}), do: id

  # A dynamic entry's fields belong to its type definition; a compiled
  # document's to its type.
  defp scope(document) do
    case Map.get(document, :type_definition_id) do
      id when is_binary(id) -> id
      _ -> ContentTypes.type_atom(document.__struct__)
    end
  end
end
