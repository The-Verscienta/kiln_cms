defmodule KilnCMS.Compliance.Checks.Disclaimer do
  @moduledoc """
  Reports a body that is missing the required disclaimer (#377).

  Which text that is, and whether any of this runs, is the site's own answer
  (`/editor/compliance`, #857) over the deployment default:

      config :kiln_cms, KilnCMS.Compliance,
        disclaimer: "This information is not medical advice."

  Both arrive already resolved, as the `:compliance_settings` fact that
  `KilnCMS.Compliance.Checks.Claims` documents. A caller that resolved none
  gets `:n_a` — this check is a *requirement*, and reporting a document green
  against a requirement nobody looked up is the failure mode compliance
  checking exists to avoid.

  The comparison itself is cheap enough to run in the check — one
  `String.contains?/2` against the already-folded body text, no scan and no
  walk, so unlike `KilnCMS.Compliance.Checks.Claims` it needs no *scan* fact.

  ## Substring, not equality, and folded on both sides

  The disclaimer is usually authored inside a rich-text block, wrapped in
  markup and sitting next to other prose, so what the body walk yields is the
  sentence embedded in a longer string. Comparing for equality would fail on
  every real document.

  Both sides are compared on `Kiln.Advisory.Body`'s folded text — lowercased
  with whitespace collapsed — so a disclaimer that was line-wrapped by the
  editor, or title-cased by an author, still counts. What it will *not*
  survive is rewording, which is correct: a disclaimer whose text an operator
  pinned in config is one they want verbatim.

  An empty body is `:n_a` rather than a failure, so a brand-new draft doesn't
  open with a compliance error before anything has been written.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias KilnCMS.Compliance.Settings

  @impl Kiln.Advisory
  def lenses, do: [:compliance]

  @impl Kiln.Advisory
  def check(%Context{body: %Body{} = body} = context) do
    with %Settings{enabled?: true, disclaimer: text} when is_binary(text) <-
           Context.fact(context, :compliance_settings),
         false <- blank?(body.folded_text) do
      if String.contains?(body.folded_text, fold(text)) do
        :ok
      else
        finding(:warning, :disclaimer_missing, :body, %{disclaimer: text})
      end
    else
      _otherwise -> :n_a
    end
  end

  # `Body.fold/1` itself, not a copy of it: the two sides of this comparison
  # have to normalize identically, and a second implementation is one that
  # drifts the next time folding changes.
  defp fold(text), do: text |> Body.fold() |> String.trim()

  defp blank?(text), do: String.trim(text) == ""
end
