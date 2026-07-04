defmodule KilnCMSWeb.LocalesControllerTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  test "GET /api/locales returns the configured locales and default", %{conn: conn} do
    conn = get(conn, ~p"/api/locales")
    body = json_response(conn, 200)

    assert body["default"] == KilnCMS.I18n.default_locale()
    assert is_list(body["locales"])
    # The default is always one of the offered locales.
    assert body["default"] in body["locales"]
  end

  test "GET /api/locales is cacheable by shared caches", %{conn: conn} do
    conn = get(conn, ~p"/api/locales")
    assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
  end
end
