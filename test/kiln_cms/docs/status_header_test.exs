defmodule KilnCMS.Docs.StatusHeaderTest do
  @moduledoc """
  Every plan and spike under `docs/` states its status in its opening lines.

  These are the documents an evaluator reads to learn what shipped, and they
  drifted in both directions (#1313): `advanced-analytics-plan.md` said
  "design only" above a phase table of "done" rows, `content-experiments-plan.md`
  had no status at all for a feature with a UI, and the collaboration spike
  read as shipped while the flag is off in production.

  A test cannot check that a status is *true*, but it can make a missing one
  impossible — and a `Status:` line in the first lines is what a reviewer sees
  in the diff when the phase table below it changes. See CONTRIBUTING.md,
  "Documentation".
  """
  use ExUnit.Case, async: true

  @docs Path.expand("../../../docs", __DIR__)
  @head_lines 20

  test "every docs/*-plan.md and docs/*-spike.md has a Status: line near the top" do
    files = Path.wildcard(Path.join(@docs, "*-{plan,spike}.md"))

    # A broken glob would otherwise pass vacuously.
    assert length(files) >= 5

    missing =
      for file <- files,
          head = file |> File.stream!() |> Enum.take(@head_lines) |> Enum.join(),
          not String.contains?(head, "Status:") do
        Path.relative_to(file, Path.dirname(@docs))
      end

    assert missing == [],
           "these documents have no `Status:` line in their first #{@head_lines} lines: " <>
             Enum.join(missing, ", ")
  end
end
