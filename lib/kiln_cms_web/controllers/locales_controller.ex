defmodule KilnCMSWeb.LocalesController do
  @moduledoc """
  Locale discovery for headless consumers.

  `GET /api/locales` returns the configured content locales, the default, and
  this site's fallback chain for each locale (`KilnCMS.I18n.Fallback`), so a
  frontend can build a locale switcher / hreflang set — and know which
  translation a missing one is answered with — without hard-coding the site's
  language configuration:

      {"default": "en", "locales": ["en", "fr", "fr-CA"],
       "fallbacks": {"en": [], "fr": ["en"], "fr-CA": ["fr", "en"]}}

  Each chain excludes the locale itself; `[]` means that locale never falls
  back.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.I18n
  alias KilnCMS.I18n.Fallback

  # Locales change only on redeploy and the chains on a settings save, so let
  # shared caches/CDNs hold the response — mirrors the artifact endpoint's cache
  # posture. The host is part of the URL, so each site caches its own chains.
  @max_age_seconds 300

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
    |> json(%{
      default: I18n.default_locale(),
      locales: I18n.locales(),
      fallbacks: Fallback.effective(KilnCMSWeb.Tenant.current_org_id(conn))
    })
  end
end
