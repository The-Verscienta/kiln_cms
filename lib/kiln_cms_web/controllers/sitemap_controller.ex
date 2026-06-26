defmodule KilnCMSWeb.SitemapController do
  @moduledoc """
  Auto-generated `sitemap.xml` and `robots.txt` for the public delivery
  frontend. Lists every published content record at its public URL — pages at
  `<base>/<slug>`, posts at `<base>/blog/<slug>`, and other content types at
  `<base>/<plural>/<slug>` — discovered through `KilnCMS.CMS.ContentTypes`. The
  base URL is `:public_base_url` config.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes

  # The sitemaps protocol caps a single sitemap at 50,000 URLs. Enforce that as a
  # hard ceiling so the per-request scan (and response) is bounded no matter how
  # much published content exists.
  @max_urls 50_000

  # Repeated hits within this window reuse the rendered XML instead of
  # re-scanning every published row. Busted immediately on any content write
  # (`KilnCMS.Cache.bust_published/0`), so it never serves stale content long.
  @cache_ttl :timer.minutes(5)

  def index(conn, _params) do
    xml = Cache.fetch("sitemap:xml", @cache_ttl, fn -> sitemap_xml(build_urls()) end)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  # No actor + `authorize?: true` ⇒ the read policy returns published records
  # only, which is exactly what belongs in a public sitemap. Each type's read is
  # capped, and accumulation stops once the overall ceiling is reached.
  defp build_urls do
    Enum.reduce_while(ContentTypes.all(), [], fn ct, acc ->
      remaining = @max_urls - length(acc)

      if remaining <= 0 do
        {:halt, acc}
      else
        entries =
          ct.type
          |> ContentTypes.list!(authorize?: true, query: [limit: remaining])
          |> page_entries(ContentTypes.public_prefix(ct))

        {:cont, acc ++ entries}
      end
    end)
  end

  def robots(conn, _params) do
    body = """
    User-agent: *
    Allow: /

    Sitemap: #{base_url()}/sitemap.xml
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  defp page_entries(records, prefix) do
    Enum.map(records, fn record ->
      %{
        loc: "#{base_url()}#{locale_prefix(record.locale)}#{prefix}/#{record.slug}",
        lastmod: DateTime.to_iso8601(record.updated_at)
      }
    end)
  end

  # Non-default locales are served under a `/<locale>` URL prefix.
  defp locale_prefix(locale) do
    if locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{locale}"
  end

  defp sitemap_xml(urls) do
    body =
      Enum.map_join(urls, "\n", fn %{loc: loc, lastmod: lastmod} ->
        "  <url><loc>#{escape(loc)}</loc><lastmod>#{lastmod}</lastmod></url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{body}
    </urlset>
    """
  end

  defp base_url, do: Application.get_env(:kiln_cms, :public_base_url, "http://localhost:4000")

  # Minimal XML-entity escaping for the (already URL-ish) slug values.
  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
