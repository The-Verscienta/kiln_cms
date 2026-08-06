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

  ## Localized per fetched URL, not per request locale (#630)

  A manifest is fetched once per install and the OS keeps the chosen name on the
  home screen indefinitely, so translating against the request's Gettext locale
  would label the installed app in whatever locale happened to trigger the first
  fetch. Instead the locale is an explicit query param the linking page embeds
  (`root.html.heex` links `?locale=<request locale>`): `?locale=fr` is a
  distinct, cacheable URL from `?locale=en`, and each carries a distinct manifest
  `id`, so a `fr` install and an `en` install are separate apps — switching the
  console language does not rename an already-installed one; a reinstall from the
  new language does. The default locale keeps the historical `/editor` id, so
  existing installs survive this change.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Branding

  # The icon tile's background (see `priv/static/images/app-icon-*.png`). Used
  # for the splash screen so the launch matches the installed icon.
  @background_color "#1c1b1a"

  # Stock ember, for a site that hasn't set a brand colour. Mirrors
  # `--color-primary` in `assets/css/app.css`.
  @default_theme_color "#ff6200"

  @doc "The per-org, per-locale web app manifest (`application/manifest+json`)."
  def show(conn, params) do
    # The locale rides in as a query param (`?locale=fr`) that the linking page
    # embeds, NOT off the request path — the manifest URL carries no locale
    # segment (#630). Unsupported or absent falls back to the default. Set the
    # process locale so every `gettext/1` below resolves against it, overriding
    # whatever `Plugs.SetLocale` derived from this (locale-less) request path.
    locale = KilnCMS.I18n.normalize(params["locale"])
    Gettext.put_locale(KilnCMSWeb.Gettext, locale)

    brand = Branding.for_org(conn.assigns[:current_org])

    conn
    |> put_resp_content_type("application/manifest+json")
    |> json(manifest(brand, locale))
  end

  defp manifest(brand, locale) do
    %{
      # A stable identity across redeploys and brand renames — without it the
      # browser keys the installed app on `start_url`, and a later change there
      # would orphan the install. Per-locale (#630) so an install made in one UI
      # language keeps its localized home-screen name when the operator later
      # switches the console language — a `fr` install and an `en` install are
      # distinct apps. The default locale keeps the historical `/editor` id so
      # existing installs are not orphaned by this change.
      id: manifest_id(locale),
      name: gettext("%{site} Editor", site: brand.site_name),
      short_name: brand.site_name,
      description: gettext("Review, approve and publish %{site} content.", site: brand.site_name),
      start_url: "/editor?status=in_review",
      scope: "/",
      display: "standalone",
      theme_color: brand.brand_color || @default_theme_color,
      background_color: @background_color,
      categories: ["productivity", "business"],
      icons: icons(),
      shortcuts: shortcuts()
    }
  end

  defp manifest_id(locale) do
    if locale == KilnCMS.I18n.default_locale(), do: "/editor", else: "/editor?lang=#{locale}"
  end

  # `any` and `maskable` are separate images, not one image with both purposes:
  # a maskable icon is drawn with a 40% safe zone, so reusing it as `any` would
  # render a small mark floating in a large tile everywhere the mask isn't
  # applied.
  defp icons do
    [
      %{src: "/images/app-icon-192.png", sizes: "192x192", type: "image/png", purpose: "any"},
      %{src: "/images/app-icon-512.png", sizes: "512x512", type: "image/png", purpose: "any"},
      %{
        src: "/images/app-icon-maskable-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable"
      }
    ]
  end

  defp shortcuts do
    [
      %{
        name: gettext("Review queue"),
        url: "/editor?status=in_review",
        icons: [%{src: "/images/app-icon-192.png", sizes: "192x192", type: "image/png"}]
      },
      %{
        name: gettext("Drafts"),
        url: "/editor?status=draft",
        icons: [%{src: "/images/app-icon-192.png", sizes: "192x192", type: "image/png"}]
      }
    ]
  end
end
