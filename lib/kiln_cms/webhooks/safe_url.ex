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
    base = host |> String.split(":") |> hd()

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
    |> String.split(":")
    |> hd()
    |> resolve_addresses()
    |> check_resolved_addresses()
  end

  defp check_resolved_addresses({:ok, addresses}) do
    if Enum.any?(addresses, &blocked_ip?/1),
      do: {:error, "must not resolve to a private or link-local address"},
      else: :ok
  end

  defp check_resolved_addresses({:error, _}), do: {:error, "hostname could not be resolved"}

  defp resolve_addresses(host) do
    charlist = String.to_charlist(host)

    case :inet.gethostbyname(charlist) do
      {:ok, {:hostent, _name, _aliases, _addrtype, _length, addresses}} ->
        {:ok, Enum.map(addresses, &normalize_address/1)}

      {:error, reason} ->
        {:error, reason}
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

  defp blocked_address?({a, b, _, _}), do: ipv4_blocked?(a, b)
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_address?({0xFE, b, _, _, _, _, _, _}), do: ipv6_link_local?(b)
  defp blocked_address?({0xFC, _, _, _, _, _, _, _}), do: true
  defp blocked_address?({0xFD, _, _, _, _, _, _, _}), do: true
  defp blocked_address?(_), do: false

  defp ipv4_blocked?(a, b) do
    a in [0, 10, 127, 255] or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 168)
  end

  defp ipv6_link_local?(b), do: Bitwise.band(b, 0xC0) == 0x80

  defp allowed_schemes do
    if require_https?(), do: ["https"], else: ["http", "https"]
  end

  defp require_https? do
    config() |> Keyword.get(:require_https, false)
  end

  defp resolve_dns? do
    config() |> Keyword.get(:resolve_dns, true)
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
