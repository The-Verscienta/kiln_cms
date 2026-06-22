defmodule KilnCMSWeb.HealthControllerTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  test "GET /up returns 200 OK when the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/up")
    assert response(conn, 200) == "OK"
  end
end
