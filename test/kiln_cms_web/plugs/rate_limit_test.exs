defmodule KilnCMSWeb.Plugs.RateLimitTest do
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMSWeb.Plugs.RateLimit

  test "the production auth limit is the one the threat model states" do
    # `config/test.exs` overrides `:auth` so the suite's own `/sign-in` and
    # `/api/auth/*` traffic cannot exhaust it (#715). That override used to be
    # absent, which is what pinned the production number — every other test now
    # reads the configured value, so without this nothing would notice
    # `@default_limits` being loosened.
    assert %{auth: {20, 60_000}} = Map.take(KilnCMSWeb.RateLimit.default_limits(), [:auth])
  end

  test "returns 429 when the auth bucket is exceeded", %{conn: conn} do
    # Deliberately NOT under 127.0.0.x: `rem(n, 200) + 1` can be 1, and
    # `auth:127.0.0.1` is the bucket every `ConnTest` request in the suite keys
    # on. Exhausting it here would 429 unrelated tests for the rest of the
    # window — and, worse, would let this test pass on iteration 1 having
    # asserted nothing.
    suffix = rem(System.unique_integer([:positive]), 200) + 1
    conn = Map.put(conn, :remote_ip, {10, 7, 0, suffix})

    # Read the limit rather than restating it: `config/test.exs` raises this one
    # so the suite's own `/sign-in` and `/api/auth/*` traffic cannot exhaust it
    # (#715), and a hardcoded 20 here would silently stop testing the boundary.
    {limit, _scale} = Map.fetch!(KilnCMSWeb.RateLimit.limits(), :auth)

    # Not "exactly `limit` allowed, then one denied": these are fixed windows, so
    # a rollover part-way through a long loop resets the counter and the next
    # request is legitimately allowed. Keep going until one is denied, bounded
    # generously enough that a single rollover cannot exhaust the attempts.
    denied =
      Enum.reduce_while(1..(limit * 3), nil, fn _, _acc ->
        case RateLimit.call(conn, :auth) do
          %{halted: true} = denied -> {:halt, denied}
          _allowed -> {:cont, nil}
        end
      end)

    # Named rather than left to `denied.halted` raising `KeyError` on `nil`:
    # "the limiter never denied" is the security regression this test exists to
    # catch, and it must not read as the test itself being broken.
    assert denied, "the :auth bucket allowed #{limit * 3} requests without denying one"
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

  test "returns 429 when the form bucket is exceeded", %{conn: conn} do
    suffix = rem(System.unique_integer([:positive]), 200) + 1
    conn = Map.put(conn, :remote_ip, {10, 3, 0, suffix})

    for _ <- 1..20 do
      refute RateLimit.call(conn, :form).halted
    end

    denied = RateLimit.call(conn, :form)
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
