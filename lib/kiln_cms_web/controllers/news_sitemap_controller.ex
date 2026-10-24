defmodule KilnCMSWeb.NewsSitemapController do
  @moduledoc """
  The Google News sitemap, `/news-sitemap.xml` (#2045).

  Google News reads a sitemap of its own beside `/sitemap.xml`: every `<url>`
  carries a `<news:news>` element with the publication's name and language, the
  article's publication date and its title. Google's rules for it are narrower
  than the sitemaps protocol's, and this route follows them:

    * **Only articles published in the last 48 hours.** Older URLs are ignored by
      Google News, and a news sitemap padded with them is one it reads less of.
    * **At most 1,000 URLs**, the newest first.
    * **Listed from `robots.txt`** (`KilnCMSWeb.SitemapController.robots/2`).

  ## Which types, and the opt-in

  A content type is in the news sitemap when its schema.org type is
  `NewsArticle`: the Content macro's `schema_org_type:` option for a compiled
  type, `TypeDefinition.schema_org_type` for a dynamic one. That declaration is
  the opt-in. A site with no such type serves an empty, well-formed `<urlset>` and
  `robots.txt` does not advertise the route.

  ## What may appear

  Published, `audience: :public` records only, exactly as the feeds
  (`KilnCMSWeb.FeedController`): the actor-less read returns published records,
  and the audience filter is explicit because *published* is not *public*. An
  audience-gated article never appears, so `<news:access>` is never needed.

  ## Caching

  Per org, under the same short TTL as `/sitemap.xml` and the same `:probe` rate
  limit. `KilnCMS.Cache.bust_sitemap/1`, which every publish and unpublish
  already calls, drops this key too, so an unpublished article is gone on the
  next request. An article can outlive its 48 hours by at most the TTL.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.Tenant

  # Google News' cap on a single news sitemap.
  @max_urls 1_000

  # How far back an article may have been published and still be listed.
  @window_hours 48

  @cache_ttl :timer.minutes(5)

  @news_type "NewsArticle"

  # Only what the XML reads — see `SitemapController.build_urls/1` for why.
  @fields [:title, :slug, :path_alias, :locale, :published_at]

  def index(conn, _params) do
    org = Tenant.current_org(conn)

    xml = Cache.fetch(Cache.news_sitemap_key(org.id), @cache_ttl, fn -> build(org) end)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  @doc """
  The org's content types that opted into the news sitemap by declaring the
  schema.org type `NewsArticle`.
  """
  @spec news_types(Ash.UUID.t() | struct()) :: [ContentTypes.t()]
  def news_types(org), do: Enum.filter(ContentTypes.all_for_org(org), &news_type?/1)

  defp news_type?(%{source: :dynamic, definition: definition}),
    do: definition.schema_org_type == @news_type

  defp news_type?(%{resource: resource}) do
    function_exported?(resource, :__kiln_schema_org_type__, 0) and
      resource.__kiln_schema_org_type__() == @news_type
  end

  defp build(org) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_hours, :hour)
    base_url = Tenant.base_url(org)
    publication = KilnCMS.Branding.for_org(org.id).site_name

    org.id
    |> news_types()
    |> Enum.flat_map(&type_records(&1, org, cutoff))
    # Each type's read is already newest-first and capped; the merge is ordered
    # and capped on the same key, so a busy type can't crowd out a newer item.
    |> Enum.sort_by(fn {record, _ct} -> record.published_at end, {:desc, DateTime})
    |> Enum.take(@max_urls)
    |> Enum.map(fn {record, ct} -> url_xml(record, ct, base_url, publication) end)
    |> urlset()
  end

  # No actor + `authorize?: true` ⇒ published records only (the read policy);
  # `audience: :public` keeps gated content out — see the moduledoc.
  defp type_records(ct, org, cutoff) do
    ct
    |> ContentTypes.list!(
      authorize?: true,
      tenant: org.id,
      query: [
        filter: [audience: :public, published_at: [greater_than_or_equal: cutoff]],
        sort: [published_at: :desc],
        limit: @max_urls,
        select: @fields
      ]
    )
    |> Enum.map(&{&1, ct})
  end

  defp url_xml(record, ct, base_url, publication) do
    loc = "#{base_url}#{locale_prefix(record.locale)}#{public_path(record, ct)}"

    """
      <url>
        <loc>#{escape(loc)}</loc>
        <news:news>
          <news:publication>
            <news:name>#{escape(publication)}</news:name>
            <news:language>#{language(record.locale)}</news:language>
          </news:publication>
          <news:publication_date>#{DateTime.to_iso8601(record.published_at)}</news:publication_date>
          <news:title>#{escape(record.title || "")}</news:title>
        </news:news>
      </url>
    """
  end

  defp urlset(urls) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">
    #{Enum.join(urls)}</urlset>
    """
  end

  @doc """
  The `<news:language>` for a record's locale. Google wants a bare ISO 639 code
  (`en`, not `en-GB`), except for Chinese, which must say `zh-cn` (Simplified)
  or `zh-tw` (Traditional).
  """
  @spec language(String.t() | nil) :: String.t()
  def language(locale) when is_binary(locale) do
    [primary | rest] = locale |> String.downcase() |> String.split(["-", "_"])

    case {primary, rest} do
      {"zh", [region | _]} when region in ~w(tw hk mo hant) -> "zh-tw"
      {"zh", _} -> "zh-cn"
      _ -> primary
    end
  end

  def language(_locale), do: language(KilnCMS.I18n.default_locale())

  defp public_path(%{path_alias: alias_path}, _ct) when is_binary(alias_path), do: alias_path
  defp public_path(record, ct), do: "#{ContentTypes.public_prefix(ct)}/#{record.slug}"

  defp locale_prefix(locale) do
    if locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{locale}"
  end

  defdelegate escape(value), to: KilnCMS.Xml
end
