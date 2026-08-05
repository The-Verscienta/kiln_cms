defmodule Kiln.Advisory.Checks.Headings do
  @moduledoc """
  Heading structure: are there any, do the levels descend without gaps, and
  does each one actually say something?

  Lives in the neutral `Kiln.Advisory` namespace rather than under SEO because
  it is one of the checks #495's accessibility panel needs verbatim — a skipped
  level breaks the document outline a screen-reader user navigates by, which is
  the same defect search engines penalize. Registering it once means the two
  features cannot disagree about what a heading problem is.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  # Below this a page is short enough to read straight through, so demanding
  # section headings would be noise.
  @headings_expected_from 300

  @impl Kiln.Advisory
  def check(%Context{body: body}) do
    [headings_present(body), heading_order(body), empty_headings(body)]
  end

  defp headings_present(%{word_count: count}) when count < @headings_expected_from, do: :n_a
  defp headings_present(%{headings: []}), do: finding(:warning, :no_headings)
  defp headings_present(_body), do: :ok

  defp heading_order(%{headings: []}), do: :n_a

  defp heading_order(%{headings: headings}) do
    case headings |> Enum.map(& &1.level) |> skipped_level() do
      nil -> :ok
      {from, to} -> finding(:warning, :heading_levels_skipped, :body, %{from: from, to: to})
    end
  end

  # An empty heading renders as a gap and announces to a screen reader as an
  # unlabelled landmark — a heading that says nothing while still structuring
  # the document. `Kiln.Advisory.Body` records these separately rather than
  # putting them in `headings`, so the order check above isn't judging the
  # level of a heading with no text.
  defp empty_headings(%{empty_headings: []}), do: :ok

  defp empty_headings(%{empty_headings: indexes}) do
    # `count` is how many empty headings there are; `indexes` is where to jump,
    # de-duplicated — one rich-text block can hold several, and three jump
    # links to the same block is two too many. `Checks.LinkText` does the same.
    finding(:warning, :headings_empty, :body, %{
      count: length(indexes),
      indexes: Enum.uniq(indexes)
    })
  end

  defp skipped_level(levels) do
    levels
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [a, b] -> if b - a > 1, do: {a, b} end)
  end
end
