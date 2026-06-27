defmodule KilnCMS.Webhooks.SafeUrl do
  @moduledoc """
  Validates outbound webhook target URLs to reduce SSRF risk.

  Rejects private/link-local/metadata addresses, loopback hostnames, and
  (in production) non-HTTPS schemes. Optionally resolves hostnames and
  rejects any answer that maps to a blocked address.
  """

  @blocked_hostnames ~w(
    localhost
    metadata.google.internal
    metadata.goog
  )

  @doc """
  Returns `:ok` when `url` is an acceptable webhook target, or
  `{:error, message}` with a human-readable reason.
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) do
    url = String.trim(url)

    with %URI{} = uri <- parse_uri(url),
         :ok <- validate_scheme(uri.scheme),
         host when is_binary(host) and host != "" <- uri.host,
         :ok <- validate_host(host),
         :ok <- validate_resolved(host) do
      :ok
    else
      nil -> {:error, "must be a valid URL with a host"}
      "" -> {:error, "must be a valid URL with a host"}
      {:error, message} -> {:error, message}
    end
  end

  def validate(_), do: {:error, "must be a valid URL with a host"}

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) -> uri
      _ -> nil
    end
  end

  defp validate_scheme(scheme) do
    cond do
      scheme in allowed_schemes() -> :ok
      require_https?() -> {:error, "must use HTTPS"}
      true -> {:error, "must use HTTP or HTTPS"}
    end
  end

  defp validate_host(host) do
    host = String.downcase(host)
    base = host_only(host)

    cond do
      base in @blocked_hostnames ->
        {:error, "must not target loopback or internal hostnames"}

      String.ends_with?(base, ".local") ->
        {:error, "must not target .local hostnames"}

      String.ends_with?(base, ".internal") ->
        {:error, "must not target .internal hostnames"}

      ip_literal?(base) ->
        if blocked_ip?(base),
          do: {:error, "must not target private or link-local addresses"},
          else: :ok

      true ->
        :ok
    end
  end

  defp validate_resolved(host) do
    if resolve_dns?(), do: validate_resolved_dns(host), else: :ok
  end

  defp validate_resolved_dns(host) do
    host
    |> String.downcase()
    |> host_only()
    |> resolve_addresses()
    |> check_resolved_addresses()
  end

  defp host_only(host) do
    cond do
      String.starts_with?(host, "[") ->
        host |> String.trim_leading("[") |> String.split("]") |> hd()

      String.contains?(host, ":") and length(String.split(host, ":")) > 2 ->
        host

      true ->
        host |> String.split(":") |> hd()
    end
  end

  defp check_resolved_addresses({:ok, addresses}) do
    if Enum.any?(addresses, &blocked_ip?/1),
      do: {:error, "must not resolve to a private or link-local address"},
      else: :ok
  end

  defp check_resolved_addresses({:error, :timeout}),
    do: {:error, "hostname resolution timed out"}

  defp check_resolved_addresses({:error, _}), do: {:error, "hostname could not be resolved"}

  # Resolve in a supervised task with a hard timeout (#223): `:inet.gethostbyname`
  # blocks for the resolver's full timeout, so a slow/firewalled/NXDOMAIN target
  # would otherwise tie up the DeliveryWorker (Oban) for seconds per attempt.
  defp resolve_addresses(host) do
    charlist = String.to_charlist(host)
    task = Task.async(fn -> :inet.gethostbyname(charlist) end)

    case Task.yield(task, dns_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {:hostent, _name, _aliases, _addrtype, _length, addresses}}} ->
        {:ok, Enum.map(addresses, &normalize_address/1)}

      {:ok, {:error, reason}} ->
        {:error, reason}

      # Task.yield timed out (and shutdown returned nil) — treat as a resolution
      # timeout so the webhook fails validation fast instead of blocking.
      _ ->
        {:error, :timeout}
    end
  end

  defp normalize_address({_, _, _, _} = tuple), do: tuple
  defp normalize_address({a, b, c, d, e, f, g, h}), do: {a, b, c, d, e, f, g, h}

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp blocked_ip?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> blocked_address?(address)
      _ -> false
    end
  end

  defp blocked_ip?(address), do: blocked_address?(address)

  # IPv4
  defp blocked_address?({a, b, _, _}), do: ipv4_blocked?(a, b)

  # IPv6 loopback (::1) and unspecified (::) — match before the generic mapped clauses
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # IPv4-mapped ::ffff:a.b.c.d → re-check under the IPv4 rules
  defp blocked_address?({0, 0, 0, 0, 0, 0xFFFF, g7, g8}),
    do: blocked_address?(v4_from_groups(g7, g8))

  # IPv4-compatible ::a.b.c.d (deprecated) → re-check under the IPv4 rules
  defp blocked_address?({0, 0, 0, 0, 0, 0, g7, g8}),
    do: blocked_address?(v4_from_groups(g7, g8))

  # IPv6 ULA fc00::/7 (first 7 bits == 1111110)
  defp blocked_address?({g1, _, _, _, _, _, _, _})
       when Bitwise.band(g1, 0xFE00) == 0xFC00,
       do: true

  # IPv6 link-local fe80::/10 (first 10 bits == 1111111010)
  defp blocked_address?({g1, _, _, _, _, _, _, _})
       when Bitwise.band(g1, 0xFFC0) == 0xFE80,
       do: true

  defp blocked_address?(_), do: false

  defp ipv4_blocked?(a, b) do
    a in [0, 10, 127, 255] or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 168)
  end

  # Split two 16-bit IPv6 groups into the embedded IPv4 4-tuple.
  defp v4_from_groups(g7, g8) do
    {Bitwise.bsr(g7, 8), Bitwise.band(g7, 0xFF), Bitwise.bsr(g8, 8), Bitwise.band(g8, 0xFF)}
  end

  defp allowed_schemes do
    if require_https?(), do: ["https"], else: ["http", "https"]
  end

  defp require_https? do
    config() |> Keyword.get(:require_https, false)
  end

  defp resolve_dns? do
    config() |> Keyword.get(:resolve_dns, true)
  end

  # Max time to wait for hostname resolution before failing validation (#223).
  defp dns_timeout_ms do
    config() |> Keyword.get(:dns_timeout_ms, 3_000)
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
