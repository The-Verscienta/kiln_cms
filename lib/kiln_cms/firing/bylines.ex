defmodule KilnCMS.Firing.Bylines do
  @moduledoc """
  The schema.org `author` and `contributor` of a document, from its
  `:reference` custom fields (#2044).

  A content item's own `author` is the console `KilnCMS.Accounts.User` who
  created it — one person, never delivered. A public byline is instead a
  `:reference` field whose definition names a `schema_org_property`
  (`:author` or `:contributor`): every record it points at is one `Person`
  under that property, in the field's order. See `docs/author-profiles.md`.

  The values read here are the *resolved* ones (`KilnCMS.Firing.CustomFields`),
  so the same two rules hold as on the `:json` artifact: a renamed target is
  named by its current title, and a target an anonymous reader could not open
  (a draft profile) is left out rather than named.

  Used by the fired `:json_ld` surface (`KilnCMS.Firing.Engine`) and by the
  JSON-LD and byline of Kiln's own pages (`KilnCMSWeb.StructuredData`,
  `KilnCMSWeb.ContentController`), so the three cannot name different people.
  """
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.CustomFields

  @properties [:author, :contributor]

  @typedoc "One person in a byline: the target's snapshot, plus its public URL."
  @type person :: %{id: String.t(), type: String.t(), name: String.t(), url: String.t() | nil}

  @typedoc "The people per property, `:author` and `:contributor`, each in field order."
  @type t :: %{optional(:author | :contributor) => [person()]}

  @doc "The schema.org properties a `:reference` field may name."
  @spec properties() :: [atom()]
  def properties, do: @properties

  @doc """
  The byline of a document, reading its custom fields the way firing does.

  Returns `%{}` without reading any target when none of the type's fields
  names a property — the common case, which costs one definitions read.
  """
  @spec for_document(struct()) :: t()
  def for_document(document) do
    if Enum.any?(CustomFields.definitions(document), &byline_field?/1) do
      document |> CustomFields.resolve() |> people(Map.get(document, :org_id))
    else
      %{}
    end
  end

  @doc """
  The byline in already-resolved custom fields (`CustomFields.resolve/3`).

  When two fields name the same property their people are concatenated, in
  the fields' order, and a record named twice is listed once.
  """
  @spec people(CustomFields.t(), Ash.UUID.t() | nil) :: t()
  def people(%{values: values, definitions: definitions}, org_id) do
    definitions
    |> Enum.filter(&byline_field?/1)
    |> Enum.sort_by(& &1.position)
    |> Enum.reduce(%{}, fn definition, acc ->
      persons =
        values
        |> Map.get(definition.name)
        |> List.wrap()
        |> Enum.flat_map(&person(&1, org_id))

      Map.update(acc, definition.schema_org_property, persons, &(&1 ++ persons))
    end)
    |> Map.new(fn {property, persons} -> {property, Enum.uniq_by(persons, & &1.id)} end)
    |> Map.reject(fn {_property, persons} -> persons == [] end)
  end

  @doc """
  Put the byline on a schema.org node as `author` / `contributor`, a list of
  `Person` nodes each. A node with no byline is returned unchanged.
  """
  @spec put(map(), t()) :: map()
  def put(node, people) do
    Enum.reduce(@properties, node, fn property, node ->
      case Map.get(people, property) do
        nil -> node
        persons -> Map.put(node, Atom.to_string(property), Enum.map(persons, &person_node/1))
      end
    end)
  end

  @doc "A schema.org `Person` node for one person in a byline."
  @spec person_node(person()) :: map()
  def person_node(%{name: name, url: url}) do
    node = %{"@type" => "Person", "name" => name}
    if url, do: Map.put(node, "url", url), else: node
  end

  defp byline_field?(%{field_type: :reference, schema_org_property: property}),
    do: property in @properties

  defp byline_field?(_definition), do: false

  defp person(%{"id" => id, "type" => type, "title" => title} = snapshot, org_id)
       when is_binary(id) and is_binary(title) and title != "" do
    [%{id: id, type: type, name: title, url: url(type, Map.get(snapshot, "slug"), org_id)}]
  end

  defp person(_value, _org_id), do: []

  # The target's public URL in the site's default locale: a snapshot carries
  # the target's slug and type, not its locale or path alias, and a byline
  # names a person rather than a page variant.
  defp url(type, slug, org_id) when is_binary(type) and is_binary(slug) and slug != "" do
    case ContentTypes.get(type, org_id) do
      nil -> nil
      ct -> "#{KilnCMSWeb.Tenant.base_url(org_id)}#{ContentTypes.public_prefix(ct)}/#{slug}"
    end
  end

  defp url(_type, _slug, _org_id), do: nil
end
