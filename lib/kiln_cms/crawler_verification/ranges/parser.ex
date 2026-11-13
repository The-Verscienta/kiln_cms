defmodule KilnCMS.CrawlerVerification.Ranges.Parser do
  @moduledoc """
  Reads a search engine's published crawler range list (#2586) into parsed
  CIDRs, or refuses the whole list. Pure: no I/O, no config.

  ## What it reads

  The shape Google, Bing, Apple and DuckDuckGo all publish:

      {"creationTime": "...", "prefixes": [{"ipv4Prefix": "66.249.64.0/27"},
                                           {"ipv6Prefix": "2001:4860:4801:10::/64"}]}

  An entry may carry its range under `ipv4Prefix`, `ipv6Prefix` or `prefix`;
  a top-level list of strings is read too. A bare address is a `/32` or
  `/128`. Unknown keys are ignored, and an entry that names no range it can
  parse is skipped. `creationTime` is never read: how fresh a list is depends
  on when this node fetched it, not on what the list says about itself.

  ## What refuses a list

  A list is a claim that every address in it is the vendor's crawler, so a
  list that would verify too much is refused **whole**, never trimmed:

    * the body is not JSON, or not one of the shapes above (`:invalid_json`)
    * no usable range is left (`:no_prefixes`)
    * more than `:max_prefixes` entries (5,000) (`:too_many`)
    * any range wider than an IPv4 `/20` or an IPv6 `/48`, or ranges that
      together cover more than 65,536 IPv4 addresses or 2^80 IPv6 addresses
      (65,536 `/64`s) (`:too_broad`)
    * any range that is not entirely global unicast space
      (`KilnCMS.Security.Cidr.global_unicast_range?/1`): private, loopback,
      shared, link-local, multicast, documentation and benchmarking space,
      NAT64 (`64:ff9b::/96`), 6to4 (`2002::/16`), Teredo (`2001::/32`) and
      anything else outside `2000::/3` (`:not_public`)

  The vendors' own lists sit well inside these limits (a test parses a copy of
  each): Google's widest is a `/27` and `/64`, Bing's a `/22`, Apple's a
  `/24`, and DuckDuckGo publishes single IPv4 addresses.
  """

  import Bitwise

  alias KilnCMS.Security.Cidr

  @default_max_prefixes 5_000

  # The widest range a list may hold, per family.
  @min_prefix %{inet: 20, inet6: 48}

  # How many addresses a whole list may cover, per family: a /16's worth of
  # IPv4, and 65,536 /64s (a /48's worth) of IPv6.
  @max_addresses %{inet: 1 <<< 16, inet6: 1 <<< 80}

  @bits %{inet: 32, inet6: 128}

  @type error :: :invalid_json | :no_prefixes | :too_many | :too_broad | :not_public

  @doc "The widest prefix length a list may hold for `family`."
  @spec min_prefix(Cidr.family()) :: pos_integer()
  def min_prefix(family), do: Map.fetch!(@min_prefix, family)

  @doc """
  Parses a list's JSON `body`. Options: `:max_prefixes` (5,000).

      iex> body = ~s({"prefixes": [{"ipv4Prefix": "66.249.64.0/27"}]})
      iex> KilnCMS.CrawlerVerification.Ranges.Parser.parse(body)
      {:ok, [{:inet, 0x42F94000, 27}]}

      iex> KilnCMS.CrawlerVerification.Ranges.Parser.parse(~s({"prefixes": [{"ipv4Prefix": "0.0.0.0/0"}]}))
      {:error, :too_broad}
  """
  @spec parse(binary(), keyword()) :: {:ok, [Cidr.t()]} | {:error, error()}
  def parse(body, opts \\ []) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"prefixes" => entries}} when is_list(entries) -> parse_entries(entries, opts)
      {:ok, entries} when is_list(entries) -> parse_entries(entries, opts)
      _not_a_list -> {:error, :invalid_json}
    end
  end

  @doc """
  Checks a list already reduced to CIDR strings (`"66.249.64.0/27"`), under
  every rule `parse/2` applies. What a node runs on a list another node sent
  it, so a peer on another release, or a bad payload, cannot install what
  this node's own fetch would have refused.
  """
  @spec parse_strings([term()], keyword()) :: {:ok, [Cidr.t()]} | {:error, error()}
  def parse_strings(strings, opts \\ []) when is_list(strings), do: parse_entries(strings, opts)

  defp parse_entries(entries, opts) do
    max_prefixes = Keyword.get(opts, :max_prefixes, @default_max_prefixes)

    if length(entries) > max_prefixes do
      {:error, :too_many}
    else
      entries
      |> Enum.flat_map(&entry_ranges/1)
      |> Enum.flat_map(&parse_range/1)
      |> Enum.uniq()
      |> check()
    end
  end

  defp entry_ranges(entry) when is_binary(entry), do: [entry]

  defp entry_ranges(entry) when is_map(entry) do
    for key <- ~w(ipv4Prefix ipv6Prefix prefix),
        value <- [Map.get(entry, key)],
        is_binary(value),
        do: value
  end

  defp entry_ranges(_entry), do: []

  defp parse_range(text) do
    case Cidr.parse(text) do
      {:ok, cidr} -> [cidr]
      {:error, :invalid} -> []
    end
  end

  defp check([]), do: {:error, :no_prefixes}

  defp check(cidrs) do
    cond do
      Enum.any?(cidrs, &too_wide?/1) -> {:error, :too_broad}
      covers_too_much?(cidrs) -> {:error, :too_broad}
      not Enum.all?(cidrs, &Cidr.global_unicast_range?/1) -> {:error, :not_public}
      true -> {:ok, cidrs}
    end
  end

  defp too_wide?({family, _net, prefix}), do: prefix < @min_prefix[family]

  # Ranges may nest or repeat, so this over-counts a list that overlaps
  # itself; the vendors' lists do not.
  defp covers_too_much?(cidrs) do
    cidrs
    |> Enum.group_by(&elem(&1, 0), fn {family, _net, prefix} -> 1 <<< (@bits[family] - prefix) end)
    |> Enum.any?(fn {family, sizes} -> Enum.sum(sizes) > @max_addresses[family] end)
  end
end
