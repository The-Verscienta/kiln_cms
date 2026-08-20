defmodule Mix.Tasks.Kiln.Coverage.SummaryTest do
  @moduledoc """
  The per-directory coverage rollup (#1314).

  The report is only useful if the arithmetic under it is right: a rollup that
  counted `nil` (irrelevant) lines as relevant, or a `0` (relevant, never
  ran) line as covered, would print a confident wrong number. Both are
  asserted directly, as is the depth truncation the whole table depends on.
  """
  # `Mix.shell/1` and `$GITHUB_STEP_SUMMARY` are both process-global, so the
  # `run/1` cases cannot share the VM with another test that swaps them.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kiln.Coverage.Summary

  doctest Summary, import: true

  # excoveralls' `source_files` shape: one slot per source line — nil for a
  # line the tracer considers irrelevant, else the run count.
  defp file(name, coverage), do: %{"name" => name, "coverage" => coverage}

  # A report on disk, as `mix coveralls.json` would leave one.
  defp report(dir, files) do
    path = Path.join(dir, "excoveralls.json")
    File.write!(path, Jason.encode!(%{"source_files" => files}))
    path
  end

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
    # Floored, not rounded: excoveralls floors its own total (`floor_coverage`),
    # and this table must never read a step above the number the gate saw —
    # 82.96 is 82.9 to both, never 83.0 here.
    test "floors to one decimal" do
      assert Summary.percent(2, 3) == 66.6
      assert Summary.percent(8_296, 10_000) == 82.9
      assert Summary.percent(7, 7) == 100.0
    end

    # There is no percentage of nothing, and the two plausible answers (0% and
    # 100%) are excoveralls' `treat_no_relevant_lines_as_covered` setting,
    # which this module cannot read. Refusing to return a float at all is what
    # keeps `format_pct/2` from having a number to disagree with the gate about.
    test "has no answer when nothing is relevant" do
      assert_raise FunctionClauseError, fn -> Summary.percent(0, 0) end
    end

    # Same operand ORDER as excoveralls (`covered / relevant * 100`): the other
    # order gives 29.0 here and 82.4 for 39552/48000, one step above the gate.
    test "agrees with excoveralls' own arithmetic where the two orders differ" do
      assert Summary.percent(29, 100) == 28.9
      assert Summary.percent(39_552, 48_000) == 82.3
      assert Summary.percent(39_696, 48_000) == 82.6
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

    # A directory of nothing but module attributes and `@moduledoc` has no
    # relevant lines. "0.0" there reads as "nobody tested this"; the dash says
    # what is true, and is also the one rendering that cannot contradict
    # excoveralls whatever `treat_no_relevant_lines_as_covered` is set to.
    test "print a dash, not 0.0, for a directory with no relevant lines" do
      rows = [{"lib/kiln_cms/types", 2, 0, 0}, {"TOTAL", 2, 0, 0}]

      assert Summary.format_table(rows) =~ ~r/^lib\/kiln_cms\/types\s+2\s+0\s+0\s+—$/m
      assert Summary.format_markdown(rows) =~ "| `lib/kiln_cms/types` | 2 | 0 | 0 | — |"
    end
  end

  # Every way this task can turn a CI step red lives in `run/1`, not in the
  # arithmetic above: an unreadable report, a report that is not one, a bad
  # `--depth`, and the job-summary append. A coverage task whose own failure
  # paths are unmeasured is the joke that writes itself (#1314 review).
  describe "run/1" do
    setup do
      # The task appends to this when GitHub Actions sets it — including when
      # the suite itself runs there, which would scribble on the real job
      # summary. Every case below owns the value and puts it back.
      previous = System.get_env("GITHUB_STEP_SUMMARY")
      System.delete_env("GITHUB_STEP_SUMMARY")

      on_exit(fn ->
        if previous, do: System.put_env("GITHUB_STEP_SUMMARY", previous)
        Mix.shell(Mix.Shell.IO)
      end)

      Mix.shell(Mix.Shell.Process)
      :ok
    end

    @tag :tmp_dir
    test "prints the rollup for the report it is pointed at", %{tmp_dir: dir} do
      path =
        report(dir, [
          file("lib/kiln_cms/firing/scheduler.ex", [1, 1, 0]),
          file("lib/kiln_cms_web/live/media_live.ex", [nil, 0])
        ])

      assert :ok = Summary.run(["--report", path])

      assert_received {:mix_shell, :info, [table]}
      assert table =~ ~r/^lib\/kiln_cms\/firing\s+1\s+3\s+2\s+66\.6$/m
      assert table =~ ~r/^lib\/kiln_cms_web\/live\s+1\s+1\s+0\s+0\.0$/m
      assert table =~ ~r/^TOTAL\s+2\s+4\s+2\s+50\.0$/m
    end

    @tag :tmp_dir
    test "--depth changes how far the rollup collapses", %{tmp_dir: dir} do
      path =
        report(dir, [
          file("lib/kiln_cms/firing/scheduler.ex", [1]),
          file("lib/kiln_cms/cms/page.ex", [0])
        ])

      assert :ok = Summary.run(["--report", path, "--depth", "2"])

      assert_received {:mix_shell, :info, [table]}
      assert table =~ ~r/^lib\/kiln_cms\s+2\s+2\s+1\s+50\.0$/m
      refute table =~ "lib/kiln_cms/firing"
    end

    test "refuses a depth below 1 rather than grouping everything as \"\"" do
      assert_raise Mix.Error, ~r/--depth must be a positive integer, got: 0/, fn ->
        Summary.run(["--depth", "0"])
      end
    end

    @tag :tmp_dir
    test "names the report and how to produce one when it is missing", %{tmp_dir: dir} do
      missing = Path.join(dir, "nope.json")

      assert_raise Mix.Error, ~r/Cannot read #{Regex.escape(missing)}.+coveralls/s, fn ->
        Summary.run(["--report", missing])
      end
    end

    @tag :tmp_dir
    test "says so when the file is not an excoveralls report", %{tmp_dir: dir} do
      path = Path.join(dir, "excoveralls.json")
      File.write!(path, ~s({"coverage": 83.0}))

      assert_raise Mix.Error, ~r/is not an excoveralls JSON report/, fn ->
        Summary.run(["--report", path])
      end
    end

    @tag :tmp_dir
    test "appends the table to $GITHUB_STEP_SUMMARY as Markdown", %{tmp_dir: dir} do
      path = report(dir, [file("lib/kiln_cms/cms/page.ex", [1, 0])])
      summary = Path.join(dir, "step-summary.md")
      File.write!(summary, "# Existing\n")
      System.put_env("GITHUB_STEP_SUMMARY", summary)

      assert :ok = Summary.run(["--report", path])

      written = File.read!(summary)
      # Appended, not overwritten — other steps write here too.
      assert written =~ "# Existing"
      assert written =~ "### Coverage by directory"
      assert written =~ "| `lib/kiln_cms/cms` | 1 | 2 | 1 | 50.0 |"
      assert written =~ "| **TOTAL** | 1 | 2 | 1 | 50.0 |"
    end

    @tag :tmp_dir
    test "writes no job summary when the variable is unset", %{tmp_dir: dir} do
      path = report(dir, [file("lib/kiln_cms/cms/page.ex", [1])])

      assert :ok = Summary.run(["--report", path])
      assert File.ls!(dir) == ["excoveralls.json"]
    end
  end
end
