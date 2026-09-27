defmodule KilnCMSWeb.RenderAsyncBudgetTest do
  @moduledoc """
  No test may call `render_async/1` without a timeout.

  `Phoenix.LiveViewTest.render_async/2` defaults to **100 ms**, and every async
  panel in this app — a bucket probe, an SMTP send, a pgvector query, an LLM
  stub — can outrun that on a loaded CI runner. The failure reads
  `expected async processes to finish within 100ms`: pure timing, never a wrong
  assertion, and it reproduces on `main` with nothing changed. #631 gave all 27
  call sites an explicit `2_000`; five bare ones crept back, and
  `SiteStorageLiveTest` failed CI twice in one day (#1644, #1689).

  So the rule is checked instead of remembered, by a static read of the test
  files, as `KilnCMS.Collab.PrototypeFlagIsolationTest` does for its flag.
  """
  use ExUnit.Case, async: true

  # This file quotes the bare call in its own examples.
  @self Path.relative_to_cwd(__ENV__.file)

  # `render_async(lv)` or `lv |> render_async()`: one argument or none, where a
  # budgeted call has two.
  @bare ~r/render_async\(\s*[^,()]*\s*\)/

  test "every render_async call passes a timeout" do
    offenders =
      "test/**/*.exs"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @self))
      |> Enum.flat_map(&bare_calls/1)

    assert offenders == [],
           """
           These render_async calls take the 100 ms default budget:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Pass one: `render_async(lv, 2_000)`. Never weaken the assertion
           instead; only the budget is wrong.
           """
  end

  test "the check can fail" do
    assert Regex.match?(@bare, ~s|assert render_async(lv) =~ "done"|)
    assert Regex.match?(@bare, "lv |> render_async()")
    refute Regex.match?(@bare, "render_async(lv, 2_000)")
    refute Regex.match?(@bare, "render_async(view, @timeout)")
    assert @self == "test/kiln_cms_web/render_async_budget_test.exs"
  end

  defp bare_calls(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(@bare, line) end)
    |> Enum.map(fn {_, n} -> "#{path}:#{n}" end)
  end
end
