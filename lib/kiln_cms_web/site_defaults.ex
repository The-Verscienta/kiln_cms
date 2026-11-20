defmodule KilnCMSWeb.SiteDefaults do
  @moduledoc """
  The site-level link-preview defaults a headless client needs (#2577), as
  `GET /api/site` serves them (`KilnCMSWeb.SiteController`).

  A per-document artifact carries the document's own `social` object and never
  the site's values (`docs/decisions/0061-*`), so a consumer rendering its own
  pages fetches these once and falls back to them, the way Kiln's own `<head>`
  does (`KilnCMSWeb.Layouts.social_meta/1`):

    * `site_name`: the resolved site name, the value of Kiln's own `<title>`.
      Never `nil`: an unbranded site answers the operator's `SITE_NAME`, or
      Kiln's stock name.
    * `twitter_site`: the site's X (Twitter) handle as `@handle`, or `nil`.
      Per site only, with no operator layer (#2258).
    * `social_image_url`: the brand's default share image as an absolute
      http(s) URL on the site's own host, or `nil`.

  **An allowlist, not a serialization of `%KilnCMS.Branding{}`.** Every key is
  a value the site's public HTML already emits to anyone, so the endpoint
  discloses nothing new. A new key needs that same evidence, is additive only
  (the response is a public contract under 1.x), and adds the columns it
  reads to `KilnCMS.CMS.Changes.BustBranding`'s purge list, or a save that
  changes it leaves the CDN serving the old answer. The logo and favicon are
  left out on purpose: an unbranded site's are Kiln's own stock assets.
  """

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Branding
  alias KilnCMSWeb.Tenant

  @type t :: %{
          site_name: String.t(),
          twitter_site: String.t() | nil,
          social_image_url: String.t() | nil
        }

  @doc """
  The three keys for `brand`, resolved for `org`. The org is required: a
  relative image is made absolute on that site's own host, and there is no
  host to guess without it.
  """
  @spec project(Branding.t(), Organization.t()) :: t()
  def project(%Branding{} = brand, %Organization{} = org) do
    %{
      site_name: brand.site_name,
      twitter_site: brand.twitter_site,
      social_image_url: Tenant.absolute_url(org, brand.social_image_url)
    }
  end
end
