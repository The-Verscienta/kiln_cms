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

  ## Why the strings here aren't `gettext`'d

  Every other admin string is translated, but a manifest is fetched once per
  install from a single URL that carries no locale, and the OS then keeps the
  chosen name on the home screen indefinitely. Translating it would mean the
  installed app is labelled in whatever locale happened to trigger the first
  fetch — worse than one consistent label. Per-locale manifests are a real
  feature, but they need a locale-scoped URL to hang off; see #630.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Branding

  # The icon tile's background (see `priv/static/images/app-icon-*.png`). Used
  # for the splash screen so the launch matches the installed icon.
  @background_color "#1c1b1a"

  # Stock ember, for a site that hasn't set a brand colour. Mirrors
  # `--color-primary` in `assets/css/app.css`.
  @default_theme_color "#ff6200"

  @doc "The per-org web app manifest (`application/manifest+json`)."
  def show(conn, _params) do
    brand = Branding.for_org(conn.assigns[:current_org])

    conn
    |> put_resp_content_type("application/manifest+json")
    |> json(manifest(brand))
  end

  defp manifest(brand) do
    %{
      # A stable identity across redeploys and brand renames — without it the
      # browser keys the installed app on `start_url`, and a later change there
      # would orphan the install.
      id: "/editor",
      name: "#{brand.site_name} Editor",
      short_name: brand.site_name,
      description: "Review, approve and publish #{brand.site_name} content.",
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
        name: "Review queue",
        url: "/editor?status=in_review",
        icons: [%{src: "/images/app-icon-192.png", sizes: "192x192", type: "image/png"}]
      },
      %{
        name: "Drafts",
        url: "/editor?status=draft",
        icons: [%{src: "/images/app-icon-192.png", sizes: "192x192", type: "image/png"}]
      }
    ]
  end
end
