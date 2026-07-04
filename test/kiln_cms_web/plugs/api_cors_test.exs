defmodule KilnCMSWeb.Plugs.ApiCORSTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  # config/test.exs pins the allowlist to this single origin.
  @allowed "https://frontend.test"
  @denied "https://evil.test"

  describe "preflight (OPTIONS)" do
    test "an allowed origin gets the CORS headers and is halted before routing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @allowed)
        |> put_req_header("access-control-request-method", "GET")
        |> options(~p"/api/locales")

      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      # Corsica answers the preflight itself (2xx), rather than the 404 an
      # OPTIONS to a get-only route would otherwise produce.
      assert conn.status in 200..204
    end

    test "a disallowed origin gets no allow-origin header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @denied)
        |> put_req_header("access-control-request-method", "GET")
        |> options(~p"/api/locales")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "actual cross-origin request" do
    test "an allowed origin gets the allow-origin header on a real GET", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @allowed)
        |> get(~p"/api/locales")

      assert json_response(conn, 200)
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
    end

    test "a disallowed origin still gets the body but no CORS header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", @denied)
        |> get(~p"/api/locales")

      assert json_response(conn, 200)
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  test "non-API paths are not CORS-enabled", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", @allowed)
      |> get(~p"/up")

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
