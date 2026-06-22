defmodule KilnCMS.CMS.Calculations.WordCount do
  @moduledoc """
  Calculates the total word count across a content resource's embedded block
  tree (`blocks`). HTML/markup in block `content` is stripped before counting,
  and nested `children` blocks are included.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:blocks]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      record.blocks
      |> List.wrap()
      |> count_blocks()
    end)
  end

  defp count_blocks(blocks) do
    Enum.reduce(blocks, 0, fn block, acc ->
      acc + count_text(block_field(block, :content)) + count_blocks(child_blocks(block))
    end)
  end

  defp child_blocks(block), do: block |> block_field(:children) |> List.wrap()

  # Top-level blocks are `Block` structs (atom keys); nested `children` come
  # back from JSONB as plain maps with string keys.
  defp block_field(block, key), do: Map.get(block, key) || Map.get(block, to_string(key))

  defp count_text(nil), do: 0

  defp count_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp count_text(_), do: 0
end
