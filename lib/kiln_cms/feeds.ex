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

  defmodule Policy do
    @moduledoc """
    One site's resolved syndication policy — the `FeedSettings` row and the
    operator config already folded into two lists of content-type **names**
    (never atoms; a dynamic type has no atom).

    A struct rather than a bare map so `KilnCMS.Feeds.syndicated?/2` and
    `full_content?/2` can demand a resolved policy and nothing else. With a map
    they matched on one key each, so a half-shaped map — or a `conn`, a socket,
    a `nil` — fell through to a second clause that resolved it as an *org*, and
    `KilnCMS.Accounts.org_id(nil)` answers with the **default** organization.
    Reading one tenant's syndication policy for another is the failure this
    whole module exists to remove; the struct makes it a compile-visible
    mismatch instead.
    """
    defstruct exclude: [], full_content: []

    @type t :: %__MODULE__{exclude: [String.t()], full_content: [String.t()]}
  end

  alias KilnCMS.Accounts
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Feeds.Policy

  require Logger

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
  @spec policy(Accounts.Organization.t() | Ash.UUID.t() | nil) :: Policy.t()
  def policy(%Accounts.Organization{id: id}) when is_binary(id), do: for_org_id(id)
  def policy(nil), do: for_org_id(Accounts.default_org_id())
  def policy(org_id) when is_binary(org_id), do: for_org_id(org_id)

  # Anything that is not an org degrades rather than raising, exactly as
  # `KilnCMS.Branding.for_org/1` does: every caller is on an anonymous delivery
  # route, and `unavailable/0` is safe by construction. Spelling the accepted
  # shapes out rather than deferring to `Accounts.org_id/1` also keeps a stray
  # `conn`/socket from being read as an org id.
  def policy(_other), do: unavailable()

  defp for_org_id(org_id) do
    # `resolve/1` returns nil only on an infrastructure failure, which the cache
    # then declines to store — so a transient error degrades for one request
    # rather than for the whole TTL. It degrades to `unavailable/0`, NOT to the
    # operator config: see that function.
    KilnCMS.Cache.fetch(KilnCMS.Cache.feed_policy_key(org_id), @ttl, fn -> resolve(org_id) end) ||
      unavailable()
  end

  @doc "The operator-level (config-only) policy, ignoring any per-site row."
  @spec defaults() :: Policy.t()
  def defaults, do: build(nil)

  @doc """
  The policy to use when a site's row **cannot be read** — a rolling deploy
  before the table exists, a pool timeout under load.

  Not `defaults/0`, and that is the whole point. Falling back to the operator
  config would discard exactly the opt-out this feature exists for: a tenant
  that saved `full_content_types: []` against a deployment configured
  `full_content: ["post"]` would start handing its complete articles to every
  anonymous scraper for the duration of the fault, silently. So the axis with a
  disclosure consequence fails **closed** — summaries only, whatever anyone
  configured.

  `exclude` keeps the operator default instead, because failing closed there
  means "no feeds at all", and taking every tenant's syndication down over a
  transient read error is the larger failure. Nothing in a feed is private —
  the records are published and `:public` — so the two axes get the answer that
  is safe for each.
  """
  @spec unavailable() :: Policy.t()
  def unavailable, do: %Policy{defaults() | full_content: []}

  @doc """
  The content types this org syndicates, in `ContentTypes` descriptor form.

  Cached per org, like `KilnCMS.Events.calendar_types/1` and for the same
  reason: this runs on the public feed routes *before* the response cache is
  consulted (`KilnCMSWeb.FeedController.find_type/2`) and in the `<head>` of
  every delivery page, and it costs a policy resolve plus a full content-type
  registry walk. Busted by `Changes.BustFeedSettings` and `Changes.BustTypeRegistry`
  — the two writes that can change the answer.
  """
  @spec syndicated_types(Accounts.Organization.t() | Ash.UUID.t() | nil) :: [map()]
  def syndicated_types(org) do
    org_id = Accounts.org_id(org)
    build = fn -> syndicated_types(org_id, policy(org_id)) end

    # Honours `ContentTypes.cache_registry?/0`, which is off in tests: these
    # descriptors carry `%TypeDefinition{}` structs, so caching them past a
    # sandbox rollback hands a later test a type whose row no longer exists.
    if ContentTypes.cache_registry?() do
      KilnCMS.Cache.fetch(KilnCMS.Cache.syndicated_types_key(org_id), @ttl, build)
    else
      build.()
    end
  end

  @doc """
  Like `syndicated_types/1`, but against an already-resolved policy — for a
  caller that needs both and must not resolve twice (they could then disagree
  across a concurrent save, producing a document mixing two policies).

  Uncached: the caller holding a policy is the one rebuilding a feed, and a
  policy passed in may not be this org's cached one.
  """
  @spec syndicated_types(Accounts.Organization.t() | Ash.UUID.t() | nil, Policy.t()) :: [map()]
  def syndicated_types(org, %Policy{} = policy) do
    org
    |> Accounts.org_id()
    |> ContentTypes.all_for_org()
    |> Enum.filter(&syndicated?(&1, policy))
  end

  @doc """
  Whether `descriptor` syndicates for a site — the guard behind its own feed
  route, and behind ActivityPub delivery for the type (`KilnCMS.Federation`).

  Takes a **resolved** `policy/1` and nothing else, deliberately: an org-shaped
  second argument would make the cheap call optional, and `Accounts.org_id/1`
  resolves a `nil` to the *default* org — reading one tenant's policy for
  another is the failure this whole module exists to remove.
  """
  @spec syndicated?(map(), Policy.t()) :: boolean()
  def syndicated?(descriptor, %Policy{exclude: exclude}) do
    # `Map.get` rather than a field access: a descriptor built by an older
    # compiled resource (a stale beam, an external `:content_domains`) predates
    # the key, and the safe reading of "we don't know" is "don't syndicate".
    Map.get(descriptor, :published_feed?, false) and to_string(descriptor.type) not in exclude
  end

  @doc """
  Whether entries of `descriptor` carry their rendered body rather than a
  summary. Takes a resolved `policy/1`, for the reason `syndicated?/2` does.
  """
  @spec full_content?(map(), Policy.t()) :: boolean()
  def full_content?(descriptor, %Policy{full_content: full_content}),
    do: to_string(descriptor.type) in full_content

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

  @doc """
  The resolved policy for a `FeedSettings` row (or `nil` for a site that has
  none) — the config layer already folded in underneath.

  Public so the settings page can show what the site does today from the row it
  has already read, rather than reading the same single row a second time
  through `policy/1`.
  """
  @spec for_row(struct() | nil) :: Policy.t()
  def for_row(row), do: build(row)

  defp build(row) do
    %Policy{
      exclude: layer(row && row.excluded_types, config(:exclude, [])),
      full_content: layer(row && row.full_content_types, config(:full_content, []))
    }
  end

  # `nil` at the org layer falls through to the operator default; `[]` does not
  # — `[]` is truthy in Elixir, so `||` says exactly that. Everything is
  # normalized to a list of strings, so a config written with atoms
  # (`exclude: [:page]`) or with a bare value instead of a list still compares
  # against a descriptor's name rather than silently matching nothing.
  defp layer(names, default), do: normalize(names || default)

  # `List.wrap/1` rather than a list guard, so `exclude: "page"` — an operator
  # writing the bare value instead of a list — still means the type they named.
  # Dropping it to `[]` would fail *open*: the type the operator meant to remove
  # from syndication would keep its public feed route, silently. Anything that is
  # not a name (a number, a tuple) is discarded rather than stringified into a
  # value nothing can match.
  defp normalize(names) do
    for name <- List.wrap(names), is_binary(name) or is_atom(name), do: to_string(name)
  end

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
    # rather than 500ing the site — to `unavailable/0`, which is summaries-only,
    # NOT to the operator config. The message says which, because "using
    # defaults" would describe the fallback this deliberately does not take.
    error ->
      Logger.warning(
        "feed settings lookup failed; syndicating summaries only: #{Exception.message(error)}"
      )

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
