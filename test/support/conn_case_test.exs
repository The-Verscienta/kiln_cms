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
  """
  use ExUnit.Case, async: true

  import KilnCMSWeb.ConnCase, only: [unique_ip: 1]

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

    test "stays inside loopback, and off the network and broadcast addresses" do
      for _ <- 1..1_000 do
        assert {127, b, c, d} = fresh() |> unique_ip() |> ip()
        assert b in 1..254
        assert c in 0..249
        # `.0` is the network address and `.255` the broadcast; neither is a
        # host, and a limiter keyed on a "host" that is not one is a trap.
        assert d in 1..250
      end
    end

    test "replaces the address rather than adding a key to the struct" do
      conn = fresh() |> unique_ip()

      assert %Plug.Conn{} = conn
      assert is_tuple(conn.remote_ip)
    end
  end
end
