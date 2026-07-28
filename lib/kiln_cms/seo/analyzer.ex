defmodule KilnCMS.Seo.Analyzer do
  @moduledoc """
  Yoast-style SEO and readability analysis (#476) — the advisory signals the
  content editor renders as a non-blocking checklist. Nothing here ever
  prevents a save.

  This is now a thin aggregator over `Kiln.Advisory`: it builds a context,
  runs the registered checks, and turns their outcomes into the report the
  editor renders. The checks themselves live in `KilnCMS.Seo.Checks.*` and
  `Kiln.Advisory.Checks.*`, and a plugin can add more without touching this
  module.

  Two of the checks it aggregates — `Kiln.Advisory.Checks.Headings` and
  `Kiln.Advisory.Checks.ImageAlt` — deliberately sit in the neutral namespace,
  because #495's accessibility panel needs exactly those and must not
  reimplement them.

  ## Grading

  Severity, not a pass ratio: `:info` findings are nudges, so a document whose
  only findings are nudges is in good shape. `passed`/`total` carries the finer
  picture, counting only checks that were applicable — a check with nothing to
  judge is neither a pass nor a failure, which is what keeps an empty draft
  from reading as a wall of red.
  """

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Finding
  alias Kiln.Advisory.Registry

  @type grade :: :good | :ok | :poor

  @type report :: %{
          grade: grade(),
          findings: [Finding.t()],
          passed: non_neg_integer(),
          total: non_neg_integer(),
          stats: Body.t()
        }

  @doc """
  Analyze the authored fields against the body.

  `fields` is a plain map (string or atom keys) of `:title`, `:slug`,
  `:seo_title`, `:seo_description`, `:seo_keywords`, `:seo_image`,
  `:featured_image_id` and `:locale` — whatever subset is available.
  """
  @spec analyze(map(), Body.t()) :: report()
  def analyze(fields, %Body{} = body) do
    fields
    |> Context.new(body, locale: fields[:locale] || fields["locale"])
    |> Registry.run()
    |> report(body)
  end

  @doc "Analyze with body facts derived from `blocks` in one call."
  @spec analyze_blocks(map(), term()) :: report()
  def analyze_blocks(fields, blocks), do: analyze(fields, Body.compute(blocks))

  @doc "An empty report — for call sites that need the shape before any analysis."
  @spec empty() :: report()
  def empty, do: %{grade: :good, findings: [], passed: 0, total: 0, stats: %Body{}}

  defp report(outcomes, body) do
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
