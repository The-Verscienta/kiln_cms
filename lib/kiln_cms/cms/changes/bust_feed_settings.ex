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

  ## After the transaction, not after the action

  Ash runs `after_action` hooks **inside** the write transaction. Busting there
  looks right and is worse than not busting at all: between the delete and the
  COMMIT, an anonymous `GET /feed.xml` misses the cache, reads the *pre-save*
  row on its own snapshot, and re-caches the old policy — and a full-body feed
  document built from it — with a fresh five-minute TTL. Nothing busts again, so
  the admin is told the save succeeded while every scraper keeps receiving whole
  articles for longer than if the hook had never run.

  `after_transaction/2` fires after COMMIT, where the value it drops cannot be
  replaced by a reader that still cannot see the write. It is also the right
  place for `bust_all_feeds/1` on its own terms: that one walks the cache
  keyspace, which has no business happening while a Postgres transaction is
  open.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &bust/2)
  end

  defp bust(_changeset, {:ok, record} = result) do
    KilnCMS.Cache.bust_feed_policy(record.org_id)
    KilnCMS.Cache.bust_all_feeds(record.org_id)
    # Delivery ETag folds head generation (#1079): feed autodiscovery `<link>`s
    # are derived from this policy, not from the content row.
    KilnCMS.Cache.bump_head_generation(record.org_id)
    result
  end

  # A failed write changed nothing, so there is nothing to invalidate.
  defp bust(_changeset, other), do: other
end
