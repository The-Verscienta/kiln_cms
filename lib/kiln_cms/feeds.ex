defmodule KilnCMS.Feeds do
  @moduledoc """
  Which content types syndicate, and how much of each entry a feed carries (#486).

  Kiln had no feed at all, which is what keeps it out of every RSS-driven
  workflow there is — the email-campaign tools people actually use (Klaviyo,
  Mailchimp) build "new post → campaign" off a feed, and so do readers and the
  IFTTT/Zapier class of automation.

  ## A type syndicates if it already has a public index

  The decision is `has_published_feed` — the per-type flag an admin already sets
  in `/editor/types` under "Has a public index of published entries", which
  **defaults to off**. A dynamic type nobody chose to publish an index for is
  not one whose records should be enumerable, in a feed or anywhere else; making
  syndication a second, config-file-only switch would have put that decision
  somewhere a tenant admin cannot reach. Compiled types (Page, Post) have public
  indexes by definition.

  On top of that, an operator can drop a type deployment-wide:

      config :kiln_cms, :feeds, exclude: ["page"]

  Names are the type names `KilnCMS.CMS.ContentTypes` uses (`"post"`,
  `"page"`, a dynamic type's own name). Excluding one drops it from the
  site-wide feed *and* removes its own feed route.

  Both are deployment-wide rather than per-org, which is the wrong grain for a
  multi-tenant install — tracked separately.

  ## Summaries by default

  An entry carries its excerpt (or SEO description) unless the type is named in
  `:full_content`:

      config :kiln_cms, :feeds, full_content: ["post"]

  Full-text syndication is a publishing decision, not a technical default: it
  hands the whole article to every scraper subscribed to the feed, and it is the
  rendered body — several kilobytes per entry — multiplied by the entry limit on
  every cache miss. Sites that want it (a newsletter built from the feed body)
  say so.

  ## Bounds

  `entry_limit` caps how many of the newest records a feed carries; the default
  is deliberately small, because a feed is a *recent-items* document and every
  reader ignores the tail anyway.
  """

  alias KilnCMS.CMS.ContentTypes

  @default_entry_limit 50
  # A feed reader that ignores `<updated>` still shouldn't be able to make a site
  # serialize its entire archive.
  @max_entry_limit 200

  @doc "The content types this org syndicates, in `ContentTypes` descriptor form."
  @spec syndicated_types(Ash.UUID.t()) :: [map()]
  def syndicated_types(org_id) do
    Enum.filter(ContentTypes.all() ++ ContentTypes.dynamic_all(org_id), &syndicated?/1)
  end

  @doc "Whether `type` syndicates — the guard behind its own feed route."
  @spec syndicated?(map()) :: boolean()
  def syndicated?(descriptor) do
    # `Map.get` rather than a field access: a descriptor built by an older
    # compiled resource (a stale beam, an external `:content_domains`) predates
    # the key, and the safe reading of "we don't know" is "don't syndicate".
    Map.get(descriptor, :published_feed?, false) and
      to_string(descriptor.type) not in config(:exclude, [])
  end

  @doc """
  Whether entries of `type` carry their rendered body rather than a summary.
  """
  @spec full_content?(map()) :: boolean()
  def full_content?(descriptor), do: to_string(descriptor.type) in config(:full_content, [])

  @doc "How many of the newest records a feed carries, clamped to a sane ceiling."
  @spec entry_limit() :: pos_integer()
  def entry_limit do
    :entry_limit
    |> config(@default_entry_limit)
    |> case do
      value when is_integer(value) and value > 0 -> min(value, @max_entry_limit)
      _other -> @default_entry_limit
    end
  end

  defp config(key, default) do
    :kiln_cms
    |> Application.get_env(:feeds, [])
    |> Keyword.get(key, default)
  end
end
