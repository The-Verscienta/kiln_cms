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
end
