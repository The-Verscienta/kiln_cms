defmodule KilnCMS.Security.Cidr do
  @moduledoc """
  Pure IP/CIDR parsing, normalisation and matching for operator-defined block
  rules (#2242). No I/O, no config: the same input always gives the same answer,
  so the matcher and the write-time validation cannot disagree.

  A CIDR is the parsed triple `{family, network, prefix}` — `family` is `:inet`
  or `:inet6`, `network` the address as an integer with the host bits already
  cleared, `prefix` the mask length. A bare address is a single-host rule
  (`/32` or `/128`).

  ## Normalisation

  `normalise/1` gives one stored spelling per range, so the unique identity on
  the resource and a `contains?/2` comparison both see the same rule however an
  operator typed it:

    * host bits are masked off (`10.1.2.3/8` is `10.0.0.0/8`)
    * IPv6 is lowercase and compressed (`:inet.ntoa/1`)
    * an IPv4-mapped IPv6 range (`::ffff:10.0.0.0/104`) is stored as the IPv4
      range it means (`10.0.0.0/8`) — a client behind a dual-stack listener
      shows up as the mapped form, and a rule must catch it either way

  ## What may be blocked

  `blockable/1` is the write-time guard. It refuses what would lock an operator
  out of their own host or, in one keystroke, everyone out of the site:

    * anything that overlaps loopback (`127.0.0.0/8`, `::1`): the health probes
      and local tooling arrive from there, and it is never matched either
      (`loopback?/1`)
    * IPv4 wider than `/8`, IPv6 wider than `/16` (so `0.0.0.0/0` and
      `::/0` are refused)

  Parsing is strict: no leading-zero octets (`010.0.0.1` is read as octal by
  some stacks and decimal by others), no IPv6 zone ids, no whitespace inside.
  """

  import Bitwise

  @type family :: :inet | :inet6
  @type t :: {family(), non_neg_integer(), non_neg_integer()}
  @type ip :: :inet.ip_address()

  @min_prefix %{inet: 8, inet6: 16}
  @bits %{inet: 32, inet6: 128}

  # ::ffff:0:0/96 as a network integer.
  @mapped_net 0xFFFF <<< 32

  @doc "Shortest allowed prefix per family (the floor `blockable/1` enforces)."
  @spec min_prefix(family()) :: non_neg_integer()
  def min_prefix(family), do: Map.fetch!(@min_prefix, family)

  @doc """
  Parses `input` (an address, or `address/prefix`) into a masked, canonical
  `t:t/0`.

      iex> KilnCMS.Security.Cidr.parse("10.1.2.3/8")
      {:ok, {:inet, 167_772_160, 8}}

      iex> KilnCMS.Security.Cidr.parse("not an ip")
      {:error, :invalid}
  """
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid}
  def parse(input) when is_binary(input) do
    with [addr | rest] when length(rest) <= 1 <- String.split(String.trim(input), "/"),
         {:ok, ip} <- parse_address(addr),
         {family, int} = to_int(ip),
         {:ok, prefix} <- parse_prefix(rest, @bits[family]) do
      {:ok, canonical({family, int, prefix})}
    else
      _ -> {:error, :invalid}
    end
  end

  def parse(_), do: {:error, :invalid}

  @doc """
  The stored spelling of `input`: masked, compressed, mapped ranges folded to
  IPv4. The prefix is always written, so `10.0.0.1` is `10.0.0.1/32`.

      iex> KilnCMS.Security.Cidr.normalise("::FFFF:10.0.0.1")
      {:ok, "10.0.0.1/32"}
  """
  @spec normalise(term()) :: {:ok, String.t()} | {:error, :invalid}
  def normalise(input) do
    with {:ok, cidr} <- parse(input), do: {:ok, format(cidr)}
  end

  @doc "The canonical text of a parsed CIDR."
  @spec format(t()) :: String.t()
  def format({family, net, prefix}) do
    :inet.ntoa(from_int(family, net)) |> List.to_string() |> Kernel.<>("/#{prefix}")
  end

  @doc """
  Is `ip` inside `cidr`? `cidr` is a string or a parsed `t:t/0`; `ip` an address
  tuple or string. An IPv4-mapped IPv6 address is tested as the IPv4 address it
  carries (and, for a rule written wider than the mapped block, as IPv6 too).
  Anything unparseable matches nothing.

      iex> KilnCMS.Security.Cidr.contains?("10.0.0.0/8", {0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203})
      true

      iex> KilnCMS.Security.Cidr.contains?("10.0.0.0/8", {11, 0, 0, 1})
      false
  """
  @spec contains?(String.t() | t(), ip() | String.t()) :: boolean()
  def contains?(cidr, ip) when is_binary(cidr) do
    case parse(cidr) do
      {:ok, parsed} -> contains?(parsed, ip)
      _ -> false
    end
  end

  def contains?(cidr, ip) when is_binary(ip) do
    case parse_address(String.trim(ip)) do
      {:ok, tuple} -> contains?(cidr, tuple)
      _ -> false
    end
  end

  def contains?({_, _, _} = cidr, ip) when is_tuple(ip) do
    case address_forms(ip) do
      [] -> false
      forms -> Enum.any?(forms, &within?(cidr, &1))
    end
  end

  def contains?(_cidr, _ip), do: false

  @doc """
  Is the address loopback (`127.0.0.0/8`, `::1`, or the mapped form of either)?
  Loopback is never blocked, so a rule list can never cut off the node itself.
  """
  @spec loopback?(ip() | String.t()) :: boolean()
  def loopback?(ip) when is_binary(ip) do
    case parse_address(String.trim(ip)) do
      {:ok, tuple} -> loopback?(tuple)
      _ -> false
    end
  end

  def loopback?(ip) when is_tuple(ip) do
    ip |> address_forms() |> Enum.any?(&loopback_form?/1)
  end

  def loopback?(_), do: false

  @doc """
  Write-time guard: may this rule be stored? `{:ok, cidr_string}` is the
  normalised rule; otherwise a reason — `:invalid`, `:too_broad` (below the
  prefix floor) or `:loopback` (overlaps `127.0.0.0/8` / `::1`).

      iex> KilnCMS.Security.Cidr.blockable("0.0.0.0/0")
      {:error, :too_broad}

      iex> KilnCMS.Security.Cidr.blockable("127.0.0.1")
      {:error, :loopback}
  """
  @spec blockable(term()) :: {:ok, String.t()} | {:error, :invalid | :too_broad | :loopback}
  def blockable(input) do
    with {:ok, {family, _, prefix} = cidr} <- parse(input),
         :ok <- check_floor(family, prefix),
         :ok <- check_loopback(cidr) do
      {:ok, format(cidr)}
    end
  end

  defp check_floor(family, prefix) do
    if prefix < @min_prefix[family], do: {:error, :too_broad}, else: :ok
  end

  # A range overlaps loopback when it contains one of its ends: ranges nest, so
  # either it holds the whole of 127/8 (wider than /8, already refused by the
  # floor, but checked here so the guard stands on its own) or sits inside it.
  defp check_loopback({:inet, _, _} = cidr) do
    if overlaps?(cidr, {:inet, 127 <<< 24, 8}), do: {:error, :loopback}, else: :ok
  end

  defp check_loopback({:inet6, _, _} = cidr) do
    if overlaps?(cidr, {:inet6, 1, 128}) or overlaps?(cidr, mapped_loopback()),
      do: {:error, :loopback},
      else: :ok
  end

  # ::ffff:127.0.0.0/104
  defp mapped_loopback, do: {:inet6, @mapped_net ||| 127 <<< 24, 104}

  defp overlaps?({fam, _, p1} = a, {fam, _, p2} = b) do
    {_, n1, _} = a
    {_, n2, _} = b
    shorter = min(p1, p2)
    shift = @bits[fam] - shorter
    n1 >>> shift == n2 >>> shift
  end

  defp overlaps?(_, _), do: false

  defp within?({fam, net, prefix}, {fam, int}) do
    shift = @bits[fam] - prefix
    net >>> shift == int >>> shift
  end

  defp within?(_, _), do: false

  # The forms an address is tested under: its own family, plus the IPv4 it
  # carries when it is IPv4-mapped.
  defp address_forms({_, _, _, _} = ip), do: [to_int(ip)]

  defp address_forms({0, 0, 0, 0, 0, 0xFFFF, hi, lo} = ip),
    do: [{:inet, hi <<< 16 ||| lo}, to_int(ip)]

  defp address_forms(ip) when tuple_size(ip) == 8, do: [to_int(ip)]
  defp address_forms(_), do: []

  defp loopback_form?({:inet, int}), do: int >>> 24 == 127
  defp loopback_form?({:inet6, int}), do: int == 1

  # Fold a mapped range to IPv4 so one range has one spelling.
  defp canonical({:inet6, net, prefix}) when prefix >= 96 do
    if net >>> 32 == 0xFFFF do
      {:inet, net &&& 0xFFFFFFFF, prefix - 96} |> mask()
    else
      mask({:inet6, net, prefix})
    end
  end

  defp canonical(cidr), do: mask(cidr)

  defp mask({fam, net, prefix}) do
    shift = @bits[fam] - prefix
    {fam, (net >>> shift) <<< shift, prefix}
  end

  defp parse_prefix([], bits), do: {:ok, bits}

  defp parse_prefix([text], bits) do
    with true <- Regex.match?(~r/\A\d{1,3}\z/, text),
         n = String.to_integer(text),
         true <- n <= bits do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp parse_address(text) do
    cond do
      String.contains?(text, "%") -> :error
      # Leading zeros in a dotted quad: octal in some stacks, decimal in others.
      leading_zero_octet?(text) -> :error
      true -> :inet.parse_strict_address(String.to_charlist(text))
    end
  end

  defp leading_zero_octet?(text) do
    dotted = text |> String.split(":") |> List.last()

    String.contains?(dotted, ".") and
      dotted
      |> String.split(".")
      |> Enum.any?(&(String.length(&1) > 1 and String.starts_with?(&1, "0")))
  end

  defp to_int({a, b, c, d}), do: {:inet, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

  defp to_int(ip) when tuple_size(ip) == 8 do
    int =
      ip
      |> Tuple.to_list()
      |> Enum.reduce(0, fn word, acc -> acc <<< 16 ||| word end)

    {:inet6, int}
  end

  defp from_int(:inet, int),
    do: {int >>> 24 &&& 255, int >>> 16 &&& 255, int >>> 8 &&& 255, int &&& 255}

  defp from_int(:inet6, int),
    do: List.to_tuple(for shift <- 112..0//-16, do: int >>> shift &&& 0xFFFF)
end
