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

    test "a cross-origin write (PATCH) preflight is allowed (#330/#355)", %{conn: conn} do
      # The visual-editing bridge round-trips edits with `PATCH /api/json/...`;
      # the preflight must advertise PATCH in allow-methods or the browser blocks
      # the write.
      conn =
        conn
        |> put_req_header("origin", @allowed)
        |> put_req_header("access-control-request-method", "PATCH")
        |> options(~p"/api/json/posts/00000000-0000-0000-0000-000000000000")

      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert conn.status in 200..204

      allow_methods =
        conn
        |> get_resp_header("access-control-allow-methods")
        |> Enum.join(",")

      assert allow_methods =~ "PATCH"
      assert allow_methods =~ "DELETE"
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
