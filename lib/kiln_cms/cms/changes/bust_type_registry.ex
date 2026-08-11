defmodule KilnCMS.CMS.Changes.BustTypeRegistry do
  @moduledoc """
  Invalidates the cached dynamic-type registry (and the sitemap, whose URL set
  depends on which types exist) after any `TypeDefinition` write — create,
  update (incl. restore), or archive.

  Also runs on `FieldDefinition` writes (#480). It is a field, not a type, that
  decides whether a type is event-shaped and so has an `.ics` calendar, so the
  cached answer to that question has to drop when a `datetime_range` field is
  added or removed — otherwise a new event type has no calendar until a TTL
  passes, with nothing to explain why.

  Published payloads of an archived type may linger under their own
  `{name, slug}` cache keys until their short TTL passes; `get_by_path/2`
  stops resolving the type immediately, so only already-cached responses ride
  out the window.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, record ->
      # The type registry, sitemap and llms.txt are all per-org (#336): bust the
      # writing type's own site so its editors/delivery see the change at once
      # (another org's cached registry is unaffected).
      KilnCMS.Cache.bust_type_registry(record.org_id)
      KilnCMS.Cache.bust_sitemap(record.org_id)
      KilnCMS.Cache.bust_llms(record.org_id)
      {:ok, record}
    end)
    |> Ash.Changeset.after_transaction(&bust_feeds/2)
  end

  # The feed *documents* (#719). `has_published_feed` is the other half of
  # `KilnCMS.Feeds.syndicated?/2`: turning it off stops `/recipes/feed.xml`
  # resolving at once, but the already-built site-wide feed kept listing recipe
  # entries until its TTL — and turning it on left the new type missing from
  # that feed for five minutes, with nothing on either page to explain why.
  #
  # After the transaction, not beside the busts above, for two reasons: a bust
  # that runs before COMMIT can be undone by a concurrent reader re-caching the
  # pre-write answer (see `BustFeedSettings`), and `bust_all_feeds/1` walks the
  # keyspace, which has no business happening with a Postgres transaction open.
  defp bust_feeds(_changeset, {:ok, record} = result) do
    KilnCMS.Cache.bust_all_feeds(record.org_id)
    # Delivery ETag folds head generation (#1079): `has_published_feed` and
    # event-shaped fields decide which alternate links the layout emits.
    KilnCMS.Cache.bump_head_generation(record.org_id)
    result
  end

  defp bust_feeds(_changeset, other), do: other
end
