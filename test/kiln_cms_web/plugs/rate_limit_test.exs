defmodule KilnCMSWeb.Plugs.RateLimitTest do
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMSWeb.Plugs.RateLimit

  test "returns 429 when the auth bucket is exceeded", %{conn: conn} do
    suffix = rem(System.unique_integer([:positive]), 200) + 1
    conn = Map.put(conn, :remote_ip, {127, 0, 0, suffix})

    for _ <- 1..20 do
      refute RateLimit.call(conn, :auth).halted
    end

    denied = RateLimit.call(conn, :auth)
    assert denied.halted
    assert denied.status == 429
  end

  test "returns 429 when the preview bucket is exceeded", %{conn: conn} do
    suffix = rem(System.unique_integer([:positive]), 200) + 1
    conn = Map.put(conn, :remote_ip, {10, 1, 0, suffix})

    for _ <- 1..30 do
      refute RateLimit.call(conn, :preview).halted
    end

    denied = RateLimit.call(conn, :preview)
    assert denied.halted
    assert denied.status == 429
  end

  # #225: the always-on Swagger UI explorer has its own `docs` bucket.
  test "returns 429 when the docs (Swagger UI) bucket is exceeded", %{conn: conn} do
    suffix = rem(System.unique_integer([:positive]), 200) + 1
    conn = Map.put(conn, :remote_ip, {10, 9, 0, suffix})

    for _ <- 1..60 do
      refute RateLimit.call(conn, :docs).halted
    end

    denied = RateLimit.call(conn, :docs)
    assert denied.halted
    assert denied.status == 429
  end
end
