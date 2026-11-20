defmodule KilnCMS.Backups.Destination.HostPolicy do
  @moduledoc """
  Which hosts a remote backup destination may connect to (#2221, #2222,
  ADR 0069): the rule Kiln's own network adapters share. A platform admin
  types the host into a form, so it is treated like a webhook URL
  (`KilnCMS.Webhooks.SafeUrl`), with one opening the operator controls: an
  exact-name list of private hosts, one environment variable per adapter
  (`BACKUP_S3_PRIVATE_HOSTS`, `BACKUP_SFTP_PRIVATE_HOSTS`), so allowing a
  host for one protocol opens no other port of it.

    * `check_host/3` decides without contacting anything (an adapter's
      `validate/1`, and the start of every call): an unlisted host is no
      `localhost`, `*.localhost`, `.local`, `.internal` or metadata name, and
      no private, loopback or link-local IP literal. A listed one may be any
      of those but a metadata name or a link-local address, which no listing
      opens;
    * `pin/3` resolves the host and answers the one address to connect to:
      every address it resolves to must be allowed, as above. Run on save (a
      core validation) and before every call, so a name that resolves
      somewhere else by now is refused rather than followed. With DNS
      resolution off (the test env), a name pins to `nil` and is connected
      to by name.

  The refusal sentences name the thing refused (`:noun`, e.g. `"the
  endpoint"` or `"the host"`) and the variable that would open it (`:env`),
  so each adapter says them in its own words.
  """

  alias KilnCMS.Webhooks.SafeUrl

  @metadata_names ~w(metadata.google.internal metadata.goog metadata instance-data)
  @blocked_names ~w(localhost)

  @typedoc """
  How refusals are worded: `:env`, the variable that lists private hosts,
  and `:noun`, what the host is called (`"the endpoint"`).
  """
  @type wording :: [env: String.t(), noun: String.t()]

  @doc """
  The hosts `adapter`'s `:private_hosts` config lists, lowercased: the only
  ones a destination of that adapter may reach on a private or loopback
  address.
  """
  @spec private_hosts(module()) :: [String.t()]
  def private_hosts(adapter) when is_atom(adapter) do
    :kiln_cms
    |> Application.get_env(adapter, [])
    |> Keyword.get(:private_hosts, [])
  end

  @doc """
  Parses a private-hosts variable: host names (or IP literals) separated by
  commas, trimmed and lowercased, blanks dropped. A name with a scheme, a
  port, a path or a wildcard is not a host name and is dropped, so the list
  only ever names exact hosts.
  """
  @spec parse_private_hosts(String.t() | nil) :: [String.t()]
  def parse_private_hosts(nil), do: []

  def parse_private_hosts(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.filter(&(&1 =~ ~r/\A(?:[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.?|[0-9a-f:.]+)\z/))
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.uniq()
  end

  @doc "Whether `host` (lowercased, no trailing dot) is a cloud metadata name."
  @spec metadata_name?(String.t()) :: boolean()
  def metadata_name?(host) when is_binary(host),
    do: String.trim_trailing(host, ".") in @metadata_names

  @doc """
  Whether `host` may be connected to, by its name or literal alone:
  `:ok`, or `{:error, message}` worded by `wording`. `listed?` is whether
  the private-hosts variable lists the exact name. See the moduledoc.
  """
  @spec check_host(String.t(), boolean(), wording()) :: :ok | {:error, String.t()}
  def check_host(host, listed?, wording) when is_binary(host) do
    base = String.trim_trailing(host, ".")
    noun = Keyword.fetch!(wording, :noun)

    cond do
      base in @metadata_names -> {:error, "#{noun} must not be a metadata host"}
      ip_literal?(base) -> literal(base, listed?, wording)
      listed? -> :ok
      true -> unlisted_name(base, wording)
    end
  end

  defp literal(base, listed?, wording) do
    {:ok, address} = parse_address(base)

    if allowed_address?(address, listed?),
      do: :ok,
      else: {:error, refusal(address, listed?, wording)}
  end

  defp unlisted_name(base, wording) do
    noun = Keyword.fetch!(wording, :noun)
    env = Keyword.fetch!(wording, :env)

    cond do
      base in @blocked_names or String.ends_with?(base, ".localhost") ->
        {:error, "#{noun} must not be a loopback host"}

      String.ends_with?(base, [".local", ".internal"]) ->
        {:error, "#{noun} must not be a .local or .internal host unless #{env} lists it"}

      true ->
        :ok
    end
  end

  @doc """
  The address to connect to for `host`: `{:ok, address}`, `{:ok, nil}` when
  DNS resolution is off and the host is a name,
  `{:error, {:permanent, message}}` when any address it resolves to is not
  allowed, or `{:error, message}` when it doesn't resolve or the lookup
  times out. A call answers that last one as a transient error; saving a
  destination refuses it.
  """
  @spec pin(String.t(), boolean(), wording()) ::
          {:ok, :inet.ip_address() | nil} | {:error, String.t() | {:permanent, String.t()}}
  def pin(host, listed?, wording) when is_binary(host) do
    case SafeUrl.lookup(host) do
      :no_dns ->
        {:ok, nil}

      {:ok, addresses} ->
        case Enum.find(addresses, &(not allowed_address?(&1, listed?))) do
          nil -> {:ok, hd(addresses)}
          refused -> {:error, {:permanent, refusal(refused, listed?, wording)}}
        end

      {:error, message} ->
        {:error, "#{host}: #{message}"}
    end
  end

  @doc "Why `address` is refused, worded by `wording`."
  @spec refusal(:inet.ip_address(), boolean(), wording()) :: String.t()
  def refusal(address, listed?, wording) do
    noun = Keyword.fetch!(wording, :noun)

    cond do
      never?(address) ->
        "#{noun} resolves to a link-local or metadata address, which no setting allows"

      listed? ->
        "#{noun} resolves to an address that is not allowed"

      true ->
        "#{noun} resolves to a private or loopback address; " <>
          "list its host in #{Keyword.fetch!(wording, :env)} to allow it"
    end
  end

  @doc """
  Whether a destination may connect to `address`: never to a link-local or
  metadata address; to a private or loopback one only for a listed host.
  """
  @spec allowed_address?(:inet.ip_address(), boolean()) :: boolean()
  def allowed_address?(address, listed?) do
    cond do
      never?(address) -> false
      listed? -> true
      true -> not SafeUrl.blocked_address?(address)
    end
  end

  @doc """
  Whether no listing can open `address`: 169.254.0.0/16 (cloud metadata
  lives at 169.254.169.254), fe80::/10, the EC2 IPv6 metadata address, and
  their IPv4-mapped, -compatible, NAT64 and 6to4 forms.
  """
  @spec never?(:inet.ip_address()) :: boolean()
  def never?({169, 254, _c, _d}), do: true
  def never?({0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}), do: true
  def never?({g1, _, _, _, _, _, _, _}) when Bitwise.band(g1, 0xFFC0) == 0xFE80, do: true

  # NAT64 64:ff9b::/96 and 6to4 2002::/16 carry an IPv4 address that a
  # translator or relay delivers to.
  def never?({0x64, 0xFF9B, 0, 0, 0, 0, g7, g8}), do: never?(v4(g7, g8))
  def never?({0x2002, g2, g3, _, _, _, _, _}), do: never?(v4(g2, g3))

  def never?({0, 0, 0, 0, 0, mapped, g7, g8}) when mapped in [0, 0xFFFF],
    do: never?(v4(g7, g8))

  def never?(_address), do: false

  defp v4(high, low),
    do:
      {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8),
       Bitwise.band(low, 0xFF)}

  @doc "Whether `host` is an IP literal, bracketed or not."
  @spec ip_literal?(String.t()) :: boolean()
  def ip_literal?(host) when is_binary(host), do: match?({:ok, _}, parse_address(host))

  defp parse_address(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
  end
end
