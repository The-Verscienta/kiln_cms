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
end
