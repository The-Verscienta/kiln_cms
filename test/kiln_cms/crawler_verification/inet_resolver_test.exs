defmodule KilnCMS.CrawlerVerification.InetResolverTest do
  @moduledoc """
  `KilnCMS.CrawlerVerification.InetResolver` (#2254) against a nameserver on
  a local UDP socket, so the real `:inet_res` path is exercised offline: a
  missing name and a resolver failure must come back apart, and a silent
  nameserver must not hold a call past its deadline.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CrawlerVerification.InetResolver

  setup do
    mode = :ets.new(:mode, [:public])
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    server = spawn_link(fn -> serve(socket, mode) end)
    :ok = :gen_udp.controlling_process(socket, server)

    opts = [timeout: 2_000, query_timeout_ms: 1_000, nameservers: [{{127, 0, 0, 1}, port}]]
    %{mode: mode, opts: opts}
  end

  test "a PTR answer comes back as its names", %{mode: mode, opts: opts} do
    answer(mode, {:ptr, [~c"CRAWL-1.GoogleBot.com", ~c"crawl\\.googlebot\\.com"]})

    assert InetResolver.ptr({66, 249, 66, 1}, opts) ==
             {:ok, [~c"CRAWL-1.GoogleBot.com", ~c"crawl\\.googlebot\\.com"]}

    assert_received {:asked, ~c"1.66.249.66.in-addr.arpa", :ptr}
  end

  test "an IPv6 PTR query asks the ip6.arpa name", %{mode: mode, opts: opts} do
    answer(mode, :nodata)

    assert InetResolver.ptr({0x2001, 0x4860, 0x4801, 0x2, 0, 0, 0, 0xAB}, opts) == {:ok, []}

    assert_received {:asked, name, :ptr}

    assert to_string(name) ==
             "b.a.0.0.0.0.0.0.0.0.0.0.0.0.0.0.2.0.0.0.1.0.8.4.0.6.8.4.1.0.0.2.ip6.arpa"
  end

  test "a forward query asks for the family's records only", %{mode: mode, opts: opts} do
    answer(mode, {:a, [{66, 249, 66, 1}]})
    assert InetResolver.addresses("crawl.googlebot.com", :inet, opts) == {:ok, [{66, 249, 66, 1}]}
    assert_received {:asked, ~c"crawl.googlebot.com", :a}

    answer(mode, {:aaaa, [{0x2001, 0x4860, 0x4801, 2, 0, 0, 0, 1}]})

    assert InetResolver.addresses("crawl.googlebot.com", :inet6, opts) ==
             {:ok, [{0x2001, 0x4860, 0x4801, 2, 0, 0, 0, 1}]}

    assert_received {:asked, ~c"crawl.googlebot.com", :aaaa}
  end

  test "NXDOMAIN, NODATA and SERVFAIL are told apart", %{mode: mode, opts: opts} do
    answer(mode, :nxdomain)
    assert InetResolver.ptr({66, 249, 66, 1}, opts) == {:error, :nxdomain}

    answer(mode, :nodata)
    assert InetResolver.ptr({66, 249, 66, 1}, opts) == {:ok, []}

    answer(mode, :servfail)
    assert InetResolver.ptr({66, 249, 66, 1}, opts) == {:error, :servfail}

    answer(mode, :refused)
    assert InetResolver.addresses("crawl.googlebot.com", :inet, opts) == {:error, :refused}
  end

  test "a silent nameserver times out within the call's own deadline", %{mode: mode, opts: opts} do
    answer(mode, :silent)
    # Each attempt may wait 5 s; the call has 200 ms left.
    opts = Keyword.merge(opts, timeout: 200, query_timeout_ms: 5_000)

    started = System.monotonic_time(:millisecond)
    assert InetResolver.ptr({66, 249, 66, 1}, opts) == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  # ---- a nameserver on a local socket ---------------------------------------

  defp answer(mode, reply), do: :ets.insert(mode, {:reply, reply, self()})

  defp serve(socket, mode) do
    {:ok, {address, port, packet}} = :gen_udp.recv(socket, 0)
    {:ok, query} = :inet_dns.decode(packet)
    [question] = :inet_dns.msg(query, :qdlist)
    [{:reply, reply, test}] = :ets.lookup(mode, :reply)

    send(
      test,
      {:asked, :inet_dns.dns_query(question, :domain), :inet_dns.dns_query(question, :type)}
    )

    case reply(query, question, reply) do
      nil -> :ok
      message -> :gen_udp.send(socket, address, port, :inet_dns.encode(message))
    end

    serve(socket, mode)
  end

  defp reply(_query, _question, :silent), do: nil
  defp reply(query, question, :nxdomain), do: message(query, question, 3, [])
  defp reply(query, question, :servfail), do: message(query, question, 2, [])
  defp reply(query, question, :refused), do: message(query, question, 5, [])
  defp reply(query, question, :nodata), do: message(query, question, 0, [])

  defp reply(query, question, {type, data}) do
    domain = :inet_dns.dns_query(question, :domain)

    records =
      for d <- data,
          do: :inet_dns.make_rr(domain: domain, type: type, class: :in, ttl: 60, data: d)

    message(query, question, 0, records)
  end

  defp message(query, question, rcode, answers) do
    header = :inet_dns.make_header(:inet_dns.msg(query, :header), qr: true, rcode: rcode)
    :inet_dns.make_msg(header: header, qdlist: [question], anlist: answers)
  end
end
