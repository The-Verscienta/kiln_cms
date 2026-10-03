defmodule KilnCMS.CMS.Preparations.RelatedLinksOnly do
  @moduledoc """
  Keeps `kind: :reference` edges out of a content resource's
  `related_<type>s` relationship (#1594).

  `related_*` is a many-to-many through `ContentLink` with no filter on
  `kind`, and it means "editor-curated related content" on every surface that
  exposes it (the editor's picker, JSON:API, GraphQL, the `related_links`
  calculation). Reference edges share the table since 1.1, so without this a
  page referenced from a custom field would also show up as related — and a
  save of the related picker, which replaces the set, would delete the
  reference edges it did not list.

  Applied as a preparation rather than a filter on the join relationship
  because Ash's managed *unrelate* looks the join row up by
  `(source, destination)` alone, honouring no relationship filter: with a
  curated link and a reference edge to the same page, removing the page from
  related content could delete the reference edge instead. Both the load and
  the unrelate mark the read with the join relationship's name
  (`Checks.ThroughRelatedJoin.related_join?/1`), so one preparation covers
  both.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias KilnCMS.CMS.Checks.ThroughRelatedJoin

  @impl true
  def prepare(query, _opts, _context) do
    if ThroughRelatedJoin.related_join?(query.context),
      do: Ash.Query.filter(query, kind != :reference),
      else: query
  end
end
