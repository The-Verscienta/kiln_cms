defmodule KilnCMS.CMS.Changes.SynonymsChanged do
  @moduledoc """
  After any `SearchSynonym` write, drop the site's cached rule set
  (`KilnCMS.Search.Synonyms`) so the next search applies it, and purge the
  site's CDN key (`KilnCMS.CDN.purge_site/1`): `/api/search` is publicly
  cached per URL, and a rule changes what that URL answers without anything
  being published.

  After the transaction, not in it: a bust before COMMIT lets a concurrent
  search re-cache the pre-write rules under a fresh TTL.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      if match?({:ok, _}, result) or result == :ok do
        # A destroy may answer a bare `:ok`; the row it removed is the data.
        org_id = changeset.data.org_id || Ash.Changeset.get_attribute(changeset, :org_id)
        KilnCMS.Search.Synonyms.bust(org_id)
        KilnCMS.CDN.purge_site(org_id)
      end

      result
    end)
  end
end
