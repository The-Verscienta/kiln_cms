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

    conn
    |> Map.put(:remote_ip, {10, 7, 0, suffix})
    |> assert_denies_eventually(:auth)
  end

  test "returns 429 when the preview bucket is exceeded", %{conn: conn} do
    suffix = rem(System.unique_integer([:positive]), 200) + 1

    conn
    |> Map.put(:remote_ip, {10, 1, 0, suffix})
    |> assert_denies_eventually(:preview)
  end

  test "returns 429 when the form bucket is exceeded", %{conn: conn} do
    suffix = rem(System.unique_integer([:positive]), 200) + 1

    conn
    |> Map.put(:remote_ip, {10, 3, 0, suffix})
    |> assert_denies_eventually(:form)
  end

  # #225: the always-on Swagger UI explorer has its own `docs` bucket.
  test "returns 429 when the docs (Swagger UI) bucket is exceeded", %{conn: conn} do
    suffix = rem(System.unique_integer([:positive]), 200) + 1

    conn
    |> Map.put(:remote_ip, {10, 9, 0, suffix})
    |> assert_denies_eventually(:docs)
  end

  # The generalization of the `:auth` test above, and for the same reason
  # (#697): these are FIXED windows, so "exactly `limit` allowed, then one
  # denied" has zero margin — a rollover anywhere in the run resets the counter
  # and the next request is legitimately allowed, which reads as the limiter
  # having failed. Keep going until one is denied, bounded generously enough
  # that a single rollover cannot exhaust the attempts.
  #
  # The limit is read rather than restated: `config/test.exs` raises some
  # buckets so the suite's own traffic cannot exhaust them, and a hardcoded
  # count here would silently stop testing the boundary it names.
  defp assert_denies_eventually(conn, bucket) do
    {limit, _scale} = Map.fetch!(KilnCMSWeb.RateLimit.limits(), bucket)

    denied =
      Enum.reduce_while(1..(limit * 3), nil, fn _, _acc ->
        case RateLimit.call(conn, bucket) do
          %{halted: true} = denied -> {:halt, denied}
          _allowed -> {:cont, nil}
        end
      end)

    # Named, not left to `denied.halted` raising `KeyError` on `nil`: "the
    # limiter never denied" is the security regression these tests exist to
    # catch, and it must not read as the test itself being broken.
    assert denied, "the :#{bucket} bucket allowed #{limit * 3} requests without denying one"
    assert denied.status == 429
    denied
  end
end
