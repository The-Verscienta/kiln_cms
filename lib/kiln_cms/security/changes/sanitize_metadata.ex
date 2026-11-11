defmodule KilnCMS.Security.Changes.SanitizeMetadata do
  @moduledoc """
  Reduces an event's `metadata` to the allowlist for its `type` (#2241).

  Keys are matched as strings against the resource's `metadata_keys/1`
  (`KilnCMS.Security.Event` or `KilnCMS.Security.InstanceEvent`, #2541);
  anything else is dropped, never rejected, so an audit write cannot fail
  because a caller sent one key too many. Values are scalars only (strings,
  integers, booleans), strings trimmed and length-capped; at most
  `max_metadata_keys/0` keys survive. A secret therefore cannot ride
  along unless a type's allowlist names it, and none does.
  """
  use Ash.Resource.Change

  alias KilnCMS.Security.Event

  @impl true
  def change(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)

    Ash.Changeset.change_attribute(
      changeset,
      :metadata,
      sanitize(type, Ash.Changeset.get_attribute(changeset, :metadata), changeset.resource)
    )
  end

  @doc false
  @spec sanitize(atom() | nil, term(), module()) :: %{
          optional(String.t()) => String.t() | integer() | boolean()
        }
  def sanitize(type, metadata, resource \\ Event)

  def sanitize(type, metadata, resource) when is_map(metadata) do
    allowed = resource.metadata_keys(type)

    metadata
    |> Enum.flat_map(&allowed_pair(&1, allowed, resource.max_metadata_value()))
    |> Enum.sort()
    |> Enum.take(resource.max_metadata_keys())
    |> Map.new()
  end

  def sanitize(_type, _metadata, _resource), do: %{}

  defp allowed_pair({key, value}, allowed, max) do
    key = to_string(key)

    case clean(value, max) do
      nil -> []
      value -> if key in allowed, do: [{key, value}], else: []
    end
  end

  defp clean(value, max) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, max) do
      "" -> nil
      value -> value
    end
  end

  defp clean(value, _max) when is_integer(value) or is_boolean(value), do: value

  defp clean(value, max) when is_atom(value) and not is_nil(value),
    do: clean(Atom.to_string(value), max)

  defp clean(_value, _max), do: nil
end
