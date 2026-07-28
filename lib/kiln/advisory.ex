defmodule Kiln.Advisory do
  @moduledoc """
  The contract for an **editorial advisory check** — the shared analysis
  framework behind the content editor's advice panels (#476, #495).

  An advisory is a non-blocking observation about a piece of content: the SEO
  description is too short, a heading level was skipped, an image has no alt
  text. Advisories never prevent a save. They are advice, and the author
  decides.

  ## Why a registry rather than a hardcoded list

  Two features want the same surface. #476 (SEO & readability) and #495
  (accessibility) both need "walk the content, produce fixable findings, render
  them in a severity-tiered panel", and #495 states the constraint outright:
  *"Coordinate with #476 so neither builds a private panel: the advisory
  framework is the shared deliverable."* Building each as its own panel would
  duplicate the body walk, the severity vocabulary, the jump-to-block links —
  and, concretely, the heading-order and missing-alt checks, which SEO already
  implements and accessibility needs.

  So checks are modules, discovered at runtime. A plugin adds its own the same
  way it adds a block or a field type:

      defmodule Ratings.Advisories.MissingSummary do
        use Kiln.Advisory

        @impl Kiln.Advisory
        def check(%{fields: %{summary: ""}}), do: finding(:warning, :missing_summary)
        def check(_context), do: :ok
      end

  and lists it from its plugin entry module:

      @impl Kiln.Plugin
      def advisories, do: [Ratings.Advisories.MissingSummary]

  ## Three outcomes, not just findings

  `check/1` returns `:ok` (passed), `:n_a` (nothing to judge), or a
  `Kiln.Advisory.Finding` — or a list of those, for a check that reports on
  several things at once.

  `:n_a` is what makes an empty draft readable: a brand-new page has no body,
  so the body checks have nothing to say, and reporting them as failures would
  greet the author with a wall of red. It also lets the panel show an honest
  "9 of 12 checks passing" without inventing a score.

  ## Findings carry codes, not prose

  A finding is `%{code:, severity:, field:, args:}`. `args` holds the numbers a
  message wants to interpolate; the sentence itself lives in the web layer as
  `gettext` clauses. That keeps checks free of any web or Gettext dependency —
  they are pure functions over a `Kiln.Advisory.Context` — and it is what lets
  the same finding render translated in three locales.
  """

  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Finding

  @type outcome :: :ok | :n_a | Finding.t()

  @doc """
  Judge `context`. Pure — no IO, no database, no network: this runs on every
  keystroke in the content editor.

  The check module itself is its identifier, so there is no `id/0` to
  implement and nothing to keep in sync.
  """
  @callback check(Context.t()) :: outcome() | [outcome()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.Advisory

      import Kiln.Advisory, only: [finding: 2, finding: 3, finding: 4]
    end
  end

  @doc """
  Build a finding.

  `field` names the input it is about, which is what lets the editor render a
  slug advisory next to the slug input rather than only in the panel.
  """
  @spec finding(Finding.severity(), atom(), atom(), map()) :: Finding.t()
  def finding(severity, code, field \\ :body, args \\ %{}) do
    %Finding{severity: severity, code: code, field: field, args: args}
  end
end
