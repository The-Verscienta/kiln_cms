defmodule KilnCMS.Docs.SurfaceLabelsTest do
  @moduledoc """
  The README's stability table and the overlay contract say the same thing,
  and every surface either of them names carries exactly one label (#1542).

  The table exists twice — in `README.md`, which is where a team deciding
  whether to adopt Kiln reads it, and in `docs/overlay-contract.md`, which is
  the document that argues each promise. Before this test the README's copy
  was a hand-written summary, and it drifted: its "moves without notice" row
  was missing five of the contract's "Not covered" entries, and nothing
  noticed.

  So the table is now one block, fenced by `<!-- surface-labels:start -->` and
  `<!-- surface-labels:end -->`, and it must be identical in both files (link
  targets are compared as the file they resolve to, since `docs/api.md` from
  the README is `api.md` from the contract). Beyond that, the block has to
  account for the rest of the contract:

    * every row of the contract's **Covered surfaces** table is named in the
      table's *Covered* row;
    * every entry of its **Not covered** list is named in the *Internal* row;
    * every endpoint in the API guide's *Headless surfaces at a glance* table
      has a label;
    * no code span sits in two rows — one surface, one label.

  "Named" means: the entry's code spans, when it has any, appear as code spans
  in the row; an entry with none must appear in the row as text. When this
  fails, the fix is to label the surface in both copies of the table — not to
  loosen the match.
  """
  use ExUnit.Case, async: true

  @readme "README.md"
  @contract "docs/overlay-contract.md"
  @api_guide "docs/api.md"

  @start "<!-- surface-labels:start -->"
  @stop "<!-- surface-labels:end -->"

  test "the README and the overlay contract carry the same table" do
    readme = block!(@readme)
    contract = block!(@contract)

    assert readme == contract, """
    The surface-labels table in #{@readme} differs from the one in #{@contract}.
    Edit both copies so they match; see #{Path.relative_to_cwd(__ENV__.file)}.

    #{first_difference(readme, contract)}
    """
  end

  test "every covered surface is in the Covered row" do
    rows = rows!(@contract)

    missing =
      @contract
      |> section!("Covered surfaces")
      |> covered_table_entries()
      |> Enum.reject(&named?(&1, Map.fetch!(rows, "Covered")))

    assert missing == [], """
    These rows of #{@contract}'s "Covered surfaces" table are not named in the
    surface-labels table's Covered row:

    #{bullets(missing)}
    """
  end

  test "every not-covered entry is in the Internal row" do
    rows = rows!(@contract)

    missing =
      @contract
      |> section!("Not covered")
      |> not_covered_entries()
      |> Enum.reject(&named?(&1, Map.fetch!(rows, "Internal")))

    assert missing == [], """
    These entries of #{@contract}'s "Not covered" list are not named in the
    surface-labels table's Internal row:

    #{bullets(missing)}
    """
  end

  test "every HTTP surface in the API guide has a label" do
    labelled = @contract |> rows!() |> Map.values() |> Enum.flat_map(&endpoints/1) |> MapSet.new()

    missing =
      @api_guide
      |> section!("Headless surfaces at a glance")
      |> api_guide_endpoints()
      |> Enum.reject(&MapSet.member?(labelled, &1))

    assert missing == [], """
    These endpoints from #{@api_guide}'s "Headless surfaces at a glance" table
    have no label in the surface-labels table:

    #{bullets(missing)}
    """
  end

  test "no surface carries two labels" do
    duplicated = @contract |> rows!() |> duplicated_spans()

    assert duplicated == [], """
    These code spans appear in more than one row of the surface-labels table:

    #{bullets(duplicated)}
    """
  end

  test "the checks can fail" do
    # Every check above passes vacuously if its parser stops matching, which is
    # how the README's copy drifted unnoticed in the first place.
    rows = rows!(@contract)

    assert rows |> Map.keys() |> Enum.sort() ==
             ["Covered", "Covered, off by default", "Experimental", "Internal"]

    covered = @contract |> section!("Covered surfaces") |> covered_table_entries()
    not_covered = @contract |> section!("Not covered") |> not_covered_entries()
    endpoints = @api_guide |> section!("Headless surfaces at a glance") |> api_guide_endpoints()

    assert length(covered) > 20
    assert length(not_covered) > 8
    assert length(endpoints) > 20

    row = "| **Internal** | x | `Kiln.A` and `mix kiln.*`; **Core** Oban queue names |"
    assert named?({:spans, ["Kiln.A"]}, row)
    refute named?({:spans, ["Kiln.A", "Kiln.B"]}, row)
    assert named?({:text, "core oban queue names"}, row)
    refute named?({:text, "a surface nobody labelled"}, row)

    # A span is matched whole, so `mix kiln.*` does not stand in for
    # `mix kiln.update`.
    refute named?({:spans, ["mix kiln.update"]}, row)

    assert duplicated_spans(%{"A" => "`X` and `Y`", "B" => "`Y`"}) == ["`Y`"]

    assert normalize_links("[a](docs/api.md) [b](#x) [c](https://e.x/y.md)", @readme) ==
             normalize_links("[a](api.md) [b](#x) [c](https://e.x/y.md)", @contract)

    refute normalize_links("[a](docs/api.md)", @readme) ==
             normalize_links("[a](docs/api.md)", @contract)
  end

  ## The block

  defp block!(path) do
    text = File.read!(path)

    case String.split(text, [@start, @stop]) do
      [_before, block, _after] ->
        normalize_links(block, path)

      parts ->
        flunk(
          "#{path} must hold exactly one #{@start} … #{@stop} block, found #{length(parts) - 1} markers"
        )
    end
  end

  # Relative link targets become repo-root paths, so the same file linked from
  # two directories compares equal. Absolute URLs and bare fragments stay.
  defp normalize_links(text, from) do
    dir = Path.dirname(from)

    Regex.replace(~r/\]\(([^)\s#]+)(#[^)\s]*)?\)/, text, fn full, target, fragment ->
      if String.contains?(target, "://") do
        full
      else
        "](" <> Path.relative_to(Path.expand(target, dir), File.cwd!()) <> fragment <> ")"
      end
    end)
  end

  # %{"Covered" => row_text, ...}, keyed by the bold label in the first cell.
  defp rows!(path) do
    rows =
      path
      |> block!()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\|\s*\*\*([^*]+)\*\*\s*\|/, line) do
          [_, label] -> [{label, line}]
          nil -> []
        end
      end)

    assert rows != [], "no label rows found in #{path}'s surface-labels table"
    Map.new(rows)
  end

  ## The contract's own lists

  defp section!(path, heading) do
    text = File.read!(path)

    case String.split(text, "\n## #{heading}\n", parts: 2) do
      [_, rest] -> rest |> String.split("\n## ", parts: 2) |> hd()
      _ -> flunk("#{path} has no `## #{heading}` section")
    end
  end

  # First cell of each body row of the section's table.
  defp covered_table_entries(section) do
    section
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| "))
    |> Enum.drop(1)
    |> Enum.map(fn line -> line |> String.split("|") |> Enum.at(1) |> String.trim() end)
    |> Enum.map(&entry/1)
  end

  # The bold lead of each top-level bullet.
  defp not_covered_entries(section) do
    ~r/^- \*\*(.+?)\*\*/m
    |> Regex.scan(section)
    |> Enum.map(fn [_, lead] -> entry(lead) end)
  end

  defp api_guide_endpoints(section) do
    section
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| **"))
    |> Enum.flat_map(fn line -> line |> String.split("|") |> Enum.at(2) |> endpoints() end)
    |> Enum.uniq()
  end

  ## Matching

  defp entry(text) do
    case spans(text) do
      [] -> {:text, plain(text)}
      spans -> {:spans, spans}
    end
  end

  defp named?({:spans, wanted}, row), do: Enum.all?(wanted, &(&1 in spans(row)))
  defp named?({:text, wanted}, row), do: String.contains?(plain(row), wanted)

  defp spans(text), do: ~r/`([^`]+)`/ |> Regex.scan(text) |> Enum.map(&List.last/1)

  defp plain(text) do
    text
    |> String.replace(["**", "`"], "")
    |> String.downcase()
    |> String.trim()
    |> String.trim_trailing(".")
  end

  # `GET /api/search?q=` -> "/api/search". Spans that are not a path (a script
  # tag, `…/verify`) are left to the prose around them.
  defp endpoints(text) do
    text
    |> spans()
    |> Enum.map(&String.replace(&1, ~r/^(GET|POST|PUT|PATCH|DELETE)\s+/, ""))
    |> Enum.map(&String.replace(&1, ~r/\?.*$/, ""))
    |> Enum.filter(&String.starts_with?(&1, "/"))
  end

  defp duplicated_spans(rows) do
    rows
    |> Enum.flat_map(fn {_label, row} -> row |> spans() |> Enum.uniq() end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_span, n} -> n > 1 end)
    |> Enum.map(fn {span, _} -> "`#{span}`" end)
    |> Enum.sort()
  end

  ## Messages

  defp bullets(items), do: Enum.map_join(items, "\n", &"  - #{inspect(&1)}")

  defp first_difference(a, b) do
    a
    |> String.split("\n")
    |> Enum.zip(String.split(b, "\n"))
    |> Enum.find(fn {x, y} -> x != y end)
    |> case do
      {x, y} -> "First differing line:\n  #{@readme}: #{x}\n  #{@contract}: #{y}"
      nil -> "One copy has extra lines at the end."
    end
  end
end
