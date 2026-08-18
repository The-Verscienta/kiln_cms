defmodule Mix.Tasks.Kiln.Coverage.SummaryTest do
  @moduledoc """
  The per-directory coverage rollup (#1314).

  The report is only useful if the arithmetic under it is right: a rollup that
  counted `nil` (irrelevant) lines as relevant, or a `0` (relevant, never
  ran) line as covered, would print a confident wrong number. Both are
  asserted directly, as is the depth truncation the whole table depends on.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kiln.Coverage.Summary

  doctest Summary, import: true

  # excoveralls' `source_files` shape: one slot per source line — nil for a
  # line the tracer considers irrelevant, else the run count.
  defp file(name, coverage), do: %{"name" => name, "coverage" => coverage}

  describe "summarize/2" do
    test "counts nil as irrelevant, 0 as relevant-but-uncovered, >0 as covered" do
      rows = Summary.summarize([file("lib/kiln_cms/repo.ex", [nil, 0, 1, 5, nil, 0])], 3)

      assert rows == [
               {"lib/kiln_cms", 1, 4, 2},
               {"TOTAL", 1, 4, 2}
             ]
    end

    test "rolls files up under their directory truncated to the depth" do
      rows =
        Summary.summarize(
          [
            file("lib/kiln_cms/firing/scheduler/worker.ex", [1, 0]),
            file("lib/kiln_cms/firing/scheduler.ex", [1, 1]),
            file("lib/kiln_cms/firing.ex", [nil, 1]),
            file("lib/kiln_cms_web/live/content_editor_live.ex", [0, 0, 1]),
            file("projects/example/lib/example/catalog.ex", [1])
          ],
          3
        )

      assert rows == [
               {"lib/kiln_cms", 1, 1, 1},
               {"lib/kiln_cms/firing", 2, 4, 3},
               {"lib/kiln_cms_web/live", 1, 3, 1},
               {"projects/example/lib", 1, 1, 1},
               {"TOTAL", 5, 9, 6}
             ]
    end

    test "a shallower depth merges what a deeper one splits" do
      files = [
        file("lib/kiln_cms/firing/x.ex", [1]),
        file("lib/kiln_cms/cms/y.ex", [0])
      ]

      assert [{"lib/kiln_cms/cms", 1, 1, 0}, {"lib/kiln_cms/firing", 1, 1, 1}, _total] =
               Summary.summarize(files, 3)

      assert [{"lib/kiln_cms", 2, 2, 1}, _total] = Summary.summarize(files, 2)
    end

    test "an empty report is just the (empty) total" do
      assert Summary.summarize([], 3) == [{"TOTAL", 0, 0, 0}]
    end
  end

  describe "percent/2" do
    test "one decimal, and no division by zero on an all-irrelevant directory" do
      assert Summary.percent(2, 3) == 66.7
      assert Summary.percent(0, 0) == 0.0
      assert Summary.percent(7, 7) == 100.0
    end
  end

  describe "format_table/1 and format_markdown/1" do
    test "print every row with its percentage" do
      rows = [{"lib/kiln_cms", 1, 4, 2}, {"TOTAL", 1, 4, 2}]

      table = Summary.format_table(rows)
      assert table =~ ~r/^lib\/kiln_cms\s+1\s+4\s+2\s+50\.0$/m
      assert table =~ ~r/^TOTAL\s+1\s+4\s+2\s+50\.0$/m

      md = Summary.format_markdown(rows)
      assert md =~ "| `lib/kiln_cms` | 1 | 4 | 2 | 50.0 |"
      assert md =~ "| **TOTAL** | 1 | 4 | 2 | 50.0 |"
    end
  end
end
