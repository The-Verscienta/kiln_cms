defmodule KilnCMS.CMS.BlockText do
  @moduledoc """
  Extracts plain text from an embedded block tree (`blocks`).

  Walks every block's `content` (stripping HTML/markup) plus its nested
  `children`. Used by the `word_count` calculation and the denormalized
  `search_text` field.
  """

  @doc "Returns the concatenated plain text of `blocks` (space-separated)."
  @spec to_text([map()] | nil) :: String.t()
  def to_text(blocks) do
    blocks
    |> List.wrap()
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @doc "Word count across `blocks`."
  @spec word_count([map()] | nil) :: non_neg_integer()
  def word_count(blocks) do
    blocks
    |> to_text()
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp block_text(block) do
    [strip(field(block, :content)) | Enum.map(child_blocks(block), &block_text/1)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp child_blocks(block), do: block |> field(:children) |> List.wrap()

  # Top-level blocks are `Block` structs (atom keys); nested `children` come
  # back from JSONB as plain maps with string keys.
  defp field(block, key), do: Map.get(block, key) || Map.get(block, to_string(key))

  defp strip(nil), do: ""

  defp strip(text) when is_binary(text),
    do: String.replace(text, ~r/<[^>]*>/, " ") |> String.trim()

  defp strip(_), do: ""
end
