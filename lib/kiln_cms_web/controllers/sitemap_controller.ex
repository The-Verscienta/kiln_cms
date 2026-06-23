defmodule KilnCMSWeb.SitemapController do
  @moduledoc """
  Auto-generated `sitemap.xml` and `robots.txt` for the public delivery
  frontend. Lists every published content record at its public URL — pages at
  `<base>/<slug>`, posts at `<base>/blog/<slug>`, and other content types at
  `<base>/<plural>/<slug>` — discovered through `KilnCMS.CMS.ContentTypes`. The
  base URL is `:public_base_url` config.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes

  def index(conn, _params) do
    # No actor + `authorize?: true` ⇒ the read policy returns published records
    # only, which is exactly what belongs in a public sitemap.
    urls =
      Enum.flat_map(ContentTypes.all(), fn ct ->
        ct.type
        |> ContentTypes.list!(authorize?: true)
        |> page_entries(ContentTypes.public_prefix(ct))
      end)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, sitemap_xml(urls))
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
        loc: "#{base_url()}#{prefix}/#{record.slug}",
        lastmod: DateTime.to_iso8601(record.updated_at)
      }
    end)
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
