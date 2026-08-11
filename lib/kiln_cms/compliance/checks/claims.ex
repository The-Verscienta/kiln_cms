defmodule KilnCMS.Compliance.Checks.Claims do
  @moduledoc """
  Reports the claim phrases a document contains (#377).

  One finding per rule that matched, carrying the distinct phrases in `args`
  so the panel can name them — an author told "this page makes a regulatory
  claim" with no quote has to re-read the page to find it.

  ## Why this reads a fact instead of scanning

  Advisory checks re-run on **every keystroke**, and scanning a document for
  every configured phrase is exactly the work `Kiln.Advisory.Body` exists to
  keep off that path — the same lesson `Kiln.Advisory.Checks.AllCaps` records,
  where scanning inside the check put ~90ms per validate on a large document.

  Body is feature-neutral by design, though, and the claim vocabulary is
  runtime configuration belonging to one feature. So the scan goes through the
  other documented route for expensive work: the caller computes it when the
  body changes and passes it in as a `Kiln.Advisory.Context` fact.

      Analyzer.analyze(fields, body,
        facts: %{
          compliance_settings: settings,
          claim_matches: KilnCMS.Compliance.scan(text, settings.rules)
        }
      )

  A caller that did not compute it gets `:n_a`, not a pass. That distinction is
  the whole point in a compliance context: a document nobody scanned is not a
  document that is clean, and reporting it green would be the single most
  misleading thing this module could do.

  ## The settings are a fact too (#857)

  Which rules apply, and whether any of this runs, is a property of the *site*
  and lives in a database row (`KilnCMS.CMS.SiteCompliance`). A check is a pure
  function with no tenant and no database, so the caller that resolved the
  settings in order to scan with them passes them in beside the scan. The two
  facts have to come from one resolve: matches computed under one site's
  vocabulary and graded under another's would report severities for rules that
  never ran.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Settings

  @impl Kiln.Advisory
  def lenses, do: [:compliance]

  @impl Kiln.Advisory
  def check(%Context{} = context) do
    case Context.fact(context, :compliance_settings) do
      %Settings{enabled?: true} = settings ->
        # The shipped pack is English phrases. Reporting `:ok` on a French
        # document would claim a verdict nobody computed; `:n_a` says so.
        if Settings.judgeable?(settings, context),
          do: judge(Context.fact(context, :claim_matches), settings.rules),
          else: :n_a

      # Off for this site, or a caller that resolved no settings at all — which
      # is the same answer for the same reason as an absent scan.
      _otherwise ->
        :n_a
    end
  end

  # No fact: this caller did no scan. Not a pass.
  defp judge(nil, _rules), do: :n_a

  defp judge(matches, _rules) when is_map(matches) and map_size(matches) == 0, do: :ok

  defp judge(matches, rules) when is_map(matches) do
    for {code, phrases} <- Enum.sort_by(matches, &elem(&1, 0)),
        phrases != [] do
      # Document order, not sorted: `KilnCMS.Compliance.scan/2` goes to some
      # trouble to preserve it, and the panel quotes these back at the author,
      # who is about to go looking for them in that order.
      finding(Compliance.severity(code, rules), code, :body, %{
        phrases: phrases,
        count: length(phrases)
      })
    end
  end

  defp judge(_other, _rules), do: :n_a
end
