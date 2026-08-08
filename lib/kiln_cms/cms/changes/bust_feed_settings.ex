defmodule KilnCMS.CMS.Changes.BustFeedSettings do
  @moduledoc """
  Invalidates a site's cached syndication policy after any `FeedSettings` write
  (#719), so a settings save is visible on the next fetch instead of waiting out
  the TTL.

  Also drops the **feed documents themselves**, which `BustBranding` has no
  equivalent of and this needs: `full_content` and `excluded_types` decide what
  is *in* a cached feed body, not just how the layout renders around it. An
  admin who turns full-text syndication off and then watches `/feed.xml` keep
  handing out complete articles for five more minutes has no way to tell whether
  the switch worked — and for the setting with the disclosure consequence, that
  is the wrong thing to be unsure about.

  Every syndicated type's feed is dropped, not just one: unlike a publish, this
  write names no record and no type, so there is nothing narrower to aim at.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      KilnCMS.Cache.bust_feed_policy(record.org_id)
      KilnCMS.Cache.bust_all_feeds(record.org_id)
      {:ok, record}
    end)
  end
end
