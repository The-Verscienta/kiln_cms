defmodule KilnCMSWeb.HealthControllerTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  test "GET /live returns 200 OK — the liveness probe (endpoint plug)", %{conn: conn} do
    conn = get(conn, "/live")
    assert response(conn, 200) == "OK"

    # Placement guard (#816): the plug must sit BEFORE SetTenant, which is what
    # keeps /live off the DB. SetTenant assigns :current_org on every request it
    # runs for, so its ABSENCE proves /live short-circuited ahead of it. Moving
    # the plug after SetTenant would still return 200 here (test DB is up) — this
    # is what catches that regression.
    refute Map.has_key?(conn.assigns, :current_org)
  end

  # The point of /live (#816): it is a bare endpoint plug that answers before
  # SetTenant, so it touches neither the DB nor tenant resolution. `call/2` does
  # nothing but send a response and halt — no DB access is even reachable, which
  # is exactly why a restart-triggering healthcheck can point at it safely.
  describe "the Liveness endpoint plug" do
    test "answers GET /live and halts, doing nothing but respond" do
      conn = KilnCMSWeb.Plugs.Liveness.call(Plug.Test.conn(:get, "/live"), [])

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == "OK"
    end

    test "passes every other request through untouched" do
      for path <- ["/up", "/ready", "/", "/blog/post"] do
        conn = KilnCMSWeb.Plugs.Liveness.call(Plug.Test.conn(:get, path), [])
        refute conn.halted, path
        assert conn.status == nil, path
      end
    end

    # Only GET — a POST to /live is not a healthcheck and falls through.
    test "does not short-circuit a non-GET /live" do
      conn = KilnCMSWeb.Plugs.Liveness.call(Plug.Test.conn(:post, "/live"), [])
      refute conn.halted
    end
  end

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
