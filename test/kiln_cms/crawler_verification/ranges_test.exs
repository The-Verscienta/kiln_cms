defmodule KilnCMS.CrawlerVerification.RangesTest do
  @moduledoc """
  The published crawler range lists (#2586): the parser that reads or refuses
  a vendor's list, and the per-node store `lookup/3` answers from.

  Synthetic lists use `45.143.200.0/24` and `2a01:4f8:1::/48`: the parser
  refuses the documentation ranges, and these are clear of every vendor's
  real list and of `KilnCMS.Test.PublicAddress`.
  """
  # Not async: the lists are VM-global (`:persistent_term` and `:atomics`),
  # and `check/3` in other tests reads them.
  use ExUnit.Case, async: false

  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.CrawlerVerification.Ranges.Parser
  alias KilnCMS.Security.Cidr

  doctest KilnCMS.CrawlerVerification.Ranges.Parser

  @fixtures Path.expand("../../support/fixtures/crawler_ranges", __DIR__)

  @v4 "45.143.200.0/24"
  @v6 "2a01:4f8:1::/48"
  @inside_v4 {45, 143, 200, 7}
  @outside_v4 {45, 143, 201, 7}
  @inside_v6 {0x2A01, 0x4F8, 1, 2, 0, 0, 0, 7}
  @outside_v6 {0x2A01, 0x4F8, 2, 0, 0, 0, 0, 7}

  setup do
    Ranges.clear()
    on_exit(&Ranges.clear/0)
  end

  describe "the vendors' real lists" do
    for {file, families} <- [
          {"duckduckbot.json", [:inet]},
          {"common-crawlers.json", [:inet, :inet6]},
          {"bingbot.json", [:inet]},
          {"applebot.json", [:inet]}
        ] do
      test "#{file} parses within every limit" do
        body = File.read!(Path.join(@fixtures, unquote(file)))
        assert {:ok, cidrs} = Parser.parse(body)

        assert cidrs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
                 Enum.sort(unquote(families))

        assert length(cidrs) == length(Jason.decode!(body)["prefixes"])
      end
    end
  end

  describe "Parser.parse/2 reads" do
    test "ipv4Prefix, ipv6Prefix and prefix keys, ignoring unknown keys" do
      body =
        Jason.encode!(%{
          "creationTime" => "2026-01-01T00:00:00",
          "syncToken" => "1",
          "prefixes" => [
            %{"ipv4Prefix" => @v4, "service" => "crawler"},
            %{"ipv6Prefix" => @v6},
            %{"prefix" => "45.143.202.0/24"}
          ]
        })

      assert {:ok, cidrs} = Parser.parse(body)
      assert Enum.map(cidrs, &Cidr.format/1) == [@v4, @v6, "45.143.202.0/24"]
    end

    test "a top-level list of strings, with bare addresses as /32 and /128" do
      body = Jason.encode!(["45.143.200.7", "2a01:4f8:1::7", @v4])

      assert {:ok, cidrs} = Parser.parse(body)
      assert Enum.map(cidrs, &Cidr.format/1) == ["45.143.200.7/32", "2a01:4f8:1::7/128", @v4]
    end

    test "entries it cannot read are skipped, and duplicates kept once" do
      body =
        Jason.encode!(%{
          "prefixes" => [
            %{"ipv4Prefix" => "nonsense"},
            %{"other" => @v4},
            5,
            %{"ipv4Prefix" => @v4},
            @v4
          ]
        })

      assert {:ok, [{:inet, _net, 24}]} = Parser.parse(body)
    end
  end

  describe "Parser.parse/2 refuses the whole list" do
    test "when it is not JSON, or not a list of ranges" do
      for body <- ["not json", ~s({"prefixes": 5}), ~s("45.143.200.0/24"), ~s({"other": []})] do
        assert Parser.parse(body) == {:error, :invalid_json}, body
      end
    end

    test "when no range is left" do
      assert Parser.parse(~s({"prefixes": []})) == {:error, :no_prefixes}
      assert Parser.parse(~s({"prefixes": [{"ipv4Prefix": "x"}]})) == {:error, :no_prefixes}
    end

    test "with more entries than :max_prefixes" do
      entries = for c <- 0..9, do: "45.143.#{c}.0/24"
      body = Jason.encode!(entries)

      assert {:ok, _} = Parser.parse(body, max_prefixes: 10)
      assert Parser.parse(body, max_prefixes: 9) == {:error, :too_many}

      default = Jason.encode!(for n <- 0..5_000, do: "45.143.#{div(n, 256)}.#{rem(n, 256)}")
      assert Parser.parse(default) == {:error, :too_many}
    end

    test "with a range wider than an IPv4 /20 or an IPv6 /48" do
      assert {:ok, _} = parse_list(["45.143.192.0/20"])
      assert {:ok, _} = parse_list(["2a01:4f8:1::/48"])

      for wide <- [
            "0.0.0.0/0",
            "45.143.192.0/19",
            "45.0.0.0/8",
            "::/0",
            "2a01:4f8::/47",
            "2a01::/16"
          ] do
        assert parse_list([@v4, wide]) == {:error, :too_broad}, wide
      end
    end

    test "when its ranges together cover too many addresses" do
      sixteen = for n <- 0..15, do: "45.#{100 + n}.0.0/20"
      assert {:ok, _} = parse_list(sixteen)
      assert parse_list(["46.0.0.0/20" | sixteen]) == {:error, :too_broad}

      assert parse_list(["2a01:4f8:1::/48", "2a01:4f8:2::/48"]) == {:error, :too_broad}
    end

    test "with any range that is not global unicast space" do
      for bad <- [
            "10.0.0.0/24",
            "127.0.0.1",
            "100.64.0.0/24",
            "169.254.1.0/24",
            "172.16.0.0/24",
            "192.168.1.0/24",
            "224.0.0.0/24",
            "240.0.0.0/24",
            "0.0.0.0/24",
            "198.51.100.0/24",
            "203.0.113.7",
            "192.0.2.0/24",
            "198.18.0.0/24",
            "192.88.99.0/24",
            # wider than a special block, and overlapping it
            "192.0.0.0/20",
            "::ffff:10.0.0.0/120",
            "64:ff9b::/96",
            "64:ff9b:1::/48",
            "2002:c000:204::/48",
            "2001:0:4136:e378::/64",
            "2001:db8::/48",
            "3fff::/48",
            "fd00::/48",
            "fe80::/64",
            "ff02::/64",
            "::1",
            "::/128"
          ] do
        assert parse_list([@v4, bad]) == {:error, :not_public}, bad
      end
    end

    test "never trimmed to the ranges that pass" do
      assert parse_list([@v4, @v6, "10.0.0.0/24"]) == {:error, :not_public}
    end
  end

  describe "lookup/3" do
    test "answers :in and :out for both families" do
      Ranges.put_fixture(:google, [@v4, @v6])

      assert Ranges.lookup(:google, @inside_v4) == :in
      assert Ranges.lookup(:google, @outside_v4) == :out
      assert Ranges.lookup(:google, @inside_v6) == :in
      assert Ranges.lookup(:google, @outside_v6) == :out
    end

    test "reads an IPv4-mapped address as the IPv4 address it carries" do
      Ranges.put_fixture(:google, [@v4])

      assert Ranges.lookup(:google, {0, 0, 0, 0, 0, 0xFFFF, 45 * 256 + 143, 200 * 256 + 7}) == :in
    end

    test "matches single addresses and mixed prefix lengths" do
      Ranges.put_fixture(:duckduckgo, ["45.143.201.9/32", "45.143.202.0/27", @v4])

      assert Ranges.lookup(:duckduckgo, {45, 143, 201, 9}) == :in
      assert Ranges.lookup(:duckduckgo, {45, 143, 201, 10}) == :out
      assert Ranges.lookup(:duckduckgo, {45, 143, 202, 31}) == :in
      assert Ranges.lookup(:duckduckgo, {45, 143, 202, 32}) == :out
    end

    test "is :unknown for a family the list has no range of" do
      Ranges.put_fixture(:duckduckgo, ["45.143.201.9/32"])

      assert Ranges.lookup(:duckduckgo, @inside_v6) == :unknown
      assert Ranges.lookup(:duckduckgo, @outside_v4) == :out
    end

    test "is :unknown with no list, for another engine's list, and for a non-address" do
      assert Ranges.lookup(:duckduckgo, @inside_v4) == :unknown

      Ranges.put_fixture(:bing, [@v4])
      assert Ranges.lookup(:duckduckgo, @inside_v4) == :unknown
      assert Ranges.lookup(:yandex, @inside_v4) == :unknown
      assert Ranges.lookup(:bing, nil) == :unknown
      assert Ranges.lookup(:bing, "45.143.200.7") == :unknown
    end

    test "a stale list is :unknown, even for an address it contains" do
      Ranges.put_fixture(:duckduckgo, [@v4])
      max_age = Ranges.config()[:max_age_ms]
      now = System.monotonic_time(:millisecond)

      assert Ranges.lookup(:duckduckgo, @inside_v4, now: now + max_age - 1_000) == :in
      assert Ranges.lookup(:duckduckgo, @inside_v4, now: now + max_age + 1_000) == :unknown
      assert Ranges.lookup(:duckduckgo, @outside_v4, now: now + max_age + 1_000) == :unknown
      refute Ranges.fresh?(:duckduckgo, now: now + max_age + 1_000)

      Ranges.clear()
      Ranges.put_fixture(:duckduckgo, [@v4], age_ms: max_age + 1)
      assert Ranges.lookup(:duckduckgo, @inside_v4) == :unknown
    end

    test "a list dated in the future is not fresh" do
      now = System.monotonic_time(:millisecond)
      Ranges.put_fixture(:duckduckgo, [@v4], now: now + :timer.minutes(10))

      refute Ranges.fresh?(:duckduckgo, now: now)
      assert Ranges.lookup(:duckduckgo, @inside_v4, now: now) == :unknown
    end

    test "is :unknown with ranges turned off" do
      Ranges.put_fixture(:duckduckgo, [@v4])

      assert Ranges.lookup(:duckduckgo, @inside_v4, enabled: false) == :unknown
    end
  end

  describe "put/3" do
    test "ignores a list no newer than the one installed" do
      now = System.monotonic_time(:millisecond)
      assert Ranges.put_fixture(:duckduckgo, [@v4], now: now) == :installed

      assert Ranges.put_fixture(:duckduckgo, ["45.143.202.0/24"], now: now, age_ms: 1) == :ignored
      assert Ranges.lookup(:duckduckgo, @inside_v4) == :in

      assert Ranges.put_fixture(:duckduckgo, ["45.143.202.0/24"], now: now + 1) == :installed
      assert Ranges.lookup(:duckduckgo, @inside_v4, now: now + 1) == :out
    end

    test "an unchanged list moves its fetch time and leaves the index term alone" do
      now = System.monotonic_time(:millisecond)
      Ranges.put_fixture(:duckduckgo, [@v4, "45.143.202.0/24"], age_ms: :timer.hours(2), now: now)
      before = :persistent_term.get({Ranges, :index, :duckduckgo})

      Ranges.put_fixture(:duckduckgo, ["45.143.202.0/24", @v4], now: now)

      assert :erts_debug.same(before, :persistent_term.get({Ranges, :index, :duckduckgo}))
      assert Ranges.status().duckduckgo.age_ms < :timer.hours(1)
    end
  end

  describe "status/0 and payload/2" do
    test "report each engine with a source, and send only a fresh list" do
      Ranges.put_fixture(:duckduckgo, [@v4, @v6], age_ms: 5_000)

      status = Ranges.status()
      assert Map.keys(status) |> Enum.sort() == Enum.sort(Engines.range_engines())
      assert %{count: 2, fresh?: true, source: "https://duckduckgo.com/" <> _} = status.duckduckgo
      assert status.duckduckgo.age_ms >= 5_000
      assert %{count: 0, fresh?: false, age_ms: nil} = status.google

      assert {:crawler_ranges, 1, :duckduckgo, [@v4, @v6], age} = Ranges.payload(:duckduckgo)
      assert age >= 5_000
      assert Ranges.payload(:google) == nil

      Ranges.clear()
      Ranges.put_fixture(:duckduckgo, [@v4], age_ms: Ranges.config()[:max_age_ms] + 1)
      assert Ranges.payload(:duckduckgo) == nil
    end
  end

  describe "Engines" do
    test "every range source is HTTPS, and Yandex and Baidu have none" do
      for engine <- Engines.range_engines() do
        assert "https://" <> _ = Engines.range_source(engine)
      end

      assert Enum.sort(Engines.range_engines()) == [:apple, :bing, :duckduckgo, :google]

      assert Engines.range_source(:yandex) == nil
      assert Engines.range_source(:baidu) == nil
    end

    test "an operator override replaces one engine and keeps the others" do
      previous = Application.get_env(:kiln_cms, Ranges)

      on_exit(fn -> Application.put_env(:kiln_cms, Ranges, previous) end)

      Application.put_env(
        :kiln_cms,
        Ranges,
        Keyword.put(previous, :sources, %{
          bing: false,
          google: "https://mirror.example/g.json",
          altavista: "https://x"
        })
      )

      assert Engines.range_source(:bing) == nil
      assert Engines.range_source(:google) == "https://mirror.example/g.json"
      assert Engines.range_source(:duckduckgo) == Engines.default_range_sources().duckduckgo
      assert Engines.range_source(:apple) == Engines.default_range_sources().apple
      assert Engines.range_source(:altavista) == nil
      refute :bing in Engines.range_engines()
    end
  end

  defp parse_list(strings), do: Parser.parse(Jason.encode!(strings))
end
