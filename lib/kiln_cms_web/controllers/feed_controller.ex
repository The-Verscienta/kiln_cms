defmodule KilnCMSWeb.FeedController do
  @moduledoc """
  Atom 1.0 and JSON Feed 1.1 syndication for the public delivery site (#486).

  `/feed.xml` and `/feed.json` carry the newest published records across every
  syndicated content type; `/<plural>/feed.xml` and `/<plural>/feed.json` carry
  one type. Which types syndicate, and whether entries carry a summary or the
  rendered body, is `KilnCMS.Feeds`.

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
  def index(conn, _params), do: render_feed(conn, nil, :atom)
  def index_json(conn, _params), do: render_feed(conn, nil, :json)

  def type(conn, %{"plural" => plural}), do: render_type(conn, plural, :atom)
  def type_json(conn, %{"plural" => plural}), do: render_type(conn, plural, :json)

  defp render_type(conn, plural, feed_format) do
    org = Tenant.current_org(conn)

    case find_type(org.id, plural) do
      nil -> conn |> put_status(404) |> text("")
      descriptor -> render_feed(conn, descriptor, feed_format)
    end
  end

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
  defp render_feed(conn, descriptor, :atom) do
    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, cached_body(conn, descriptor, :atom))
  end

  # sobelow_skip ["XSS.SendResp"]
  defp render_feed(conn, descriptor, :json) do
    conn
    |> put_resp_content_type("application/feed+json")
    |> send_resp(200, cached_body(conn, descriptor, :json))
  end

  defp cached_body(conn, descriptor, feed_format) do
    org = Tenant.current_org(conn)
    key = Cache.feed_key(org.id, descriptor && to_string(descriptor.type), feed_format)

    Cache.fetch(key, @cache_ttl, fn ->
      org |> entries(descriptor) |> serialize(org, descriptor, feed_format)
    end)
  end

  # ── entries ───────────────────────────────────────────────────────────────

  defp entries(org, descriptor) do
    limit = Feeds.entry_limit()
    types = if descriptor, do: [descriptor], else: Feeds.syndicated_types(org.id)

    types
    |> Enum.flat_map(&type_entries(&1, org, limit))
    # Ordered and capped on the SAME key the per-type reads selected on. Sorting
    # the merged set by `updated_at` instead would let a bulk copy-edit of fifty
    # old records evict a post published five minutes ago — silently, and
    # permanently, since stable entry ids mean it is never re-notified once it
    # re-enters the window.
    |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp type_entries(descriptor, org, limit) do
    descriptor
    |> ContentTypes.list!(
      authorize?: true,
      tenant: org.id,
      query: [
        # Published *and* public — see the moduledoc. An `audience` other than
        # `:public` is gated content that happens to be published.
        #
        # One locale, too: a record translated into three languages is three
        # rows, and a feed carrying all three re-notifies every subscriber (and
        # every "new post → campaign" automation) three times per publish. The
        # sitemap wants every locale; a feed wants one.
        filter: [audience: :public, locale: KilnCMS.I18n.default_locale()],
        sort: [published_at: :desc],
        limit: limit,
        # Only the fields the serializer reads. Without this every entry drags
        # its whole `blocks` union tree and its embedding vector into memory —
        # the spike `SitemapController` avoids the same way, and this route is
        # anonymous.
        select: select_fields(descriptor)
      ]
    )
    |> Enum.map(&entry(&1, descriptor, org))
  end

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
      published_at: published_at,
      updated_at: record.updated_at
    }
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
  defp serialize(entries, org, descriptor, :atom) do
    base_url = Tenant.base_url(org)
    self_url = base_url <> feed_path(descriptor, :atom)
    title = feed_title(org, descriptor)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>#{escape(title)}</title>
      <id>#{escape(self_url)}</id>
      <link rel="self" href="#{escape(self_url)}" type="application/atom+xml"/>
      <link rel="alternate" href="#{escape(base_url)}" type="text/html"/>
      <updated>#{feed_updated(entries)}</updated>
      <author><name>#{escape(feed_title(org, nil))}</name></author>
    #{Enum.map_join(entries, "\n", &atom_entry/1)}
    </feed>
    """
  end

  defp serialize(entries, org, descriptor, :json) do
    base_url = Tenant.base_url(org)

    Jason.encode!(%{
      "version" => "https://jsonfeed.org/version/1.1",
      "title" => feed_title(org, descriptor),
      "home_page_url" => base_url,
      "feed_url" => base_url <> feed_path(descriptor, :json),
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
    #{content}
      </entry>\
    """
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

  defp feed_title(org, nil), do: KilnCMS.Branding.for_org(org.id).site_name

  defp feed_title(org, descriptor),
    do: "#{KilnCMS.Branding.for_org(org.id).site_name} — #{descriptor.label}"

  @doc """
  The path a feed is served at — shared with the autodiscovery `<link>` tags so
  the advertised URL and the routed one cannot drift.
  """
  @spec feed_path(map() | nil, :atom | :json) :: String.t()
  def feed_path(nil, :json), do: "/feed.json"
  def feed_path(nil, :atom), do: "/feed.xml"
  def feed_path(descriptor, :json), do: "#{feed_prefix(descriptor)}/feed.json"
  def feed_path(descriptor, :atom), do: "#{feed_prefix(descriptor)}/feed.xml"

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
