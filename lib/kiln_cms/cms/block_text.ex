defmodule KilnCMS.CMS.BlockText do
  @moduledoc """
  Extracts plain text from a document's block tree (`blocks`).

  Works over the Kiln v2 typed representation: each block is normalized via
  `KilnCMS.CMS.TypedBlocks.to_typed/1` (handling `%Ash.Union{}`, typed structs,
  and legacy shapes) and projected with each block's `search_text/1`. Used by the
  `word_count` calculation and the denormalized `search_text` field.
  """
  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks

  @doc "Returns the concatenated plain text of `blocks` (space-separated)."
  @spec to_text([term()] | nil) :: String.t()
  def to_text(blocks) do
    blocks
    |> TypedBlocks.to_typed()
    |> Enum.map(&Blocks.search_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @doc "Word count across `blocks`."
  @spec word_count([term()] | nil) :: non_neg_integer()
  def word_count(blocks) do
    blocks
    |> to_text()
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
