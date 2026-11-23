defmodule KilnCMS.CMS.ReferenceSnapshots do
  @moduledoc """
  The `:reference` snapshots inside a `custom_fields` map, and the reader's
  view of them.

  A `:reference` field stores `%{"id", "type", "slug", "title"}` per target
  (`KilnCMS.CMS.Changes.ApplyCustomFields`), taken when the referrer was
  saved — whatever state the target was in then, a draft included. Serving
  that map verbatim tells a reader the id, slug and title of a document they
  could not read directly, which is exactly what the read API promises never
  to reveal (a draft answers 404). `mask/2` is the read-side view: every
  snapshot whose target is not in the reader's readable set is left out — a
  list loses the item, a single-valued field reads as `nil` (unset).
  `present/2` does the same and also gives every snapshot it keeps its
  target's current slug and title, since the stored ones go stale when the
  target is renamed.

  The **stored value is never rewritten**: masking happens on the way out,
  per reader, and the target reappears the moment the reader may read it.
  Callers:

    * firing (`KilnCMS.Firing.CustomFields`), as an anonymous reader, since
      every artifact consumer serves the body to anyone at the URL;
    * every content read under authorization
      (`KilnCMS.CMS.Preparations.MaskUnreadableReferences`) — JSON:API,
      GraphQL and the public site — as the actor.

  A snapshot is recognised by shape, as `KilnCMS.Firing.References` does for
  the re-fire graph: the four keys (more are allowed), a uuid `"id"`, and no
  `"url"` (a media snapshot's mark). So a value in a field deleted since, or a
  point-in-time replay, is masked too.

  ## Inside items and rows

  A `:flexible` field's items and a `:group` field's rows are maps nested in
  the field's value, and a reference sub-field of one stores the same
  snapshot (#2282). Every function here therefore walks the whole value, lists
  and maps alike, down to `max_depth/0` levels, and finds a snapshot wherever
  it sits: a hidden snapshot inside an item is left out of an item's list or
  reads `nil` where a single value stood, exactly as at the top level. The
  walk is by shape and not by definition, so it also covers a value whose
  sub-field was deleted or renamed since it was stored. An item (a map with
  `_id` or `_type`) is never itself taken for a snapshot, whatever its
  sub-fields are called; its values are walked.

  ## Limitation: shape, not definition

  The walks never consult a definition, so they also see a snapshot-shaped
  object (`id` uuid, `type`, `slug`, `title`, no `url`) inside a `:json` field,
  or under a key no definition names. Such an object is masked and counted as
  an edge like a real snapshot. That is deliberate: it fails closed, and a
  stored map cannot tell a leftover of a retype from a typed one.
  """

  alias KilnCMS.CMS.FieldDefinition

  @doc """
  How many levels of maps the walks descend: the item nesting cap
  (`FieldDefinition.max_flexible_depth/0`) with a group row between every two
  items and the snapshot itself. Deeper than any definition can store; a value
  below it (only reachable by a crafted write) is passed through as it is.
  """
  @spec max_depth() :: pos_integer()
  def max_depth, do: 2 * FieldDefinition.max_flexible_depth() + 2

  @doc "Whether `value` is a stored reference snapshot."
  @spec snapshot?(term()) :: boolean()
  def snapshot?(%{"id" => id, "type" => type, "slug" => _, "title" => _} = value)
      when is_binary(id) and is_binary(type),
      do:
        not Map.has_key?(value, "url") and not item?(value) and
          match?({:ok, _}, Ecto.UUID.cast(id))

  def snapshot?(_value), do: false

  @doc "Whether `value` is an item of a `:flexible` field (it carries `_id` or `_type`)."
  @spec item?(term()) :: boolean()
  def item?(value) when is_map(value) and not is_struct(value),
    do: Map.has_key?(value, "_id") or Map.has_key?(value, "_type")

  def item?(_value), do: false

  @doc "Every snapshot in `custom_fields`, single-valued, listed and nested alike."
  @spec snapshots(term()) :: [map()]
  # Not a struct: an unselected attribute reads as `%Ash.NotLoaded{}`.
  def snapshots(custom_fields) when is_map(custom_fields) and not is_struct(custom_fields) do
    custom_fields |> Map.values() |> Enum.flat_map(&collect(&1, 0))
  end

  def snapshots(_custom_fields), do: []

  defp collect(list, depth) when is_list(list), do: Enum.flat_map(list, &collect(&1, depth))

  defp collect(value, depth) when is_map(value) and not is_struct(value) do
    cond do
      snapshot?(value) -> [value]
      media?(value) or depth >= max_depth() -> []
      true -> value |> Map.values() |> Enum.flat_map(&collect(&1, depth + 1))
    end
  end

  defp collect(_value, _depth), do: []

  # A media snapshot is a leaf for this module: nothing in it is a reference.
  defp media?(%{"id" => id, "url" => url}) when is_binary(id) and is_binary(url), do: true
  defp media?(_value), do: false

  @doc "The distinct target ids the snapshots in `custom_fields` name."
  @spec ids(term()) :: [Ash.UUID.t()]
  def ids(custom_fields),
    do: custom_fields |> snapshots() |> Enum.map(& &1["id"]) |> Enum.uniq()

  @doc """
  `custom_fields` with every snapshot whose target is not in `readable` (a
  `MapSet` of ids) left out. Anything that is not a snapshot passes through.
  """
  @spec mask(term(), MapSet.t()) :: term()
  def mask(custom_fields, readable) when is_map(custom_fields) and not is_struct(custom_fields) do
    Map.new(custom_fields, fn {name, value} -> {name, mask_entry(value, readable, 0)} end)
  end

  def mask(custom_fields, _readable), do: custom_fields

  # A hidden snapshot is `nil` where it is the value of a key, and gone where
  # it is an element of a list.
  defp mask_entry(value, readable, depth),
    do: if(hidden?(value, readable), do: nil, else: mask_node(value, readable, depth))

  defp mask_node(list, readable, depth) when is_list(list) do
    list
    |> Enum.reject(&hidden?(&1, readable))
    |> Enum.map(&mask_node(&1, readable, depth))
  end

  defp mask_node(value, readable, depth) when is_map(value) and not is_struct(value) do
    if snapshot?(value) or media?(value) or depth >= max_depth() do
      value
    else
      Map.new(value, fn {key, child} -> {key, mask_entry(child, readable, depth + 1)} end)
    end
  end

  defp mask_node(value, _readable, _depth), do: value

  defp hidden?(value, readable),
    do: snapshot?(value) and not MapSet.member?(readable, value["id"])

  @doc """
  `custom_fields` as a reader sees it, given `labels` — the readable
  targets' current labels, `%{id => %{"slug" => _, "title" => _}}`
  (`KilnCMS.CMS.Checks.LinkEndsReadable.readable_labels/3`): every snapshot
  whose target is readable carries the target's current slug and title, and
  every other snapshot is left out as `mask/2` does.

  The stored `slug`/`title` are a copy taken when the referrer was saved, so
  a renamed target would otherwise be served under its old name until the
  referrer is saved again. Only the two label values change; the shape is
  the stored one.
  """
  @spec present(term(), %{optional(Ash.UUID.t()) => map()}) :: term()
  def present(custom_fields, labels)
      when is_map(custom_fields) and not is_struct(custom_fields) do
    custom_fields
    |> Map.new(fn {name, value} -> {name, relabel(value, labels)} end)
    |> mask(labels |> Map.keys() |> MapSet.new())
  end

  def present(custom_fields, _labels), do: custom_fields

  @doc """
  A stored value with each readable snapshot's `slug`/`title` replaced by
  its target's current label from `labels`, wherever in the value it sits.
  Unreadable snapshots, and anything that is not a snapshot, are returned as
  stored.
  """
  @spec relabel(term(), %{optional(Ash.UUID.t()) => map()}) :: term()
  def relabel(value, labels), do: relabel(value, labels, 0)

  defp relabel(list, labels, depth) when is_list(list),
    do: Enum.map(list, &relabel(&1, labels, depth))

  defp relabel(value, labels, depth) when is_map(value) and not is_struct(value) do
    cond do
      snapshot?(value) ->
        case Map.fetch(labels, value["id"]) do
          {:ok, label} -> Map.merge(value, label)
          :error -> value
        end

      media?(value) or depth >= max_depth() ->
        value

      true ->
        Map.new(value, fn {key, child} -> {key, relabel(child, labels, depth + 1)} end)
    end
  end

  defp relabel(value, _labels, _depth), do: value
end
