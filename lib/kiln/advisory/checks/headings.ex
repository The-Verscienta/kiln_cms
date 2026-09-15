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
  alias KilnCMS.HeadingAnchors

  # Below this a page is short enough to read straight through, so demanding
  # section headings would be noise.
  @headings_expected_from 300

  @impl Kiln.Advisory
  def check(%Context{body: body}) do
    [headings_present(body), heading_order(body), empty_headings(body), anchors_renamed(body)]
  end

  defp headings_present(%{word_count: count}) when count < @headings_expected_from, do: :n_a
  defp headings_present(%{headings: []}), do: finding(:warning, :no_headings)
  defp headings_present(_body), do: :ok

  defp heading_order(%{headings: []}), do: :n_a

  # The finding lands on the heading that *did* the skipping (the `to` one):
  # that is the one the author edits to fix it, and `indexes` is what the
  # editor's click-to-locate reads. A heading built without an index (a test
  # fixture, or a plugin's own body) just has nowhere to jump.
  defp heading_order(%{headings: headings}) do
    case skipped_level(headings) do
      nil ->
        :ok

      {from, to} ->
        finding(:warning, :heading_levels_skipped, :body, %{
          from: from.level,
          to: to.level,
          indexes: to |> Map.get(:index) |> List.wrap()
        })
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

  # A heading's `#link` on the public page is its slug, unless something got
  # there first — an earlier heading with the same words, or an id the page
  # layout owns (`HeadingAnchors.reserved_ids/0`) — in which case it is
  # numbered. The page never carries a duplicate id; this tells the author the
  # link someone would share is `#main-1`, not the `#main` they'd guess.
  #
  # Info, not a warning: repeated sub-headings ("Example", "Example") are
  # ordinary and numbering them is correct. SEO panel only — it's about links
  # into the page, which a screen-reader outline doesn't depend on.
  defp anchors_renamed(%{headings: []}), do: :n_a

  defp anchors_renamed(%{headings: headings}) do
    renamed =
      headings
      |> Enum.zip(HeadingAnchors.ids(Enum.map(headings, & &1.text)))
      |> Enum.filter(fn {heading, id} -> id && id != HeadingAnchors.slug(heading.text) end)

    case renamed do
      [] ->
        :ok

      [{first, anchor} | _] ->
        :info
        |> finding(:heading_anchor_renamed, :body, %{
          count: length(renamed),
          example: first.text,
          anchor: anchor,
          slug: HeadingAnchors.slug(first.text),
          indexes:
            renamed
            |> Enum.flat_map(fn {h, _} -> List.wrap(Map.get(h, :index)) end)
            |> Enum.uniq()
        })
        |> lensed([:seo])
    end
  end

  defp skipped_level(headings) do
    headings
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [a, b] -> if b.level - a.level > 1, do: {a, b} end)
  end
end
