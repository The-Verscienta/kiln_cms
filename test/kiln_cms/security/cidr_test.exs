defmodule KilnCMS.Security.CidrTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Security.Cidr

  doctest KilnCMS.Security.Cidr

  describe "normalise/1" do
    test "a bare address is a single-host rule" do
      assert Cidr.normalise("203.0.113.7") == {:ok, "203.0.113.7/32"}
      assert Cidr.normalise("2001:db8::1") == {:ok, "2001:db8::1/128"}
    end

    test "host bits are masked off" do
      assert Cidr.normalise("10.1.2.3/8") == {:ok, "10.0.0.0/8"}
      assert Cidr.normalise("2001:db8:1:2::9/32") == {:ok, "2001:db8::/32"}
    end

    test "IPv6 is lowercased and compressed" do
      assert Cidr.normalise("2001:0DB8:0000:0000:0000:0000:0000:0001/128") ==
               {:ok, "2001:db8::1/128"}
    end

    test "IPv4-mapped IPv6 folds to the IPv4 it carries" do
      assert Cidr.normalise("::FFFF:10.0.0.1") == {:ok, "10.0.0.1/32"}
      assert Cidr.normalise("::ffff:a00:1") == {:ok, "10.0.0.1/32"}
      assert Cidr.normalise("::ffff:10.0.0.0/104") == {:ok, "10.0.0.0/8"}
    end

    test "surrounding whitespace is trimmed" do
      assert Cidr.normalise("  198.51.100.0/24 ") == {:ok, "198.51.100.0/24"}
    end

    test "garbage is refused" do
      for bad <- [
            "",
            "nope",
            "1.2.3",
            "1.2.3.4/33",
            "::1/129",
            "1.2.3.4/-1",
            "1.2.3.4/",
            "1.2.3.4/8/8",
            "1.2.3.4/ 8",
            "256.0.0.1",
            "010.0.0.1",
            "1.2.3.04",
            "fe80::1%eth0",
            "1.2.3.4 5.6.7.8",
            nil,
            42
          ] do
        assert Cidr.normalise(bad) == {:error, :invalid}, "expected #{inspect(bad)} refused"
      end
    end

    test "hex groups with leading zeros are ordinary IPv6" do
      assert Cidr.normalise("2001:0db8::0001") == {:ok, "2001:db8::1/128"}
    end
  end

  describe "contains?/2" do
    test "IPv4 ranges" do
      assert Cidr.contains?("203.0.113.0/24", {203, 0, 113, 200})
      refute Cidr.contains?("203.0.113.0/24", {203, 0, 114, 1})
      assert Cidr.contains?("203.0.113.7/32", {203, 0, 113, 7})
      refute Cidr.contains?("203.0.113.7/32", {203, 0, 113, 8})
    end

    test "IPv6 ranges" do
      assert Cidr.contains?("2001:db8::/32", {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6})
      refute Cidr.contains?("2001:db8::/32", {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
    end

    test "families never match across each other" do
      refute Cidr.contains?("10.0.0.0/8", {0, 0, 0, 0, 0, 0, 0xA00, 1})
      refute Cidr.contains?("2001:db8::/32", {32, 1, 13, 184})
    end

    test "an IPv4-mapped IPv6 client matches an IPv4 rule" do
      assert Cidr.contains?("10.0.0.0/8", {0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203})
      refute Cidr.contains?("11.0.0.0/8", {0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203})
      assert Cidr.contains?("10.1.2.3", "::ffff:10.1.2.3")
    end

    test "a mapped-form rule is the IPv4 rule" do
      assert Cidr.contains?("::ffff:10.0.0.0/104", {10, 9, 9, 9})
    end

    test "takes strings or tuples, parsed or not" do
      {:ok, parsed} = Cidr.parse("192.0.2.0/24")
      assert Cidr.contains?(parsed, "192.0.2.9")
      assert Cidr.contains?(parsed, {192, 0, 2, 9})
    end

    test "garbage matches nothing" do
      refute Cidr.contains?("not a cidr", {1, 2, 3, 4})
      refute Cidr.contains?("1.2.3.0/24", "garbage")
      refute Cidr.contains?("1.2.3.0/24", nil)
      refute Cidr.contains?("1.2.3.0/24", {1, 2, 3})
    end
  end

  describe "loopback?/1" do
    test "v4, v6 and mapped" do
      assert Cidr.loopback?({127, 0, 0, 1})
      assert Cidr.loopback?({127, 200, 1, 1})
      assert Cidr.loopback?({0, 0, 0, 0, 0, 0, 0, 1})
      assert Cidr.loopback?("::ffff:127.0.0.1")
      refute Cidr.loopback?({128, 0, 0, 1})
      refute Cidr.loopback?("2001:db8::1")
      refute Cidr.loopback?(nil)
    end
  end

  describe "blockable/1" do
    test "returns the normalised rule" do
      assert Cidr.blockable("203.0.113.9/24") == {:ok, "203.0.113.0/24"}
      assert Cidr.blockable("8.0.0.0/8") == {:ok, "8.0.0.0/8"}
      assert Cidr.blockable("2001::/16") == {:ok, "2001::/16"}
    end

    test "refuses loopback in any spelling or width" do
      for bad <- [
            "127.0.0.1",
            "127.0.0.0/8",
            "127.1.0.0/16",
            "::1",
            "::1/128",
            "::ffff:127.0.0.1",
            "::ffff:7f00:1",
            "::ffff:127.0.0.0/104",
            "::/16",
            "::ffff:0:0/95"
          ] do
        assert {:error, reason} = Cidr.blockable(bad)
        assert reason in [:loopback, :too_broad], "#{bad} -> #{inspect(reason)}"
      end

      assert Cidr.blockable("127.0.0.1") == {:error, :loopback}
      assert Cidr.blockable("::1") == {:error, :loopback}
      assert Cidr.blockable("::ffff:127.0.0.1") == {:error, :loopback}
    end

    test "refuses ranges below the prefix floor" do
      for bad <- ["0.0.0.0/0", "::/0", "10.0.0.0/7", "128.0.0.0/1", "2001::/15", "::ffff:0:0/96"] do
        assert {:error, :too_broad} = Cidr.blockable(bad), "expected #{bad} too broad"
      end
    end

    test "garbage is :invalid" do
      assert Cidr.blockable("x") == {:error, :invalid}
    end
  end

  describe "allowable/1 (#2248)" do
    test "normalises an entry: /32 for a host, masked, compressed, mapped folded to IPv4" do
      assert Cidr.allowable("203.0.113.7") == {:ok, "203.0.113.7/32"}
      assert Cidr.allowable("198.51.100.77/24") == {:ok, "198.51.100.0/24"}
      assert Cidr.allowable("2001:DB8:0:0::1/64") == {:ok, "2001:db8::/64"}
      assert Cidr.allowable("::ffff:203.0.113.0/120") == {:ok, "203.0.113.0/24"}
    end

    test "refuses wider than the floor, loopback, and anything that is not an address" do
      assert Cidr.allowable("0.0.0.0/7") == {:error, :too_broad}
      assert Cidr.allowable("::/15") == {:error, :too_broad}
      assert Cidr.allowable("127.0.0.1") == {:error, :loopback}
      assert Cidr.allowable("::1") == {:error, :loopback}
      assert Cidr.allowable("010.0.0.1") == {:error, :invalid}
      assert Cidr.allowable("fe80::1%en0") == {:error, :invalid}
      assert Cidr.allowable("office") == {:error, :invalid}
    end
  end

  describe "any_contains?/2 (#2248)" do
    test "the first and last address of a /24 match, their neighbours do not" do
      cidrs = ["198.51.100.0/24"]

      assert Cidr.any_contains?(cidrs, {198, 51, 100, 0})
      assert Cidr.any_contains?(cidrs, {198, 51, 100, 255})
      refute Cidr.any_contains?(cidrs, {198, 51, 99, 255})
      refute Cidr.any_contains?(cidrs, {198, 51, 101, 0})
    end

    test "a /32 is exactly one address" do
      assert Cidr.any_contains?(["203.0.113.7/32"], {203, 0, 113, 7})
      refute Cidr.any_contains?(["203.0.113.7/32"], {203, 0, 113, 8})
    end

    test "an IPv6 /64 holds its first and last address and nothing past them" do
      cidrs = ["2001:db8:1:2::/64"]

      assert Cidr.any_contains?(cidrs, {0x2001, 0xDB8, 1, 2, 0, 0, 0, 0})
      assert Cidr.any_contains?(cidrs, {0x2001, 0xDB8, 1, 2, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
      refute Cidr.any_contains?(cidrs, {0x2001, 0xDB8, 1, 3, 0, 0, 0, 0})
    end

    test "an IPv4-mapped client matches the IPv4 entry it carries" do
      assert Cidr.any_contains?(["203.0.113.0/24"], {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7105})
    end

    test "families do not cross" do
      refute Cidr.any_contains?(["2001:db8::/32"], {203, 0, 113, 5})
      refute Cidr.any_contains?(["203.0.113.0/24"], {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end

    test "nothing is in an empty list, and an unknown address is in no list" do
      refute Cidr.any_contains?([], {203, 0, 113, 5})
      refute Cidr.any_contains?(["0.0.0.0/8", "203.0.113.0/24"], nil)
    end
  end

  describe "client_range/1 (#2248)" do
    test "an IPv4 address is itself, a mapped one is folded, an IPv6 one is its /64" do
      assert Cidr.client_range({203, 0, 113, 7}) == "203.0.113.7/32"
      assert Cidr.client_range({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}) == "203.0.113.7/32"

      assert Cidr.client_range({0x2001, 0xDB8, 1, 2, 0xA, 0xB, 0xC, 0xD}) ==
               "2001:db8:1:2::/64"
    end

    test "the range it gives is one a save accepts" do
      for ip <- [{203, 0, 113, 7}, {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}] do
        range = Cidr.client_range(ip)
        assert Cidr.allowable(range) == {:ok, range}
        assert Cidr.any_contains?([range], ip)
      end
    end
  end

  describe "shared_space?/1 (#2248)" do
    test "private, carrier-grade NAT, unique local and link-local space" do
      for ip <- [
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 168, 1, 1},
            {100, 64, 0, 1},
            {169, 254, 1, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert Cidr.shared_space?(ip), inspect(ip)
      end
    end

    test "public addresses are not" do
      for ip <- [
            {203, 0, 113, 7},
            {172, 32, 0, 1},
            {100, 128, 0, 1},
            {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
          ] do
        refute Cidr.shared_space?(ip), inspect(ip)
      end
    end
  end

  describe "public_unicast?/1 (#2254)" do
    test "public addresses, documentation ranges and mapped public IPv4 are" do
      for ip <- [
            {66, 249, 66, 1},
            {203, 0, 113, 7},
            {172, 32, 0, 1},
            {223, 255, 255, 255},
            {0x2001, 0x4860, 0x4801, 1, 0, 0, 0, 1},
            {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x42F9, 0x4201}
          ] do
        assert Cidr.public_unicast?(ip), inspect(ip)
      end
    end

    test "loopback, shared, unspecified, multicast and reserved space are not" do
      for ip <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {192, 168, 1, 1},
            {100, 64, 0, 1},
            {169, 254, 1, 1},
            {0, 0, 0, 0},
            {0, 1, 2, 3},
            {224, 0, 0, 1},
            {239, 255, 255, 250},
            {240, 0, 0, 1},
            {255, 255, 255, 255},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}
          ] do
        refute Cidr.public_unicast?(ip), inspect(ip)
      end
    end

    test "anything that is not an address tuple is not" do
      for junk <- [nil, "66.249.66.1", {1, 2, 3}, :inet] do
        refute Cidr.public_unicast?(junk), inspect(junk)
      end
    end
  end

  describe "truncate/1 (#2245)" do
    test "IPv4 to its /24, IPv6 to its /48" do
      assert Cidr.truncate("203.0.113.77") == "203.0.113.0/24"
      assert Cidr.truncate({198, 51, 100, 9}) == "198.51.100.0/24"
      assert Cidr.truncate("2001:db8:abcd:12::1") == "2001:db8:abcd::/48"
      assert Cidr.truncate({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) == "2001:db8:1::/48"
    end

    test "an IPv4-mapped address is truncated as the IPv4 it carries" do
      assert Cidr.truncate("::ffff:203.0.113.77") == "203.0.113.0/24"
      assert Cidr.truncate({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x714D}) == "203.0.113.0/24"
    end

    test "anything that is not an address is nil" do
      assert Cidr.truncate(nil) == nil
      assert Cidr.truncate("") == nil
      assert Cidr.truncate("203.0.113.0/24") == nil
      assert Cidr.truncate("010.0.0.1") == nil
      assert Cidr.truncate({300, 0, 0, 1}) == nil
      assert Cidr.truncate({1, 2}) == nil
      assert Cidr.truncate(42) == nil
    end
  end
end
