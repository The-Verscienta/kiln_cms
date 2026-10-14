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

  @typedoc """
  A panel a check's findings belong in.

  `:seo` is #476's search-and-readability panel; `:accessibility` is #495's;
  `:compliance` is #377's claim-checking panel.

  `:compliance` is deliberately **not** in the default returned by
  `c:lenses/0`. The other two overlap almost entirely — a skipped heading is
  both a search and an accessibility problem — which is why defaulting to both
  is right for them. A claim check is a different question with a different
  audience and, where the publish gate is switched on, different consequences;
  a generic plugin check landing in it by default would dilute exactly the
  panel that must not cry wolf. Compliance checks opt in explicitly.
  """
  @type lens :: :seo | :accessibility | :compliance

  @doc """
  Which panels this check's findings belong in. Defaults to **both**.

  Two features share one registry (see above), and most checks genuinely
  belong to both: a skipped heading level breaks the outline a screen-reader
  user navigates by *and* the one a search engine reads. Splitting the panels
  without splitting the checks is the whole point — an author fixing a heading
  should not have to find it twice.

  So the default is "show it in both", and a check narrows only when it has a
  reason to: `KilnCMS.Seo.Checks.Keyphrase` has nothing to say about
  accessibility, and `Kiln.Advisory.Checks.AllCaps` has nothing to say about
  search. Defaulting the other way — each check picking exactly one home —
  would mean a plugin author who never thought about the distinction silently
  gets no panel at all.
  """
  @callback lenses() :: [lens()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.Advisory

      import Kiln.Advisory, only: [finding: 2, finding: 3, finding: 4, lensed: 2]

      @impl Kiln.Advisory
      def lenses, do: [:seo, :accessibility]

      defoverridable lenses: 0
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

  @doc """
  Narrow one finding to specific panels, overriding its check's `lenses/0`.

  For a check whose findings don't all belong in the same place — see
  `Kiln.Advisory.Finding`. Reach for it only when that is genuinely true: a
  check that needs this for every finding should change its `lenses/0`
  instead.

      finding(:warning, :thin_content, :body, %{}) |> lensed([:seo])
  """
  @spec lensed(Finding.t(), [lens()]) :: Finding.t()
  def lensed(%Finding{} = finding, lenses) when is_list(lenses),
    do: %{finding | lenses: lenses}
end
