defmodule Kiln.Advisory.Report do
  @moduledoc """
  What a panel renders: the findings, how many checks passed, and a grade.

  Extracted from `KilnCMS.Seo.Analyzer` when #495's accessibility panel became
  the second consumer. The grading rule in particular is worth having in one
  place — "an `:info` is a nudge, so a page whose only findings are nudges
  still reads green" is a judgement call, and two panels quietly disagreeing
  about what green means would be worse than either answer.
  """

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Finding
  alias Kiln.Advisory.Registry

  @type grade :: :good | :ok | :poor

  @type t :: %{
          grade: grade(),
          findings: [Finding.t()],
          passed: non_neg_integer(),
          total: non_neg_integer(),
          stats: Body.t()
        }

  @doc "Build a report from already-run outcomes."
  @spec from_outcomes([Registry.outcome()], Body.t()) :: t()
  def from_outcomes(outcomes, %Body{} = body) do
    findings = Registry.findings(outcomes)
    {passed, total} = Registry.tally(outcomes)

    %{
      grade: grade(findings),
      findings: findings,
      passed: passed,
      total: total,
      stats: body
    }
  end

  @doc "An empty report — for call sites that need the shape before any analysis."
  @spec empty() :: t()
  def empty, do: %{grade: :good, findings: [], passed: 0, total: 0, stats: %Body{}}

  # Driven by severity rather than the pass ratio: an `:info` is a nudge, and a
  # page whose only findings are nudges should still read green.
  defp grade(findings) do
    errors = Enum.count(findings, &(&1.severity == :error))
    warnings = Enum.count(findings, &(&1.severity == :warning))

    cond do
      errors > 0 or warnings >= 3 -> :poor
      warnings > 0 -> :ok
      true -> :good
    end
  end
end
