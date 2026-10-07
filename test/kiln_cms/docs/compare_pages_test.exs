defmodule KilnCMS.Docs.ComparePagesTest do
  @moduledoc """
  The public "Kiln vs X" pages and migration guides in `docs/compare/` (#1876)
  keep the rules `docs/compare/how-kiln-compares.md` promises readers.

  Facts about other products go stale, and a page that quietly stops naming its
  sources reads exactly as confidently as one that still does. So every
  comparison page must:

    * say when its facts were checked, and name a review owner;
    * date its source list with the same day;
    * link a source in **every** row of the "At a glance" table, in the
      competitor's column — the claim and its evidence side by side.

  And every page in the directory carries a search description and is listed
  in mix.exs, which is what publishes it to kilncms.dev
  (`scripts/publish_docs.exs`).
  """
  use ExUnit.Case, async: true

  @dir "docs/compare"
  @comparisons Path.wildcard(Path.join(@dir, "kiln-vs-*.md"))
  @pages Path.wildcard(Path.join(@dir, "*.md"))

  test "the comparison pages exist" do
    assert length(@comparisons) >= 5
  end

  for path <- @pages do
    @path path

    test "#{path} has a search description and is published" do
      markdown = File.read!(@path)

      assert markdown =~ ~r/<!--\s*seo-description:\s*\S/,
             "#{@path} has no <!-- seo-description: … --> comment"

      assert File.read!("mix.exs") =~ ~s("#{@path}"),
             "#{@path} is not in mix.exs extras, so it is never published"
    end
  end

  for path <- @comparisons do
    @path path

    test "#{path} is dated, owned and sourced" do
      markdown = File.read!(@path)

      [checked] =
        Regex.run(~r/\*\*Facts checked (\d{4}-\d{2}-\d{2})\.\*\*/, markdown,
          capture: :all_but_first
        ) || flunk("#{@path} does not say when its facts were checked")

      assert {:ok, date} = Date.from_iso8601(checked)
      refute Date.after?(date, Date.utc_today()), "#{@path} is checked in the future"

      assert markdown =~ "Review owner:", "#{@path} names no review owner"

      assert markdown =~ "## Sources\n\nAll checked #{checked}.",
             "#{@path}'s source list is not dated #{checked}"

      for row <- table_rows(markdown, "## At a glance") do
        [_label, theirs | _] = row

        assert theirs =~ ~r/\]\[[\w-]+\]|\]\(https?:/,
               "#{@path}: this claim has no source link: #{theirs}"
      end
    end
  end

  # The hub's grid puts every product side by side, so every cell is a claim.
  # A dash is the one exception: "not compared here", which claims nothing.
  test "every cell of the hub's feature grid links its source" do
    markdown = File.read!(Path.join(@dir, "how-kiln-compares.md"))
    rows = table_rows(markdown, "## Feature grid")

    assert length(hd(rows)) == 7, "the grid should have a label column plus six products"

    for [label | cells] <- rows, cell <- cells, cell != "—" do
      assert cell =~ ~r/\]\[[\w-]+\]|\]\(https?:/,
             "feature grid, #{label}: this cell has no source link: #{cell}"
    end
  end

  # The body rows of the table under `heading`, as cell lists.
  defp table_rows(markdown, heading) do
    [_, section] = String.split(markdown, heading, parts: 2)
    [table | _] = String.split(section, "\n## ", parts: 2)

    rows =
      table
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "|"))
      |> Enum.drop(2)
      |> Enum.map(fn line ->
        line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
      end)

    assert rows != [], "the table under #{heading} has no rows"
    rows
  end
end
