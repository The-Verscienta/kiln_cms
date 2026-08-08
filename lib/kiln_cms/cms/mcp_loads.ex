defmodule KilnCMS.CMS.McpLoads do
  @moduledoc """
  What the MCP write tools load into their result — resolved per call (#996).

  `AshAi.Tool`'s `load` accepts a function of the raw client input, which is
  what lets this be conditional. That matters because the two link collections
  have opposite economics:

    * **tags and category** are small, always relevant to a content write, and
      cheap — loaded unconditionally (#640);
    * **related links** are neither. A page may carry many, and most writes do
      not touch them, so echoing them on every write would charge every model's
      context for something it did not ask about.

  So `related_links` is loaded only when the call actually named a related
  argument. A `remove_related_post_ids` that matched nothing then comes back
  with the surviving links to compare against, and a write that never mentioned
  them pays nothing.
  """

  # The merge machinery mints `related_<type>_ids` plus `add_`/`remove_`
  # prefixes (`KilnCMS.CMS.Content`), so every argument that can change a
  # related link contains this. Matched by substring rather than by an
  # enumerated list of nine strings: the list would be a second spelling of the
  # macro's naming rule, and would silently stop matching if a type were added.
  @related_marker "related_"

  @doc """
  Load list for an MCP content update.

  `input` is the raw client argument map — string keys, as it arrives over the
  wire, before Ash casts anything.
  """
  @spec update(map()) :: [atom()]
  def update(input) when is_map(input) do
    if touches_related?(input), do: [:tags, :category, :related_links], else: [:tags, :category]
  end

  def update(_other), do: [:tags, :category]

  defp touches_related?(input) do
    input
    |> Map.keys()
    |> Enum.any?(fn
      key when is_binary(key) -> String.contains?(key, @related_marker)
      key when is_atom(key) -> key |> Atom.to_string() |> String.contains?(@related_marker)
      _other -> false
    end)
  end
end
