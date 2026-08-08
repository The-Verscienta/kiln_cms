defmodule KilnCMSWeb.FeedController do
  @moduledoc """
  Atom 1.0 and JSON Feed 1.1 syndication for the public delivery site (#486).

  `/feed.xml` and `/feed.json` carry the newest published records across every
  syndicated content type; `/<plural>/feed.xml` and `/<plural>/feed.json` carry
  one type. Which types syndicate, and whether entries carry a summary or the
  rendered body, is `KilnCMS.Feeds`.

  ## Scoped feeds (#720)

  A campaign tool segments on `<category>`, and a category element is only
  useful if there is a feed narrow enough to act on. So a type's feed also comes
  scoped:

    * `/<plural>/category/<slug>/feed.{xml,json}`
    * `/<plural>/tags/<slug>/feed.{xml,json}`
    * `/<locale>/feed.{xml,json}`

  Entries carry their taxonomy either way — `<category term label>` in Atom,
  `tags` in JSON Feed.

  ## One locale, and why there is a locale feed at all

  The unscoped feeds carry the **default locale only**. A record translated into
  three languages is three rows, and a feed carrying all three re-notifies every
  subscriber — and every "new post → campaign" automation — three times per
  publish.

  That left a reader of a non-default locale with no feed at all, which is a
  worse answer than a noisy one. `/<locale>/feed.xml` drops the default-locale
  filter in favour of that locale, so each language has exactly one feed and no
  subscriber is notified twice. Only configured locales resolve; anything else
  falls through to the type lookup and 404s as before.

  Shaped like `KilnCMSWeb.SitemapController`, deliberately: same per-org scoping,
  same "no actor + `authorize?: true` ⇒ published only" read, same aggregate
  cache key with a short TTL that the existing publish hooks already drop.

  ## What a feed may contain

  **Published, and `audience: :public` only.** The read policy returns published
  records for an actor-less caller, but *published* is not *public* — an
  audience-gated record is published and paywalled, and a feed is fetched by
  anonymous readers, aggregators and mail tools. So the audience filter is
  explicit here rather than inherited: it is the difference between a feed and a
  leak, and it must not depend on a policy staying shaped the way it is today.

  ## Atom, not RSS

  Atom 1.0 has a real spec for the things a feed gets wrong: entry ids are
  required and stable, dates are RFC 3339, and `type="html"` says what the
  content is instead of leaving a reader to guess. Every reader and every
  campaign tool consumes it. JSON Feed 1.1 covers the same ground for anything
  that would rather not parse XML.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Feeds
  alias KilnCMS.Firing
  alias KilnCMSWeb.Tenant

  # Short, like the sitemap's: this aggregate key isn't a `{type, slug}`, so
  # per-record `Cache.bust/3` leaves it alone and the publish hooks drop it
  # explicitly (`Cache.bust_feeds/1`).
  @cache_ttl :timer.minutes(5)

  # A bound on the taxonomy a single entry can carry into the document. A
  # hundred-tag record would otherwise put a hundred `<category>` elements in
  # front of every subscriber, on a route that is fetched on a timer and cached
  # for everyone.
  @max_categories 20

  # Everything the serializer reads, and nothing else — see `select_fields/1`.
  @base_fields [
    :id,
    :title,
    :slug,
    :path_alias,
    :locale,
    :seo_description,
    :published_at,
    :inserted_at,
    :updated_at
  ]

  # One action per (scope, format) rather than a `?format=` parameter: the two
  # serializations are two documents with two content types and two cache keys,
  # and a route that can be asked for either is a route whose cache key depends
  # on user input.
  def index(conn, _params), do: render_feed(conn, nil, scope(conn), :atom)
  def index_json(conn, _params), do: render_feed(conn, nil, scope(conn), :json)

  def type(conn, %{"plural" => plural}), do: render_type(conn, plural, :atom)
  def type_json(conn, %{"plural" => plural}), do: render_type(conn, plural, :json)

  def category(conn, %{"plural" => plural, "slug" => slug}),
    do: render_scoped(conn, plural, {:category, slug}, :atom)

  def category_json(conn, %{"plural" => plural, "slug" => slug}),
    do: render_scoped(conn, plural, {:category, slug}, :json)

  def tag(conn, %{"plural" => plural, "tag" => slug}),
    do: render_scoped(conn, plural, {:tag, slug}, :atom)

  def tag_json(conn, %{"plural" => plural, "tag" => slug}),
    do: render_scoped(conn, plural, {:tag, slug}, :json)

  defp render_type(conn, plural, feed_format) do
    org = Tenant.current_org(conn)

    case find_type(org.id, plural) do
      nil -> not_found(conn)
      descriptor -> render_feed(conn, descriptor, scope(conn), feed_format)
    end
  end

  defp render_scoped(conn, plural, {kind, slug}, feed_format) do
    org = Tenant.current_org(conn)

    with descriptor when not is_nil(descriptor) <- find_type(org.id, plural),
         term when not is_nil(term) <- taxonomy(org.id, kind, slug) do
      render_feed(conn, descriptor, %{scope(conn) | taxonomy: {kind, term}}, feed_format)
    else
      # 404, never an empty feed: a reader who subscribes to a mistyped category
      # gets a document that will never have anything in it and no way to tell.
      _missing -> not_found(conn)
    end
  end

  # A feed's scope is its locale and, optionally, one taxonomy term. Both at
  # once, because they compose: `/fr/blog/category/news/feed.xml` is a real and
  # useful URL, and a scope that could hold only one of them would silently drop
  # the other from the filter *and* from the cache key — two feeds sharing a key.
  #
  # The locale is never routed for. `KilnCMSWeb.Plugs.SetLocale` strips a
  # supported-locale prefix before the router runs, so `/fr/feed.xml` arrives
  # here as `/feed.xml` with `path_locale = "fr"` — the same mechanism that
  # serves every other page in every locale off one set of routes. Adding a
  # `/:locale/feed.xml` route would have been a second, competing way to say it.
  defp scope(conn) do
    %{locale: conn.assigns[:path_locale] || KilnCMS.I18n.default_locale(), taxonomy: nil}
  end

  defp taxonomy(org_id, :category, slug) do
    case KilnCMS.CMS.get_category_by_slug(slug, authorize?: false, tenant: org_id) do
      {:ok, category} -> category
      _other -> nil
    end
  end

  defp taxonomy(org_id, :tag, slug) do
    case KilnCMS.CMS.get_tag_by_slug(slug, authorize?: false, tenant: org_id) do
      {:ok, tag} -> tag
      _other -> nil
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> text("")

  # `/blog/feed.xml` is a static route, so the plural never reaches `type/2` —
  # posts have their own path segment and their own descriptor.
  defp find_type(org_id, plural) do
    org_id
    |> Feeds.syndicated_types()
    |> Enum.find(&(&1.plural == plural or &1.path_segment == plural))
  end

  # The content type is a literal per branch rather than a computed value: it is
  # the header that tells a browser this is a feed and not a document to render,
  # so it must not be reachable from anything a request can influence (and a
  # variable here is a Sobelow `XSS.ContentType` finding for exactly that
  # reason).
  #
  # `body` is server-generated in both branches — the Atom serializer escapes
  # every interpolated value and the JSON one goes through `Jason.encode!/1` —
  # and neither is HTML, so `send_resp/3` carries no XSS sink here.
  # sobelow_skip ["XSS.SendResp"]
  defp render_feed(conn, descriptor, scope, :atom) do
    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, cached_body(conn, descriptor, scope, :atom))
  end

  # sobelow_skip ["XSS.SendResp"]
  defp render_feed(conn, descriptor, scope, :json) do
    conn
    |> put_resp_content_type("application/feed+json")
    |> send_resp(200, cached_body(conn, descriptor, scope, :json))
  end

  defp cached_body(conn, descriptor, scope, feed_format) do
    org = Tenant.current_org(conn)
    key = Cache.feed_key(org.id, cache_scope(descriptor, scope), feed_format)

    Cache.fetch(key, @cache_ttl, fn ->
      org |> entries(descriptor, scope) |> serialize(org, descriptor, scope, feed_format)
    end)
  end

  # Namespaced so a type's own feed and a scoped one cannot collide, and so
  # `Cache.bust_feeds/2` — which drops `{org, type}` across every format — still
  # reaches the unscoped key on publish. Mirrors `CalendarController`'s
  # `cache_scope/2`, which solved the same problem for tag-scoped calendars.
  #
  # The TAXONOMY keys are not enumerated by `bust_feeds/3`, and that is a decision
  # rather than an omission: computing them needs the record's tags and category,
  # and the bust runs in an `after_action` — a relationship load there is a
  # database read inside the publish transaction, which can abort it and lose the
  # publish (#660). Trading a five-minute TTL on a segment feed against losing a
  # publish is not a close call, and it is the trade the tag-scoped calendar
  # already makes.
  #
  # The LOCALE is not in that bargain. `record.locale` is a plain attribute,
  # already on the struct the bust receives, so it costs no read at all — and a
  # locale feed that only ever refreshed on a TTL would leave the one reader the
  # feature exists for as the only one without timely invalidation.
  #
  # The slug is percent-encoded, and not as decoration. Plug decodes path
  # segments, so `%2F` puts a literal `/` inside `:slug` — and a key built by
  # joining on `/` then made `post/category/x/locale/fr` collide with
  # `/fr/blog/category/x/feed.xml`. Two different public documents, one key, five
  # minutes of whichever was fetched first being served to everyone.
  defp cache_scope(descriptor, scope) do
    [
      descriptor && to_string(descriptor.type),
      taxonomy_segment(scope.taxonomy),
      # Only when it differs from the default, so the site-wide feed's key —
      # the one `bust_feeds/3` drops on publish — stays exactly what it was.
      scope.locale != KilnCMS.I18n.default_locale() && "locale/#{encode(scope.locale)}"
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      segments -> Enum.join(segments, "/")
    end
  end

  defp taxonomy_segment(nil), do: nil
  defp taxonomy_segment({kind, term}), do: "#{kind}/#{encode(term.slug)}"

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  # ── entries ───────────────────────────────────────────────────────────────

  defp entries(org, descriptor, scope) do
    limit = Feeds.entry_limit()
    types = if descriptor, do: [descriptor], else: Feeds.syndicated_types(org.id)

    types
    |> Enum.flat_map(&type_entries(&1, org, scope, limit))
    # Ordered and capped on the SAME key the per-type reads selected on. Sorting
    # the merged set by `updated_at` instead would let a bulk copy-edit of fifty
    # old records evict a post published five minutes ago — silently, and
    # permanently, since stable entry ids mean it is never re-notified once it
    # re-enters the window.
    |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp type_entries(descriptor, org, scope, limit) do
    descriptor
    |> ContentTypes.list!(
      authorize?: true,
      tenant: org.id,
      query: [
        filter: filter(scope),
        sort: [published_at: :desc],
        limit: limit,
        # Only the fields the serializer reads. Without this every entry drags
        # its whole `blocks` union tree and its embedding vector into memory —
        # the spike `SitemapController` avoids the same way, and this route is
        # anonymous.
        select: select_fields(descriptor),
        # Two batched queries for the whole page of entries, not two per entry:
        # Ash resolves a `load` across the result set. Bounded on the way OUT
        # (`@max_categories`) rather than here, because a `limit` inside a load
        # is per-record and Postgres has no cheap way to express it.
        load: [:category, :tags]
      ]
    )
    |> Enum.map(&entry(&1, descriptor, org))
  end

  # Published *and* public — see the moduledoc. An `audience` other than
  # `:public` is gated content that happens to be published, and this filter is
  # explicit rather than inherited from the read policy: it is the difference
  # between a feed and a leak.
  #
  # One locale, too, for the reason the moduledoc gives. A locale feed swaps
  # which one rather than dropping the filter, so no record is ever in two feeds
  # a person could subscribe to at once.
  @doc false
  # Public only so a test can assert on it directly. The read policy also filters
  # published-and-public, which meant deleting `audience: :public` from here left
  # the whole suite green — and this module's moduledoc says in as many words
  # that the filter "must not depend on a policy staying shaped the way it is
  # today". An invariant a module claims to own needs a test that fails when it
  # is removed, not one that passes because something else happens to hold.
  def filter(scope),
    do: [audience: :public, locale: scope.locale] ++ taxonomy_filter(scope.taxonomy)

  defp taxonomy_filter({:category, category}), do: [category_id: category.id]
  defp taxonomy_filter({:tag, tag}), do: [tags: [id: tag.id]]
  defp taxonomy_filter(nil), do: []

  # `excerpt` only exists on types that declare it, and selecting an attribute a
  # resource doesn't have is an error rather than a nil.
  defp select_fields(%{excerpt?: true}), do: @base_fields ++ [:excerpt]
  defp select_fields(_descriptor), do: @base_fields

  defp entry(record, descriptor, org) do
    base_url = Tenant.base_url(org)
    url = base_url <> locale_prefix(record.locale) <> public_path(record, descriptor)
    published_at = record.published_at || record.inserted_at

    %{
      id: entry_id(record, descriptor, base_url, published_at),
      url: url,
      title: record.title,
      summary: summary(record),
      content: content(record, descriptor, org),
      categories: categories(record),
      published_at: published_at,
      updated_at: record.updated_at
    }
  end

  # The record's taxonomy, as `{term, label}` — Atom's own two attributes, and
  # the shape JSON Feed's flat `tags` array is derived from (#720).
  #
  # Category first: a record has at most one, and it is the coarse axis a
  # campaign tool segments on. `%Ash.NotLoaded{}` and `nil` both fall through to
  # an empty list rather than raising — a serializer is not the place to
  # discover that a load was dropped, and a feed entry missing its categories is
  # a smaller failure than a feed that 500s for every subscriber.
  defp categories(record) do
    category =
      case Map.get(record, :category) do
        %{slug: slug, name: name} -> [{slug, name}]
        _absent -> []
      end

    tags =
      case Map.get(record, :tags) do
        list when is_list(list) -> for %{slug: slug, name: name} <- list, do: {slug, name}
        _absent -> []
      end

    (category ++ tags) |> Enum.uniq_by(&elem(&1, 0)) |> Enum.take(@max_categories)
  end

  # A tag URI (RFC 4151), not the page URL: an entry id must survive the record
  # moving to a new slug, or every reader re-notifies the whole feed on a rename.
  #
  # The date comes from the record's own publish instant, never from "today" —
  # `Date.utc_today()` would rewrite every id at midnight on 1 January and
  # re-notify the entire archive, which is the failure the tag URI exists to
  # prevent. `authority_name` falls back to a literal because a `base_url`
  # configured without a scheme parses with a nil host, and an id must not
  # silently change identity the day someone adds `https://`.
  defp entry_id(record, descriptor, base_url, published_at) do
    authority = URI.parse(base_url).host || "kiln"

    "tag:#{authority},#{Date.to_iso8601(DateTime.to_date(published_at))}:#{descriptor.type}/#{record.id}"
  end

  # `excerpt` where the type has one, else the SEO description — the two fields
  # an editor already writes as "what this is about". Never a truncated body:
  # a machine-cut sentence reads worse than nothing in a reader's list view.
  defp summary(record) do
    [Map.get(record, :excerpt), Map.get(record, :seo_description)]
    |> Enum.find("", &(is_binary(&1) and &1 != ""))
  end

  defp content(record, descriptor, org) do
    if Feeds.full_content?(descriptor) do
      rendered_html(record, descriptor, org)
    else
      nil
    end
  end

  # The fired `:web` artifact — the same HTML the delivery site serves, already
  # sanitized on the way in. Falling back to the summary rather than raising:
  # a record whose artifact hasn't been fired yet (or was swept) should appear
  # in the feed with less in it, not take the whole feed down.
  #
  # The storage type comes from the *record*, via the same helper the firing
  # pipeline persists under. Deriving it from the descriptor's name instead was
  # wrong twice over: dynamic types deliberately never mint atoms (D17), so
  # `String.to_existing_atom/1` raised and 500'd the whole site-wide feed, and
  # every dynamic-tier artifact is stored under `:entry` regardless of the
  # type's own name, so even a name that happened to exist would never match.
  defp rendered_html(record, _descriptor, org) do
    case Firing.Engine.read(org.id, Firing.Engine.document_type(record), record.id, :web) do
      {:ok, %{"html" => html}} when is_binary(html) -> html
      _other -> nil
    end
  end

  defp public_path(%{path_alias: alias_path}, _descriptor) when is_binary(alias_path),
    do: alias_path

  defp public_path(record, descriptor),
    do: "#{ContentTypes.public_prefix(descriptor)}/#{record.slug}"

  defp locale_prefix(locale) do
    if locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{locale}"
  end

  # ── serialization ─────────────────────────────────────────────────────────

  # RFC 4287 §4.1.1 requires an author on the feed or on every entry; one at
  # feed level covers them all, and the site is the honest answer. A per-entry
  # byline would mean loading the author relationship for every record, and
  # author identity is deliberately not treated as feed-facing data elsewhere.
  defp serialize(entries, org, descriptor, scope, :atom) do
    base_url = Tenant.base_url(org)
    self_url = base_url <> scoped_path(descriptor, scope, :atom)
    title = feed_title(org, descriptor, scope)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>#{escape(title)}</title>
      <id>#{escape(self_url)}</id>
      <link rel="self" href="#{escape(self_url)}" type="application/atom+xml"/>
      <link rel="alternate" href="#{escape(base_url)}" type="text/html"/>
      <updated>#{feed_updated(entries)}</updated>
      <author><name>#{escape(feed_title(org, nil, nil))}</name></author>
    #{Enum.map_join(entries, "\n", &atom_entry/1)}
    </feed>
    """
  end

  defp serialize(entries, org, descriptor, scope, :json) do
    base_url = Tenant.base_url(org)

    Jason.encode!(%{
      "version" => "https://jsonfeed.org/version/1.1",
      "title" => feed_title(org, descriptor, scope),
      "home_page_url" => base_url,
      "feed_url" => base_url <> scoped_path(descriptor, scope, :json),
      # A locale feed says which language it is in; JSON Feed 1.1 added the
      # field for exactly this, and without it a reader aggregating several has
      # nothing to tell them apart by.
      "language" => scope.locale,
      "items" => Enum.map(entries, &json_item/1)
    })
  end

  defp atom_entry(entry) do
    # `type="html"` on both, because that is what they are: an escaped HTML
    # string, not text a reader should render literally.
    content =
      if entry.content do
        "    <content type=\"html\">#{escape(entry.content)}</content>"
      else
        "    <summary type=\"html\">#{escape(entry.summary)}</summary>"
      end

    """
      <entry>
        <title>#{escape(entry.title)}</title>
        <id>#{escape(entry.id)}</id>
        <link rel="alternate" href="#{escape(entry.url)}" type="text/html"/>
        <published>#{DateTime.to_iso8601(entry.published_at)}</published>
        <updated>#{DateTime.to_iso8601(entry.updated_at)}</updated>
    #{atom_categories(entry)}#{content}
      </entry>\
    """
  end

  # `term` is the slug and `label` the display name — RFC 4287 §4.2.2 makes
  # `term` the machine-readable one, and a campaign tool filtering on a
  # human-facing name breaks the moment an editor renames a tag. No `scheme`:
  # it is optional, and a URI that is not a real dereferenceable namespace is
  # noise a reader has to ignore.
  defp atom_categories(%{categories: []}), do: ""

  defp atom_categories(entry) do
    Enum.map_join(entry.categories, "", fn {term, label} ->
      ~s(    <category term="#{escape(term)}" label="#{escape(label)}"/>\n)
    end)
  end

  # JSON Feed 1.1 requires at least one of `content_html` / `content_text` on
  # every item — `summary` is defined as a supplement to content, not a
  # substitute, and an item with neither renders as an empty body in any reader
  # that shows content. So the summary doubles as `content_text` when there is
  # no rendered body, which is also the honest typing: a summary is plain text.
  defp json_item(entry) do
    base = %{
      "id" => entry.id,
      "url" => entry.url,
      "title" => entry.title,
      "summary" => entry.summary,
      "date_published" => DateTime.to_iso8601(entry.published_at),
      "date_modified" => DateTime.to_iso8601(entry.updated_at)
    }

    # JSON Feed 1.1 `tags` is a flat array of strings, so the label is what goes
    # in — the slug is Atom's `term`, and JSON Feed has no second field to put it
    # in. Omitted entirely when empty: the spec says an item "may" have tags, and
    # an empty array in every item is bytes on a route fetched on a timer.
    base = if entry.categories == [], do: base, else: Map.put(base, "tags", labels(entry))

    if entry.content do
      Map.put(base, "content_html", entry.content)
    else
      Map.put(base, "content_text", entry.summary)
    end
  end

  # An empty feed still needs an `<updated>`; Atom requires it and a reader will
  # reject the document without one.
  defp feed_updated([]), do: DateTime.to_iso8601(DateTime.utc_now())
  defp feed_updated(entries), do: DateTime.to_iso8601(hd(entries).updated_at)

  defp labels(entry), do: Enum.map(entry.categories, &elem(&1, 1))

  defp feed_title(org, descriptor, scope) do
    [
      KilnCMS.Branding.for_org(org.id).site_name,
      descriptor && descriptor.label,
      scope_label(scope)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
  end

  defp scope_label(%{taxonomy: {_kind, term}}), do: term.name
  defp scope_label(_scope), do: nil

  @doc """
  The path a feed is served at — shared with the autodiscovery `<link>` tags so
  the advertised URL and the routed one cannot drift.
  """
  @spec feed_path(map() | nil, :atom | :json) :: String.t()
  def feed_path(descriptor, format), do: scoped_path(descriptor, nil, format)

  @doc """
  The path a scoped feed is served at (#720) — a type's category, tag or locale.

  Same contract as `feed_path/2`, and the same reason for existing: the
  autodiscovery `<link>` and the route cannot drift if both come from here.
  """
  @spec scoped_path(map() | nil, scope() | nil, :atom | :json) :: String.t()
  def scoped_path(descriptor, scope, format) do
    scope_locale_prefix(scope) <>
      type_prefix(descriptor) <> taxonomy_prefix(scope) <> "/feed." <> extension(format)
  end

  @typedoc "A feed's locale, and optionally the one taxonomy term it is narrowed to."
  @type scope :: %{locale: String.t(), taxonomy: nil | {:category | :tag, map()}}

  defp extension(:atom), do: "xml"
  defp extension(:json), do: "json"

  # The locale prefixes the whole path, exactly as it does for every other URL on
  # the delivery site — `SetLocale` strips it back off on the way in.
  defp scope_locale_prefix(%{locale: locale}), do: locale_prefix(locale)
  defp scope_locale_prefix(_scope), do: ""

  defp type_prefix(nil), do: ""
  defp type_prefix(descriptor), do: feed_prefix(descriptor)

  # Encoded for the same reason the cache key is: a slug carrying `/` or `..`
  # would otherwise put traversal segments into the `<id>` and `rel="self"` of a
  # public document, and a feed id is supposed to be stable and unambiguous.
  defp taxonomy_prefix(%{taxonomy: {:category, category}}),
    do: "/category/" <> encode(category.slug)

  defp taxonomy_prefix(%{taxonomy: {:tag, tag}}), do: "/tags/" <> encode(tag.slug)
  defp taxonomy_prefix(_scope), do: ""

  # The type's public prefix where it has one (`/blog/feed.xml` for posts), and
  # its plural otherwise (`/pages/feed.xml`). NOT `public_prefix/1` unguarded:
  # that returns "" for a type served at `<base>/<slug>`, which would put its
  # feed at `/feed.xml` — the site-wide feed's own URL. `find_type/2` matches
  # either segment, so both spellings resolve.
  defp feed_prefix(%{path_segment: segment}) when is_binary(segment) and segment != "",
    do: "/" <> segment

  defp feed_prefix(%{plural: plural}), do: "/" <> plural

  # XML 1.0 has no escape form for the C0 control characters, so a title
  # containing one — a form feed pasted out of Word, say — makes the *whole
  # document* unparseable for every subscriber, not just its own entry. Postgres
  # stores them happily and nothing upstream rejects them, so they are dropped
  # here. Tab, newline and carriage return are the three that are legal.
  @illegal_xml ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{FFFE}\x{FFFF}]/u

  # `"` and `'` are escaped as well as the three that matter in element text:
  # this output also lands in quoted *attribute* values (`href="…"`), and the
  # serializer must not depend on a validation elsewhere staying shaped as it is
  # — the same argument the moduledoc makes for the audience filter.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace(@illegal_xml, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
