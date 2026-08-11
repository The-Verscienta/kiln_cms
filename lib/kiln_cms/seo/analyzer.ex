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

  ## This is the SEO *view*, not the whole registry

  Since #495 — and a third panel since #377 — there are several views over one
  set of checks, so this filters outcomes to the `:seo` lens (see
  `c:Kiln.Advisory.lenses/0`). A caller that wants more than one view should
  run the registry once and split it —
  `KilnCMSWeb.ContentEditorLive` does — rather than call this and its
  accessibility counterpart, which would walk every shared check twice on
  every keystroke.

  ## Grading

  Severity, not a pass ratio — see `Kiln.Advisory.Report`.
  """

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Registry
  alias Kiln.Advisory.Report

  @type grade :: Report.grade()
  @type report :: Report.t()

  @doc """
  Analyze the authored fields against the body.

  `fields` is a plain map (string or atom keys) of `:title`, `:slug`,
  `:seo_title`, `:seo_description`, `:seo_keywords`, `:seo_image`,
  `:featured_image_id` and `:locale` — whatever subset is available.
  """
  @spec analyze(map(), Body.t(), keyword()) :: report()
  def analyze(fields, %Body{} = body, opts \\ []) do
    fields
    |> run(body, opts)
    |> Registry.by_lens(:seo)
    |> Report.from_outcomes(body)
  end

  @doc """
  Run every registered check and return the raw outcomes, un-lensed.

  For a caller that wants more than one panel out of one walk —
  `KilnCMSWeb.ContentEditorLive` renders both the SEO and the accessibility
  view (#495), and calling `analyze/3` plus an accessibility twin would run
  every shared check twice on every keystroke.
  """
  @spec run(map(), Body.t(), keyword()) :: [Registry.outcome()]
  def run(fields, %Body{} = body, opts \\ []) do
    fields
    |> Context.new(body,
      locale: fields[:locale] || fields["locale"],
      # Caller-computed answers to questions a pure check cannot ask — see
      # `Kiln.Advisory.Context`. Absent for a caller that did no such work, and
      # the checks that read one report `:n_a` rather than inventing a verdict.
      facts: Keyword.get(opts, :facts, %{})
    )
    |> Registry.run()
  end

  @doc "Analyze with body facts derived from `blocks` in one call."
  @spec analyze_blocks(map(), term(), keyword()) :: report()
  def analyze_blocks(fields, blocks, opts \\ []),
    do: analyze(fields, Body.compute(blocks), opts)

  @doc "An empty report — for call sites that need the shape before any analysis."
  @spec empty() :: report()
  defdelegate empty(), to: Report
end
