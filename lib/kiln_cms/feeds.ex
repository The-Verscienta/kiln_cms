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

  ## The policy is per-organization (#719)

  On top of that flag, a site says which of its types it drops from syndication
  and which carry their rendered body rather than a summary. Both live on the
  org's `KilnCMS.CMS.FeedSettings` row, edited at `/editor/feeds`, with the
  deployment-wide config underneath as the operator default:

      config :kiln_cms, :feeds, exclude: ["page"], full_content: ["post"]

  Two layers, most specific first — the same shape as `KilnCMS.Branding`, and
  for the same reason. A compiled type is shared by every organization on a
  deployment, so a config-only `full_content: ["post"]` handed *every* tenant's
  newest articles, in full, to any anonymous scraper the moment one tenant asked
  for a newsletter built from the feed body — and no tenant admin could opt out,
  because the switch lived in a file they cannot edit. `exclude:` inverted the
  same way: one tenant's "not this type" silenced everyone's.

  A `nil` column means "inherit the operator default"; an empty list means the
  admin said *none*. Collapsing the two would make clearing the full-content
  list fall back to a config that turns it on, which is the inversion this
  exists to remove.

  Names are the type names `KilnCMS.CMS.ContentTypes` uses (`"post"`, `"page"`,
  a dynamic type's own name). Excluding one drops it from the site-wide feed
  *and* removes its own feed route.

  ## Summaries by default

  An entry carries its excerpt (or SEO description) unless its type is listed as
  full-content. Full-text syndication is a publishing decision, not a technical
  default: it hands the whole article to every scraper subscribed to the feed,
  and it is the rendered body — several kilobytes per entry — multiplied by the
  entry limit on every cache miss. Sites that want it (a newsletter built from
  the feed body) say so.

  ## Bounds

  `entry_limit/0` caps how many of the newest records a feed carries; the
  default is deliberately small, because a feed is a *recent-items* document and
  every reader ignores the tail anyway. This one stays deployment-wide on
  purpose: it protects the server, not a tenant's publishing choice.

  ## Performance contract

  `policy/1` sits on the anonymous delivery path — every feed fetch, and every
  delivery page that advertises its feeds in `<head>`. Like `KilnCMS.Branding`
  it caches the **resolved** policy rather than the row (most sites have no row,
  and `KilnCMS.Cache.fetch/3` never caches a `nil`, so caching the lookup would
  mean a database hit on every request forever) and it **never writes**.

  Resolve it once per request and pass it down: `syndicated?/2` and
  `full_content?/2` take either an org or an already-resolved policy, so a feed
  render that touches twenty types costs one lookup rather than twenty.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.CMS.ContentTypes

  require Logger

  @typedoc "A site's resolved syndication policy — type **names**, never atoms."
  @type policy :: %{exclude: [String.t()], full_content: [String.t()]}

  @default_entry_limit 50
  # A feed reader that ignores `<updated>` still shouldn't be able to make a site
  # serialize its entire archive.
  @max_entry_limit 200

  # Matches `KilnCMS.Branding`'s. The cache is in-BEAM only (D2), so this also
  # bounds staleness on *other* nodes after a save; the writing node is busted
  # precisely by `KilnCMS.CMS.Changes.BustFeedSettings`.
  @ttl :timer.minutes(5)

  @doc """
  The resolved syndication policy for an org — an `%Organization{}`, a bare org
  id, or `nil` (the default org).

  Always returns both keys as lists of type-name strings, with the operator
  config folded in beneath the org's own row.
  """
  @spec policy(Accounts.Organization.t() | Ash.UUID.t() | nil) :: policy()
  def policy(org) do
    org_id = Accounts.org_id(org)

    # `resolve/1` returns nil only on an infrastructure failure, which the cache
    # then declines to store — so a transient error degrades to the operator
    # defaults for one request rather than for the whole TTL.
    KilnCMS.Cache.fetch(KilnCMS.Cache.feed_policy_key(org_id), @ttl, fn -> resolve(org_id) end) ||
      defaults()
  end

  @doc "The operator-level (config-only) policy, ignoring any per-site row."
  @spec defaults() :: policy()
  def defaults, do: build(nil)

  @doc "The content types this org syndicates, in `ContentTypes` descriptor form."
  @spec syndicated_types(Accounts.Organization.t() | Ash.UUID.t() | nil) :: [map()]
  def syndicated_types(org) do
    org_id = Accounts.org_id(org)
    # One policy lookup for the whole list, not one per type.
    policy = policy(org_id)

    Enum.filter(ContentTypes.all_for_org(org_id), &syndicated?(&1, policy))
  end

  @doc """
  Whether `descriptor` syndicates for a site — the guard behind its own feed
  route. Takes an org (or id, or `nil`) or an already-resolved `policy/1`.
  """
  @spec syndicated?(map(), policy() | Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          boolean()
  def syndicated?(descriptor, %{exclude: exclude}) do
    # `Map.get` rather than a field access: a descriptor built by an older
    # compiled resource (a stale beam, an external `:content_domains`) predates
    # the key, and the safe reading of "we don't know" is "don't syndicate".
    Map.get(descriptor, :published_feed?, false) and to_string(descriptor.type) not in exclude
  end

  def syndicated?(descriptor, org), do: syndicated?(descriptor, policy(org))

  @doc """
  Whether entries of `descriptor` carry their rendered body rather than a
  summary. Takes an org (or id, or `nil`) or an already-resolved `policy/1`.
  """
  @spec full_content?(map(), policy() | Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          boolean()
  def full_content?(descriptor, %{full_content: full_content}),
    do: to_string(descriptor.type) in full_content

  def full_content?(descriptor, org), do: full_content?(descriptor, policy(org))

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

  defp resolve(org_id) do
    case row(org_id) do
      :error -> nil
      row -> build(row)
    end
  end

  defp build(row) do
    %{
      exclude: layer(row && row.excluded_types, config(:exclude, [])),
      full_content: layer(row && row.full_content_types, config(:full_content, []))
    }
  end

  # `nil` at the org layer falls through to the operator default; `[]` does not
  # — see the moduledoc. Everything is normalized to a list of strings, so a
  # config written with atoms (`exclude: [:page]`) or with a bare value instead
  # of a list still compares against a descriptor's name rather than silently
  # matching nothing.
  defp layer(nil, default), do: normalize(default)
  defp layer(names, _default), do: normalize(names)

  defp normalize(names) when is_list(names) do
    for name <- names, is_binary(name) or is_atom(name), do: to_string(name)
  end

  defp normalize(_other), do: []

  # A system read: this resolves for anonymous feed fetches with no actor, and
  # the row is admin-only by policy. Tenant-scoped, so strict tenancy is
  # satisfied.
  #
  # Returns the row, `nil` when the site has none, or `:error` on an
  # infrastructure failure (which must NOT be cached).
  defp row(org_id) do
    case KilnCMS.CMS.list_feed_settings(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} -> row
      {:ok, []} -> nil
      _other -> :error
    end
  rescue
    # e.g. the table doesn't exist yet mid-rolling-deploy. Every feed fetch and
    # every delivery page's autodiscovery block comes through here, so degrade
    # to the operator defaults rather than 500ing the site.
    error ->
      Logger.warning("feed settings lookup failed, using defaults: #{Exception.message(error)}")
      :error
  end

  # The `:feeds` key is operator-written and may be anything at all — including
  # an explicit `nil`, which `Application.get_env/3`'s default does NOT cover.
  # Every read here is on the anonymous delivery path, so a malformed value
  # degrades to the built-in default rather than raising on a public route.
  defp config(key, default) do
    opts = Application.get_env(:kiln_cms, :feeds, [])

    if Keyword.keyword?(opts), do: Keyword.get(opts, key, default), else: default
  end
end
