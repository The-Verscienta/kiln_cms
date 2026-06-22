defmodule KilnCMS.CMS.Calculations.WordCount do
  @moduledoc """
  Calculates the total word count across a content resource's embedded block
  tree (`blocks`), via `KilnCMS.CMS.BlockText`.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.CMS.BlockText

  @impl true
  def load(_query, _opts, _context), do: [:blocks]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, &BlockText.word_count(&1.blocks))
  end
end
