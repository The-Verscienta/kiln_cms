defmodule KilnCMSWeb.RateLimitClientKeyTest do
  @moduledoc """
  `RateLimit.client_key/1`: the string every address-keyed bucket counts
  under. An IPv6 client is counted as its /64, because a host can source a
  request from any address in the /64 it was handed.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.RateLimit

  test "an IPv4 address is itself" do
    assert RateLimit.client_key({203, 0, 113, 7}) == "203.0.113.7"
  end

  test "IPv6 addresses in one /64 share a key; another /64 does not" do
    one = RateLimit.client_key({0x2001, 0xDB8, 1, 2, 0xAAAA, 0xBBBB, 0xCCCC, 1})
    two = RateLimit.client_key({0x2001, 0xDB8, 1, 2, 0x1111, 0x2222, 0x3333, 0x4444})
    other = RateLimit.client_key({0x2001, 0xDB8, 1, 3, 0xAAAA, 0xBBBB, 0xCCCC, 1})

    assert one == "2001:db8:1:2::/64"
    assert one == two
    refute one == other
  end

  test "an IPv4-mapped address is the IPv4 client" do
    assert RateLimit.client_key({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}) == "203.0.113.7"
  end

  test "nil and a non-address share the unknown bucket" do
    assert RateLimit.client_key(nil) == RateLimit.client_key(:not_an_address)
  end
end
