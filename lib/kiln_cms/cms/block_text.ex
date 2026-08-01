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

  @doc """
  Word count across `blocks`.

  The `u` modifier is load-bearing: without it `\\s` matches only ASCII
  whitespace, so a non-breaking space — which is what `&nbsp;` decodes to, and
  what every paste from Word or Google Docs is full of — does not split words.
  `alpha&nbsp;beta gamma&nbsp;delta` counted as **two** words, not four.

  `Kiln.Advisory.Body` has always split with `u`, so before #492 the editor's
  advisory panel and this calculation disagreed on the same content. That was
  invisible while nothing surfaced both numbers; `reading_time_minutes` surfaces
  one of them next to the other, and two counters is the problem #492 exists to
  remove rather than reproduce.
  """
  @spec word_count([term()] | nil) :: non_neg_integer()
  def word_count(blocks) do
    blocks
    |> to_text()
    |> String.split(~r/\s+/u, trim: true)
    |> length()
  end
end
