defmodule KilnCMSWeb.OfflineController do
  @moduledoc """
  The service worker's offline fallback, per organization (#629).

  Was `priv/static/offline.html` — a static file with no org context, so a
  white-labelled site's reviewer hit a page branded KilnCMS the moment their
  train went into a tunnel. A controller resolves the org from the request host
  the same way every other page does (`SetTenant`), so each site gets its own
  name and brand colour with no per-site build step.

  ## Still entirely self-contained

  This document is **precached by `sw.js` at install** and rendered when the
  network is gone, so it may not reference anything it would have to fetch: no
  stylesheet, no script, no image, no font. Inline `<style>` only.

  That constraint is why branding here is the site **name and colour** and not
  the logo: an `<img>` would be a network request, which is the one thing this
  page cannot make.

  There is no script here at all, which is the other half of the same rule — a
  page served from cache cannot carry the per-request nonce the app's browser
  pipelines mint. Escaping is what stands between an operator-supplied site name
  and the rendered document, so every interpolation goes through `escape/1` (see
  `page/1`), and `show/2` sends a `default-src 'none'` CSP behind it, which is
  exact rather than merely strict: this document loads nothing at all.

  ## Unauthenticated on purpose

  The service worker precaches it at install, before any navigation, and serves
  it for a failed navigation — including one to a page the visitor could not
  have read. It therefore carries nothing an anonymous visitor could not
  already see on the site's own front page: a name and a colour.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Branding

  # The stock ember, matching `ManifestController` and `--color-primary`.
  @default_accent "#ff6200"

  # `private`, not `public`, and that is the whole point of the directive here.
  # The body varies by LOCALE, which `Plugs.SetLocale` reads from the session
  # cookie for a path with no locale prefix — and `/offline.html` is exactly
  # such a path, because the service worker precaches this one URL. A shared
  # cache keyed on host+path would therefore serve the first requester's
  # language to everyone on that host.
  #
  # The manifest reaches the opposite conclusion (`public`) legitimately: it
  # puts the locale in the URL (`?locale=`), so its variants are distinct
  # resources. This one cannot, so it stays out of shared caches instead.
  #
  # NB the short max-age does NOT make a rebrand reach installed devices — see
  # the note in `sw.js`, which is where that actually happens. Cache Storage
  # ignores `Cache-Control` entirely.
  @cache_control "private, max-age=300"

  @doc "The offline fallback document for the requesting site."
  # The body is built by `page/1` below, which escapes every interpolation. It
  # cannot be a template: the whole document has to be one self-contained string
  # with no layout and no asset references.
  # sobelow_skip ["XSS.SendResp"]
  def show(conn, _params) do
    brand = Branding.for_org(conn.assigns[:current_org])

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", @cache_control)
    # This is the first HTML surface on the `:probe` pipeline, which carries no
    # `put_secure_browser_headers` of its own — the other routes there serve
    # XML and JSON. Escaping is the actual defence (see `page/1`), but a page
    # built by string interpolation should not also be the one page on the
    # origin with no headers behind it. `default-src 'none'` is exact here: the
    # document genuinely loads nothing.
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    )
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> send_resp(200, page(brand))
  end

  # Built here rather than as a HEEx template because the whole document has to
  # be one self-contained string with no layout, no `csrf` tag and no asset
  # references — which is most of what a template would otherwise give it.
  #
  # Every interpolation is escaped: `site_name` is operator-supplied, and this
  # page carries no CSP of its own (see the moduledoc), so escaping is the only
  # thing between that value and the document.
  defp page(brand) do
    name = escape(brand.site_name)
    {light_accent, dark_accent} = accents(brand)

    # Every interpolation into the document goes through `escape/1`, including
    # the translated strings. A `.po` entry is repo-reviewed, so this is not
    # where the threat is — but a uniform rule is one an added line cannot get
    # wrong, and HEEx would have escaped these too.
    # `lang` above is the *request's* locale rather than the default, because
    # these strings are too — the worker precaches this page once, at install,
    # so the cached copy speaks whatever language the installing session did.
    # That is the right answer here and the wrong one for the manifest, which
    # keys locale off the URL instead (#630): a manifest names the installed app
    # forever, whereas this is one page the same person reads.
    title = escape(gettext("Offline"))
    heading = escape(gettext("You're offline"))

    blurb =
      escape(
        gettext(
          "This page needs a connection. Your work isn't lost — reconnect and the editor picks up where it left off."
        )
      )

    retry = escape(gettext("Try again"))

    """
    <!DOCTYPE html>
    <html lang="#{escape(Gettext.get_locale(KilnCMSWeb.Gettext))}">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{title} · #{name}</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #fafaf9;
            --fg: #1c1b1a;
            --muted: #6b6a68;
            --accent: #{light_accent};
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #1c1b1a;
              --fg: #f5f5f4;
              --muted: #a3a29f;
              --accent: #{dark_accent};
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            min-height: 100dvh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 2rem 1.5rem;
            background: var(--bg);
            color: var(--fg);
            font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            line-height: 1.6;
          }
          main { max-width: 26rem; text-align: center; }
          .mark {
            display: inline-block;
            padding: 0.75rem 1rem;
            border-radius: 0.75rem;
            background: var(--accent);
            color: #fff;
            font-size: 1rem;
            font-weight: 600;
            letter-spacing: -0.01em;
          }
          h1 {
            margin: 1.25rem 0 0.5rem;
            font-size: 1.375rem;
            font-weight: 600;
            letter-spacing: -0.01em;
          }
          p { margin: 0; color: var(--muted); font-size: 0.9375rem; }
          a {
            display: inline-block;
            margin-top: 1.75rem;
            padding: 0.625rem 1.25rem;
            border: 1px solid currentColor;
            border-radius: 0.5rem;
            color: var(--accent);
            font-size: 0.9375rem;
            font-weight: 500;
            text-decoration: none;
          }
          a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
        </style>
      </head>
      <body>
        <main>
          <span class="mark">#{name}</span>
          <h1>#{heading}</h1>
          <p>#{blurb}</p>
          <a href="/editor">#{retry}</a>
        </main>
      </body>
    </html>
    """
  end

  # Through `Branding.Color.derive/1` rather than interpolated raw, for two
  # reasons. The value is operator-supplied and lands inside a CSS declaration,
  # where a `;` would end it and start another — `derive/1` re-emits from parsed
  # channels, so no user-supplied byte reaches the stylesheet, the same argument
  # `Branding.css_variables/1` makes. And it returns a *contrast-solved* pair,
  # so the accent stays readable in both schemes instead of a raw brand colour
  # vanishing against one of the two backgrounds.
  defp accents(%{brand_color: color}) when is_binary(color) do
    case KilnCMS.Branding.Color.derive(color) do
      {:ok, %{light_primary: light, dark_primary: dark}} -> {light, dark}
      _unparseable -> {@default_accent, @default_accent}
    end
  end

  defp accents(_unbranded), do: {@default_accent, @default_accent}

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
