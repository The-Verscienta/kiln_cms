defmodule KilnCMSWeb.LocalesController do
  @moduledoc """
  Locale discovery for headless consumers.

  `GET /api/locales` returns the configured content locales and the default, so
  a frontend can build a locale switcher / hreflang set without hard-coding the
  site's language configuration:

      {"default": "en", "locales": ["en", "fr"]}
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.I18n

  # Locales are static app config (they change only on redeploy), so let shared
  # caches/CDNs hold the response — mirrors the artifact endpoint's cache posture.
  @max_age_seconds 300

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=#{@max_age_seconds}")
    |> json(%{default: I18n.default_locale(), locales: I18n.locales()})
  end
end
