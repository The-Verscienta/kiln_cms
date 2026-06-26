defmodule KilnCMSWeb.HealthControllerTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  test "GET /up returns 200 OK when the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/up")
    assert response(conn, 200) == "OK"
  end

  test "GET /ready reports db ok and an oban queue-depth payload", %{conn: conn} do
    conn = get(conn, ~p"/ready")
    body = json_response(conn, 200)

    assert body["status"] == "ok"
    assert body["db"] == "ok"
    assert is_integer(body["oban"]["available"])
    assert is_integer(body["oban"]["retryable"])
    assert body["oban"]["backlog"] == body["oban"]["available"] + body["oban"]["retryable"]
  end
end
