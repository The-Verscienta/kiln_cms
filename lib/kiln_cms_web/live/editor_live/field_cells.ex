defmodule KilnCMSWeb.EditorLive.FieldCells do
  @moduledoc """
  The text a content-list column shows for one custom field of one row
  (`KilnCMSWeb.EditorLive`'s field strip).

  Stored values are not all safe to print as they are: a reference field
  stores a point-in-time snapshot (id, slug, title) that can name a document
  the viewer may not read, and a `:user` field stores an id. So the labels are
  looked up afresh, once per page of rows and not once per row:

    * **references**: one `LinkEndsReadable.readable_labels/3` call over every
      target id on the page. Only the *id* is read from the stored value; an
      id the actor may not read (or that no longer exists) is "Unavailable",
      never the snapshot's own title.
    * **people** (`:user` fields): the site's roster, read once per list load
      and only when a chosen column is a `:user` field. A person shows by
      *name only* ("Unnamed user" without one, never the email), and one not on
      the roster is "Unavailable".
    * **select** shows the option's label, **media** its alt text or file name,
      **boolean** yes/no; the rest print as stored.

  `labels/5` builds the lookup, `cell/3` reads it. A caller that fetches
  another page passes the previous lookup so the roster is not read again.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Checks.LinkEndsReadable
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.ReferenceSnapshots

  @max_chars 80

  @type labels :: %{refs: %{optional(String.t()) => String.t()}, people: map() | nil}

  @doc "A lookup with nothing in it."
  @spec empty() :: labels()
  def empty, do: %{refs: %{}, people: nil}

  @doc """
  The field definitions of the content type `descriptor` (as `ContentTypes`
  lists them) on `org`, read as `actor`.
  """
  @spec definitions(map(), map() | nil, term()) :: [struct()]
  def definitions(%{source: :dynamic, definition: %{id: id}}, actor, org),
    do: CMS.field_definitions_for_definition!(id, actor: actor, tenant: Accounts.org_id(org))

  def definitions(%{type: type}, actor, org),
    do: CMS.field_definitions_for!(type, actor: actor, tenant: Accounts.org_id(org))

  @doc """
  The lookup for the `columns` (field definitions) of `items` (`{kind,
  record}` tuples), added to `prior`.

  One `readable_labels/3` call covers every reference on `items`, and the
  roster is read only if `prior` has none and a column is a `:user` field.
  """
  @spec labels(labels(), [{term(), map()}], [struct()], map() | nil, term()) :: labels()
  def labels(prior, items, columns, actor, org) do
    %{
      refs: Map.merge(prior.refs, reference_titles(items, columns, actor, org)),
      people: prior.people || people(columns, org)
    }
  end

  defp reference_titles(items, columns, actor, org) do
    names = for %{field_type: :reference, name: name} <- columns, do: name

    ids =
      for {_kind, record} <- items,
          fields = custom_fields(record),
          id <- ReferenceSnapshots.ids(Map.take(fields, names)),
          uniq: true,
          do: id

    actor
    |> LinkEndsReadable.readable_labels(Accounts.org_id(org), ids)
    |> Map.new(fn {id, label} -> {id, label["title"] || label["slug"]} end)
  end

  defp people(columns, org) do
    if Enum.any?(columns, &(&1.field_type == :user)) do
      org
      |> Scoping.users_with_tier([:admin, :editor, :viewer])
      |> Map.new(&{&1.id, person_name(&1)})
    end
  end

  # The name alone: an email address is not shown to people who were only
  # allowed to see that a field holds a person.
  defp person_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp person_name(_user), do: gettext("Unnamed user")

  @doc "The map of a record's custom fields, or `nil` when it was not loaded."
  @spec custom_fields(map()) :: map() | nil
  def custom_fields(%{custom_fields: fields}) when is_map(fields) and not is_struct(fields),
    do: fields

  def custom_fields(_record), do: nil

  @doc "The text of `definition`'s cell on a record whose custom fields are `fields`."
  @spec cell(labels(), struct(), map()) :: String.t()
  def cell(labels, definition, fields) do
    case Map.get(fields, definition.name) do
      value when value in [nil, ""] -> "—"
      value -> labels |> render(definition, value) |> truncate()
    end
  end

  defp render(labels, %{field_type: :reference}, value) do
    case value do
      %{"id" => id} when is_binary(id) -> Map.get(labels.refs, id) || unavailable()
      _other -> unavailable()
    end
  end

  defp render(labels, %{field_type: :user}, value) when is_binary(value),
    do: Map.get(labels.people || %{}, value) || unavailable()

  defp render(_labels, %{field_type: :user}, _value), do: unavailable()

  defp render(_labels, %{field_type: :select} = definition, value) when is_binary(value),
    do: FieldDefinition.option_label(definition, value)

  defp render(_labels, %{field_type: :boolean}, true), do: gettext("Yes")
  defp render(_labels, %{field_type: :boolean}, false), do: gettext("No")

  defp render(_labels, %{field_type: :media}, %{"url" => url} = media) do
    case media["alt"] do
      alt when is_binary(alt) and alt != "" -> alt
      _none -> file_name(url)
    end
  end

  defp render(_labels, %{field_type: :media}, _value), do: unavailable()

  defp render(_labels, _definition, value) when is_binary(value), do: value
  defp render(_labels, _definition, value) when is_number(value), do: to_string(value)
  defp render(_labels, _definition, true), do: gettext("Yes")
  defp render(_labels, _definition, false), do: gettext("No")
  defp render(_labels, _definition, _value), do: "—"

  defp file_name(url) when is_binary(url) do
    case url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename() do
      "" -> unavailable()
      name -> name
    end
  end

  defp file_name(_url), do: unavailable()

  defp unavailable, do: gettext("Unavailable")

  defp truncate(text) do
    if String.length(text) > @max_chars,
      do: String.slice(text, 0, @max_chars - 1) <> "…",
      else: text
  end
end
