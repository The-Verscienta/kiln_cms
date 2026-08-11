defmodule KilnCMSWeb.ManifestController do
  @moduledoc """
  The web app manifest for the installable editor PWA (issue #65).

  Served from a controller rather than `priv/static` because the manifest is
  **per-org** (#48): `name` and `theme_color` come from
  `KilnCMS.Branding.for_org/1`, so each white-labelled site installs under its
  own name and brand colour. The endpoint's `SetTenant` plug has already
  resolved `:current_org` from the host, so this needs no tenant work of its own.

  Deliberately unauthenticated: the browser fetches the manifest as a
  subresource of whatever page links it, and it carries nothing that isn't
  already rendered into that page's `<head>`. The link itself is only emitted on
  editor/admin pages (see `KilnCMSWeb.LiveUserAuth`), so a public reader is
  never offered the install prompt.

  `start_url` is the review queue — the flow the spike in
  `docs/mobile-admin-spike.md` identifies as the mobile use case — while `scope`
  stays at `/` so a sign-in redirect (`/sign-in`) or a preview of published
  content stays inside the installed window instead of kicking out to a browser
  tab.

  ## Localization (#630)

  The strings here *are* translated, but only because the manifest URL carries
  the locale: the root layout links `?locale=<the request's locale>`, so each
  locale is a distinct resource. Translating against the request's Gettext
  locale from ONE URL would have meant the installed app was labelled in
  whichever locale happened to trigger the first fetch — worse than one
  consistent label, and dependent on cache timing. That is why this was left
  untranslated until there was a locale-scoped URL to hang it off.

  A query parameter rather than a `/:locale/` path segment: this route lives in
  the same scope as the public content routes, where `/:plural/:slug` would have
  to be ordered against a two-segment `/:locale/manifest.webmanifest`. A query
  string needs no such ordering argument, and the manifest spec resolves `id`,
  `start_url` and `scope` relative to the manifest URL either way.

  ### The install id stays locale-independent

  #630 suggested giving each locale variant its own `id`, so the locales become
  distinct installed apps. This does **not** do that, because the consequence is
  worse than the one the issue weighed:

  A manifest whose processed `id` does not match an installed app's id is not
  treated as a rename — the whole update is **discarded**. An editor who
  installed before this shipped has `id: "/editor"`; if their session locale is
  `fr` they would now be served `"/editor?locale=fr"`, and that install would
  stop receiving *every* future manifest change — `theme_color`, icons,
  `start_url`, `scope`, shortcuts, and every per-org branding edit (#48) — while
  the browser offered the site again as a second installable app.

  A locale-dependent id is also unstable under `config :kiln_cms, :i18n,
  default_locale:`, which is an operator-facing setting: moving the default from
  `en` to `fr` would flip both ids at once and orphan 100% of installs from a
  one-line config edit.

  And the thing per-locale ids were protecting barely exists. Android labels the
  home-screen icon from `short_name`, which stays untranslated here on purpose
  (it is the operator's brand name, a proper noun); iOS ignores the manifest
  entirely and takes its name from `apple-mobile-web-app-title`. What the
  translations actually reach is the install dialog, the app list, the splash
  screen and the long-press shortcut menu — worth having, and not worth
  orphaning installs for.

  So: one `id`, and an already-installed app may end up displaying whichever
  locale it most recently fetched. That is the trade-off #630 listed as the
  alternative, chosen deliberately with information the issue did not have.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Branding
  alias KilnCMS.I18n

  # The icon tile's background (see `priv/static/images/app-icon-*.png`). Used
  # for the splash screen so the launch matches the installed icon.
  @background_color "#1c1b1a"

  # Stock ember, for a site that hasn't set a brand colour. Mirrors
  # `--color-primary` in `assets/css/app.css`.
  @default_theme_color "#ff6200"

  # Five minutes: long enough to absorb the burst of fetches a page load causes,
  # short enough that a branding or locale change is not stuck behind a CDN.
  @max_age_seconds 300

  @doc "The per-org, per-locale web app manifest (`application/manifest+json`)."
  def show(conn, params) do
    brand = Branding.for_org(conn.assigns[:current_org])
    # Through `I18n.normalize/1`, so an unsupported or absent `?locale=` falls
    # to the default rather than 404ing or trusting the query string — this is
    # an unauthenticated endpoint, and the parameter is raw client input.
    locale = I18n.normalize(params["locale"])

    # Scoped to this request: `put_locale/2` is per-process, and the request
    # process is this one. The layout's link is what decides which locale a
    # browser asks for; nothing here reads the session.
    Gettext.put_locale(KilnCMSWeb.Gettext, locale)

    conn
    |> put_resp_content_type("application/manifest+json")
    # Explicit, because the response now varies by query string and this is
    # deployed behind a CDN. RFC 9111 puts the query in the cache key, so a
    # conforming cache separates the locales on its own — but a front door
    # configured to cache-everything-and-ignore-query-strings would serve
    # whichever locale was fetched first to everyone and make this inert. Short
    # enough that a branding change (#48) shows up on the next install prompt.
    # No `Vary`: the locale is in the URL, not a request header.
    |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
    |> json(manifest(brand, locale))
  end

  defp manifest(brand, locale) do
    %{
      # A stable identity across redeploys, brand renames AND locales — see the
      # moduledoc. Deliberately not locale-dependent: a mismatched id makes the
      # browser discard the entire manifest update, not just the name.
      id: "/editor",
      # `short_name` is the brand's own name and is deliberately NOT translated:
      # it is a proper noun, and a white-label operator's site name means the
      # same thing in every language.
      name: gettext("%{site} Editor", site: brand.site_name),
      short_name: brand.site_name,
      description: gettext("Review, approve and publish %{site} content.", site: brand.site_name),
      # Declares what the translated strings above are IN, so a browser renders
      # and sorts them correctly — and so `dir: auto` has something to resolve.
      lang: locale,
      dir: "auto",
      start_url: "/editor?status=in_review",
      scope: "/",
      display: "standalone",
      theme_color: brand.brand_color || @default_theme_color,
      background_color: @background_color,
      categories: ["productivity", "business"],
      icons: icons(brand),
      shortcuts: shortcuts(brand)
    }
  end

  # `any` and `maskable` are separate images, not one image with both purposes:
  # a maskable icon is drawn with a 40% safe zone, so reusing it as `any` would
  # render a small mark floating in a large tile everywhere the mask isn't
  # applied.
  #
  # ## The brand icon, when there is a verified one (#629)
  #
  # `Branding.verified_app_icon/1` is the gate, and it is the same gate the
  # shortcuts and the `apple-touch-icon` use. A size is present only once this
  # deployment has *measured* the image, which is the whole precondition for
  # declaring it: `sizes` is a declaration, and a manifest that mis-states it
  # does not degrade — Chromium stops offering the install prompt and says
  # nothing about why.
  #
  # ## Why the brand icon is `any` and the stock maskable disappears
  #
  # A maskable icon is **cropped** to the platform's shape, not letterboxed:
  # Android keeps roughly the inner 80% and throws the rest away. An operator's
  # icon has no safe zone — the form asks for a square image, not a padded one —
  # so declaring it `maskable` would clip their logo on every Android home
  # screen. It is therefore `any` only.
  #
  # But then the stock maskable cannot stay either, and that is the
  # counter-intuitive half. Android *prefers* a maskable icon for the home
  # screen, so leaving `/images/app-icon-maskable-512.png` in the list would
  # make a white-labelled site's home-screen icon the KilnCMS flame — the exact
  # symptom #629 is about, and worse than having no maskable at all. With none
  # declared, Android letterboxes the `any` icon into the adaptive shape: the
  # operator's mark, uncropped, on a generated background.
  defp icons(brand) do
    case Branding.verified_app_icon(brand) do
      {url, size} -> [%{src: url, sizes: "#{size}x#{size}", purpose: "any"} | stock_any_icons()]
      nil -> stock_any_icons() ++ [stock_maskable_icon()]
    end
  end

  # No `type` on the brand entry above, deliberately. It is a hint a browser
  # uses to skip formats it cannot decode, and the only thing available at
  # render time is the URL's extension — which an image CDN will happily
  # contradict by serving WebP from a `.png` path. Omitting the key is valid and
  # means "decode it to find out"; declaring it wrong can make a launcher skip
  # an icon it could have rendered. This module refuses to guess `sizes`; the
  # same argument applies to `type`.
  defp stock_any_icons do
    [
      %{src: "/images/app-icon-192.png", sizes: "192x192", type: "image/png", purpose: "any"},
      %{src: "/images/app-icon-512.png", sizes: "512x512", type: "image/png", purpose: "any"}
    ]
  end

  defp stock_maskable_icon do
    %{
      src: "/images/app-icon-maskable-512.png",
      sizes: "512x512",
      type: "image/png",
      purpose: "maskable"
    }
  end

  # Translated on the same terms as `name`/`description` — these are OS-surfaced
  # labels (long-press the home-screen icon), so they belong in the installing
  # user's language for exactly the same reason.
  defp shortcuts(brand) do
    icon = shortcut_icon(brand)

    [
      %{name: gettext("Review queue"), url: "/editor?status=in_review", icons: [icon]},
      %{name: gettext("Drafts"), url: "/editor?status=draft", icons: [icon]}
    ]
  end

  # The brand icon here too, at its measured size — a shortcut menu showing the
  # stock flame beside a branded app icon is exactly the mismatch #629 is about.
  # Same gate as `icons/1`, so the two can never disagree.
  defp shortcut_icon(brand) do
    case Branding.verified_app_icon(brand) do
      {url, size} -> %{src: url, sizes: "#{size}x#{size}"}
      nil -> %{src: "/images/app-icon-192.png", sizes: "192x192", type: "image/png"}
    end
  end
end
