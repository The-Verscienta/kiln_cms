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
  """

  @doc "Whether `value` is a stored reference snapshot."
  @spec snapshot?(term()) :: boolean()
  def snapshot?(%{"id" => id, "type" => type, "slug" => _, "title" => _} = value)
      when is_binary(id) and is_binary(type),
      do: not Map.has_key?(value, "url") and match?({:ok, _}, Ecto.UUID.cast(id))

  def snapshot?(_value), do: false

  @doc "Every snapshot in `custom_fields`, single-valued and listed alike."
  @spec snapshots(term()) :: [map()]
  # Not a struct: an unselected attribute reads as `%Ash.NotLoaded{}`.
  def snapshots(custom_fields) when is_map(custom_fields) and not is_struct(custom_fields) do
    custom_fields
    |> Map.values()
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.filter(&snapshot?/1)
  end

  def snapshots(_custom_fields), do: []

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
    Map.new(custom_fields, fn {name, value} -> {name, mask_value(value, readable)} end)
  end

  def mask(custom_fields, _readable), do: custom_fields

  defp mask_value(list, readable) when is_list(list),
    do: Enum.reject(list, &hidden?(&1, readable))

  defp mask_value(value, readable), do: if(hidden?(value, readable), do: nil, else: value)

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
  its target's current label from `labels`. Unreadable snapshots, and
  anything that is not a snapshot, are returned as stored.
  """
  @spec relabel(term(), %{optional(Ash.UUID.t()) => map()}) :: term()
  def relabel(list, labels) when is_list(list), do: Enum.map(list, &relabel(&1, labels))

  def relabel(%{"id" => id} = value, labels) when is_map_key(labels, id) do
    if snapshot?(value), do: Map.merge(value, Map.fetch!(labels, id)), else: value
  end

  def relabel(value, _labels), do: value
end
