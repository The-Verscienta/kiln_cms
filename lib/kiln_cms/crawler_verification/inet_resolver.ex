defmodule KilnCMS.CrawlerVerification.InetResolver do
  @moduledoc """
  `KilnCMS.CrawlerVerification.Resolver` over OTP's `:inet_res`, asking the
  nameservers the node is configured with (`/etc/resolv.conf`).

  `:inet_res.lookup/5` answers `[]` for a timeout, a SERVFAIL and a
  non-existent name alike, so this uses `:inet_res.resolve/5`, which keeps
  them apart: NXDOMAIN is `{:error, :nxdomain}`, an answer with no record of
  the type is `{:ok, []}`, and every other failure is `{:error, reason}`.

  Two timeouts bound a call:

    * `:query_timeout_ms` is what `:inet_res` calls `timeout`: the wait for
      one nameserver's reply to one attempt. With `retry: 1` and N
      nameservers a call could otherwise take up to N times that.
    * `:timeout` (the time left before the lookup's deadline) is the
      call's overall bound, passed as `resolve/5`'s own timeout, so the call
      returns `{:error, :timeout}` on its own when the deadline passes.

  The reverse names (`in-addr.arpa`, `ip6.arpa`) are built here rather than
  by `:inet_res.gethostbyaddr/2`, whose answer cannot tell those failures
  apart either.
  """
  @behaviour KilnCMS.CrawlerVerification.Resolver

  import Bitwise

  @impl true
  def ptr(ip, opts) do
    with {:ok, rrs} <- resolve(reverse_name(ip), :ptr, opts) do
      {:ok, for({:ptr, name} <- rrs, do: name)}
    end
  end

  @impl true
  def addresses(host, family, opts) when family in [:inet, :inet6] do
    type = if family == :inet, do: :a, else: :aaaa

    with {:ok, rrs} <- resolve(String.to_charlist(host), type, opts) do
      {:ok, for({^type, address} <- rrs, do: address)}
    end
  end

  @doc false
  # Public for the tests that check the names against `:inet_res`'s own.
  @spec reverse_name(:inet.ip_address()) :: charlist()
  def reverse_name({a, b, c, d}), do: ~c"#{d}.#{c}.#{b}.#{a}.in-addr.arpa"

  def reverse_name(ip) when tuple_size(ip) == 8 do
    nibbles =
      ip
      |> Tuple.to_list()
      |> Enum.flat_map(fn word -> for shift <- [12, 8, 4, 0], do: word >>> shift &&& 0xF end)
      |> Enum.reverse()
      |> Enum.map_join(".", &Integer.to_string(&1, 16))
      |> String.downcase()

    String.to_charlist(nibbles <> ".ip6.arpa")
  end

  # `{:ok, [{type, data}]}` for the answer section, or a failure with the
  # resolver's reason. `{:nxdomain, msg}` and the like carry the reply; only
  # the reason is kept.
  defp resolve(name, type, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    query_timeout = Keyword.get(opts, :query_timeout_ms, 1_000)
    res_opts = [timeout: max(min(query_timeout, timeout), 1), retry: 1] ++ extra_opts(opts)

    case :inet_res.resolve(name, :in, type, res_opts, max(timeout, 1)) do
      {:ok, msg} ->
        {:ok, for(rr <- :inet_dns.msg(msg, :anlist), do: {rr_type(rr), :inet_dns.rr(rr, :data)})}

      {:error, {reason, _msg}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rr_type(rr), do: :inet_dns.rr(rr, :type)

  # Test seam: point the resolver at a local nameserver.
  defp extra_opts(opts) do
    case Keyword.fetch(opts, :nameservers) do
      {:ok, nameservers} -> [nameservers: nameservers]
      :error -> []
    end
  end
end
