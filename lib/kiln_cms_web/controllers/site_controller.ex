defmodule KilnCMSWeb.SiteController do
  @moduledoc """
  `GET /api/site`: the site-level link-preview defaults a headless client
  falls back to when a document carries none of its own (#2577).

      {"site_name": "Acme Docs", "twitter_site": "@acme",
       "social_image_url": "https://acme.example/uploads/card.png"}

  Every key is always present; `twitter_site` and `social_image_url` are
  `null` when the site has none. What each key means, and why there are only
  these three, is `KilnCMSWeb.SiteDefaults`.

  **Why a plain endpoint.** Not a JSON:API or GraphQL resource over
  `KilnCMS.CMS.SiteBranding`: the row holds settings that are not public (the
  custom CSS, the menu keys, the app icon's verification state), carries no
  operator layer, and stores relative URLs, while the values a page shows are
  the resolved ones (`KilnCMS.Branding`). Not part of the per-document
  artifact either: site values stay out of it (`docs/decisions/0061-*`), so a
  branding save does not re-fire every document.

  **Whose site.** The org is the one `KilnCMSWeb.Plugs.SetTenant` resolved from
  the request's host, through `KilnCMSWeb.Tenant.current_org/1`, which raises
  rather than default. A host that matches no site is refused before the router
  under strict host matching, so it never answers another site's values.

  **Caching.** Anonymous reads are shared-cacheable through
  `KilnCMSWeb.Plugs.PublicCache` (60 s, ETag, purged on a branding save by
  `KilnCMS.CMS.Changes.BustBranding`). Since a cache keeps the answer, a
  branding row that cannot be read is a `503` with `Retry-After`, never the
  stock defaults (`KilnCMS.Branding.fetch_for_org/1`): a CDN would otherwise
  show a branded site's previews under Kiln's name for a minute.

  A branding save purges, and so does a change to a site's domain or slug,
  which moves an absolutized `social_image_url`
  (`KilnCMS.Accounts.Changes.BustSiteUrls`, #3194). A change that alters the
  answer without either — the operator's `SITE_NAME` or `:branding` config on
  a deploy — shows once the cached copy expires: at most `max-age` plus
  `stale-while-revalidate`, about two minutes.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Branding
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.SiteDefaults
  alias KilnCMSWeb.Tenant

  @retry_after_seconds 2

  def show(conn, _params) do
    org = Tenant.current_org(conn)

    case Branding.fetch_for_org(org) do
      {:ok, brand} ->
        json(conn, SiteDefaults.project(brand, org))

      :error ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
        |> ApiError.send(
          :service_unavailable,
          "temporarily_unavailable",
          "Site settings are temporarily unavailable; retry shortly."
        )
    end
  end
end
