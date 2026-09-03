defmodule KilnCMSWeb.ConnCaseTest do
  @moduledoc """
  The test-support helpers themselves, because a bug in one of these does not
  look like a bug in one of these — it looks like a flake in whatever test was
  unlucky.

  `unique_ip/1` is the case in point: three files each carried a copy that drew
  from 250 addresses, and the collision surfaced as `expected response with
  status 200, got: 429` inside an assertion about a Content-Security-Policy.
  It broke `main` twice before anyone read it as a rate-limit bucket collision
  rather than a CSP problem.

  ConnCase's `setup` now applies the same scheme by default (#936), so a test
  that forgets to call `unique_ip/1` is no longer on the shared loopback bucket.
  """
  use ExUnit.Case, async: true

  import KilnCMSWeb.ConnCase, only: [unique_ip: 1, loopback_conn: 0, build_conn: 0]

  defp ip(conn), do: conn.remote_ip

  defp fresh, do: Phoenix.ConnTest.build_conn()

  describe "unique_ip/1" do
    test "never repeats an address across a realistic run" do
      # 5,000 is more requests than the whole suite makes. The old helper
      # (`rem(unique_integer, 250)`) collides at ~20.
      addresses = for _ <- 1..5_000, do: fresh() |> unique_ip() |> ip()

      assert length(Enum.uniq(addresses)) == 5_000
    end

    test "twenty draws are distinct — the size that used to be a coin flip" do
      # 20 draws into 250 buckets is a 54% chance of a repeat, which is what
      # made this a "flake" rather than a permanent failure.
      addresses = for _ <- 1..20, do: fresh() |> unique_ip() |> ip()

      assert length(Enum.uniq(addresses)) == 20
    end

    test "stays inside the RateLimitHelpers range, clear of exhaustion tests" do
      # `10.128.0.0/9` — see `KilnCMS.RateLimitHelpers.client_address/0`. Not
      # loopback: ConnCase's default is already off loopback, and this helper
      # must agree with it rather than invent a second scheme.
      for _ <- 1..1_000 do
        assert {10, b, _c, _d} = fresh() |> unique_ip() |> ip()
        assert b in 128..255
      end
    end

    test "sets peer_data and remote_ip to the same address" do
      conn = fresh() |> unique_ip()

      assert %Plug.Conn{} = conn
      assert is_tuple(conn.remote_ip)
      assert Plug.Conn.get_peer_data(conn).address == conn.remote_ip
    end
  end

  describe "loopback_conn/0" do
    test "is the shared bucket a test has to opt into" do
      conn = loopback_conn()
      assert conn.remote_ip == {127, 0, 0, 1}
    end
  end

  describe "build_conn/0 (the ConnCase shadow, #1356)" do
    # The suite's steadiest flake seed was a SECOND conn built mid-test: the
    # setup conn peered uniquely (#936), but a bare Phoenix build_conn/0 for a
    # fresh session peered from 127.0.0.1 — the one bucket every other bare
    # conn in every other file charges. Four CI 429s in two weeks (federation
    # Undo x3, /api/schema, the related endpoint) were exactly that shape.
    test "every conn peers from its own address, never loopback" do
      first = build_conn()
      second = build_conn()

      assert first.remote_ip != {127, 0, 0, 1}
      assert second.remote_ip != {127, 0, 0, 1}
      assert first.remote_ip != second.remote_ip
      assert Plug.Conn.get_peer_data(second).address == second.remote_ip
    end
  end
end
