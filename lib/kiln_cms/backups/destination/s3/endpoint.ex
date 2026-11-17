defmodule KilnCMS.Backups.Destination.S3.Endpoint do
  @moduledoc """
  Where an S3 destination's requests go (#2221), and whether they may go
  there at all. A platform admin types the endpoint into a form, so it is
  treated like a webhook URL (`KilnCMS.Webhooks.SafeUrl`), with one opening
  the operator controls: `BACKUP_S3_PRIVATE_HOSTS`.

  `parse/2` checks the settings without contacting anything (the adapter's
  `validate/1`, and the start of every call):

    * the endpoint is an `https://` URL with a host and nothing else (no
      user info, path, query or fragment). `http://` only for a host
      `BACKUP_S3_PRIVATE_HOSTS` lists, whatever `SafeUrl`'s own HTTPS rule
      says;
    * an unlisted host is no `localhost`, `.local`, `.internal` or metadata
      name, and no private, loopback or link-local IP literal. A listed one
      (an exact, case-insensitive name) may be any of those but a metadata
      name or a link-local address, which no listing opens. The name that
      must be listed is the one connected to: `<bucket>.<host>` when the
      bucket is addressed virtual-hosted, so a private store needs either
      that name listed or `path_style` on;
    * the bucket follows S3's naming rules; one with a dot, or an endpoint
      that is an IP literal, is addressed path-style (a wildcard
      certificate covers no dotted bucket);
    * the region is lowercase letters, digits and `-` (`auto` for R2);
    * the prefix is `/`-separated segments of `A-Z a-z 0-9 . _ -`, none of
      them `.` or `..`, slashes at either end dropped.

  `pin/1` resolves the host requests connect to (the bucket's own name when
  addressed virtual-hosted) and answers the one address to connect to:
  every address it resolves to must be allowed, as above. Run on save (a
  core validation) and before every call, so a name that resolves somewhere
  else by now is refused rather than followed. With DNS resolution off (the
  test env), a name pins to `nil` and is connected to by name.
  """

  alias KilnCMS.Webhooks.SafeUrl

  @enforce_keys [:scheme, :host, :port, :bucket, :region]
  defstruct [:scheme, :host, :port, :bucket, :region, prefix: [], path_style?: false]

  @type t :: %__MODULE__{
          scheme: String.t(),
          host: String.t(),
          port: pos_integer(),
          bucket: String.t(),
          region: String.t(),
          prefix: [String.t()],
          path_style?: boolean()
        }

  @metadata_names ~w(metadata.google.internal metadata.goog metadata instance-data)
  @blocked_names ~w(localhost)

  @region ~r/\A[a-z0-9][a-z0-9-]{0,39}\z/
  @bucket ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
  @segment ~r/\A[A-Za-z0-9._-]{1,255}\z/
  @max_prefix 512

  @doc """
  The hosts `BACKUP_S3_PRIVATE_HOSTS` lists, lowercased: the only ones an S3
  destination may reach over `http://` or on a private or loopback address.
  """
  @spec private_hosts() :: [String.t()]
  def private_hosts do
    :kiln_cms
    |> Application.get_env(KilnCMS.Backups.Destination.S3, [])
    |> Keyword.get(:private_hosts, [])
  end

  @doc """
  Parses `BACKUP_S3_PRIVATE_HOSTS`: host names (or IP literals) separated by
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

  @doc "The settings as an endpoint, or `{:error, message}`. See the moduledoc."
  @spec parse(map(), [String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse(settings, listed \\ private_hosts()) when is_map(settings) do
    with {:ok, uri} <- endpoint_uri(settings["endpoint"]),
         {:ok, bucket} <- bucket(settings["bucket"]),
         {:ok, region} <- region(settings["region"]),
         {:ok, prefix} <- prefix(settings["prefix"]) do
      host = uri.host |> String.downcase() |> String.trim_trailing(".")

      endpoint = %__MODULE__{
        scheme: uri.scheme,
        host: host,
        port: uri.port,
        bucket: bucket,
        region: region,
        prefix: prefix,
        path_style?:
          settings["path_style"] == true or String.contains?(bucket, ".") or ip_literal?(host)
      }

      # The name connected to is what must be listed: `bucket.host` when
      # virtual-hosted, so listing a host opens none of its subdomains.
      listed? = listed?(endpoint, listed)

      with :ok <- scheme(uri.scheme, listed?),
           :ok <- metadata(host),
           :ok <- host(connect_host(endpoint), listed?),
           do: {:ok, endpoint}
    end
  end

  @doc """
  Whether `BACKUP_S3_PRIVATE_HOSTS` lists the exact name `endpoint`'s
  requests connect to (`connect_host/1`).
  """
  @spec listed?(t(), [String.t()]) :: boolean()
  def listed?(%__MODULE__{} = endpoint, listed \\ private_hosts()),
    do: connect_host(endpoint) in listed

  defp metadata(host) do
    if host in @metadata_names,
      do: {:error, "the endpoint must not be a metadata host"},
      else: :ok
  end

  @doc "The host requests connect to: the bucket's own name, unless path-style."
  @spec connect_host(t()) :: String.t()
  def connect_host(%__MODULE__{path_style?: true, host: host}), do: host
  def connect_host(%__MODULE__{bucket: bucket, host: host}), do: bucket <> "." <> host

  @doc """
  The URL of `key` (a path under the bucket, `""` for the bucket itself)
  with `query`, already encoded. Keys and prefixes only ever hold characters
  that need no encoding (see the moduledoc and `object_key/3`).
  """
  @spec url(t(), String.t(), String.t()) :: String.t()
  def url(%__MODULE__{} = endpoint, key, query \\ "") do
    authority =
      case {endpoint.scheme, endpoint.port} do
        {"https", 443} -> url_host(connect_host(endpoint))
        {"http", 80} -> url_host(connect_host(endpoint))
        {_scheme, port} -> "#{url_host(connect_host(endpoint))}:#{port}"
      end

    path =
      if endpoint.path_style?,
        do: "/" <> Enum.join(Enum.reject([endpoint.bucket, key], &(&1 == "")), "/"),
        else: "/" <> key

    query = if query == "", do: "", else: "?" <> query
    "#{endpoint.scheme}://#{authority}#{path}#{query}"
  end

  defp url_host(host), do: if(String.contains?(host, ":"), do: "[#{host}]", else: host)

  @doc "The object key of `name` in `subdir` under the endpoint's prefix."
  @spec object_key(t(), String.t(), String.t()) :: String.t()
  def object_key(%__MODULE__{prefix: prefix}, subdir, name),
    do: Enum.join(prefix ++ [subdir, name], "/")

  @doc "The key prefix of `subdir` (or of everything, with `nil`), ending in `/`."
  @spec key_prefix(t(), String.t() | nil) :: String.t()
  def key_prefix(%__MODULE__{prefix: prefix}, nil),
    do: if(prefix == [], do: "", else: Enum.join(prefix, "/") <> "/")

  def key_prefix(%__MODULE__{prefix: prefix}, subdir),
    do: Enum.join(prefix ++ [subdir], "/") <> "/"

  @doc """
  The address to connect to for `endpoint`: `{:ok, address}`, `{:ok, nil}`
  when DNS resolution is off and the host is a name,
  `{:error, {:permanent, message}}` when any address it resolves to is not
  allowed, or `{:error, message}` when it doesn't resolve or the lookup
  times out. A call answers that last one as a transient error; saving a
  destination refuses it. See the moduledoc.
  """
  @spec pin(t(), [String.t()]) ::
          {:ok, :inet.ip_address() | nil} | {:error, String.t() | {:permanent, String.t()}}
  def pin(%__MODULE__{} = endpoint, listed \\ private_hosts()) do
    listed? = listed?(endpoint, listed)
    target = connect_host(endpoint)

    case SafeUrl.lookup(target) do
      :no_dns ->
        {:ok, nil}

      {:ok, addresses} ->
        case Enum.find(addresses, &(not allowed_address?(&1, listed?))) do
          nil -> {:ok, hd(addresses)}
          refused -> {:error, {:permanent, refusal(refused, listed?)}}
        end

      {:error, message} ->
        {:error, "#{target}: #{message}"}
    end
  end

  defp refusal(address, listed?) do
    cond do
      never?(address) ->
        "the endpoint resolves to a link-local or metadata address, which no setting allows"

      listed? ->
        "the endpoint resolves to an address that is not allowed"

      true ->
        "the endpoint resolves to a private or loopback address; " <>
          "list its host in BACKUP_S3_PRIVATE_HOSTS to allow it"
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

  # 169.254.0.0/16 (cloud metadata lives at 169.254.169.254), fe80::/10, the
  # EC2 IPv6 metadata address, and their IPv4-mapped and -compatible forms.
  defp never?({169, 254, _c, _d}), do: true
  defp never?({0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}), do: true
  defp never?({g1, _, _, _, _, _, _, _}) when Bitwise.band(g1, 0xFFC0) == 0xFE80, do: true

  # NAT64 64:ff9b::/96 and 6to4 2002::/16 carry an IPv4 address that a
  # translator or relay delivers to.
  defp never?({0x64, 0xFF9B, 0, 0, 0, 0, g7, g8}), do: never?(v4(g7, g8))
  defp never?({0x2002, g2, g3, _, _, _, _, _}), do: never?(v4(g2, g3))

  defp never?({0, 0, 0, 0, 0, mapped, g7, g8}) when mapped in [0, 0xFFFF],
    do:
      never?(
        {Bitwise.bsr(g7, 8), Bitwise.band(g7, 0xFF), Bitwise.bsr(g8, 8), Bitwise.band(g8, 0xFF)}
      )

  defp never?(_address), do: false

  defp v4(high, low),
    do:
      {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8),
       Bitwise.band(low, 0xFF)}

  ## Settings

  defp endpoint_uri(raw) when is_binary(raw) do
    case URI.new(String.trim(raw)) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
        cond do
          uri.userinfo != nil -> {:error, "the endpoint must not contain credentials"}
          uri.query != nil or uri.fragment != nil -> {:error, "the endpoint must be a bare URL"}
          uri.path not in [nil, "", "/"] -> {:error, "the endpoint must not have a path"}
          true -> {:ok, uri}
        end

      _invalid ->
        {:error, "the endpoint must be a URL, e.g. https://s3.us-east-1.amazonaws.com"}
    end
  end

  defp endpoint_uri(_raw), do: {:error, "the endpoint is missing"}

  defp scheme("https", _listed?), do: :ok
  defp scheme("http", true), do: :ok

  defp scheme("http", false),
    do:
      {:error,
       "the endpoint must use https:// (http:// only for a host in BACKUP_S3_PRIVATE_HOSTS)"}

  defp scheme(_scheme, _listed?), do: {:error, "the endpoint must use https://"}

  defp host(host, listed?) do
    base = String.trim_trailing(host, ".")

    cond do
      base in @metadata_names -> {:error, "the endpoint must not be a metadata host"}
      ip_literal?(base) -> literal(base, listed?)
      listed? -> :ok
      true -> unlisted_name(base)
    end
  end

  defp literal(base, listed?) do
    {:ok, address} = :inet.parse_address(String.to_charlist(base))
    if allowed_address?(address, listed?), do: :ok, else: {:error, refusal(address, listed?)}
  end

  defp unlisted_name(base) do
    cond do
      base in @blocked_names or String.ends_with?(base, ".localhost") ->
        {:error, "the endpoint must not be a loopback host"}

      String.ends_with?(base, [".local", ".internal"]) ->
        {:error,
         "the endpoint must not be a .local or .internal host unless BACKUP_S3_PRIVATE_HOSTS lists it"}

      true ->
        :ok
    end
  end

  defp ip_literal?(host) do
    match?(
      {:ok, _},
      host
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.to_charlist()
      |> :inet.parse_address()
    )
  end

  defp bucket(bucket) when is_binary(bucket) do
    bucket = String.trim(bucket)

    cond do
      not Regex.match?(@bucket, bucket) ->
        {:error,
         "the bucket name must be 3 to 63 lowercase letters, digits, dots and hyphens, " <>
           "starting and ending with a letter or digit"}

      String.contains?(bucket, ["..", ".-", "-."]) ->
        {:error, "the bucket name must not have two dots, or a dot next to a hyphen, in a row"}

      ip_literal?(bucket) ->
        {:error, "the bucket name must not look like an IP address"}

      String.starts_with?(bucket, "xn--") or String.ends_with?(bucket, "-s3alias") ->
        {:error, "the bucket name uses a prefix or suffix S3 reserves"}

      true ->
        {:ok, bucket}
    end
  end

  defp bucket(_bucket), do: {:error, "the bucket is missing"}

  defp region(region) when is_binary(region) do
    region = String.trim(region)

    if Regex.match?(@region, region),
      do: {:ok, region},
      else:
        {:error,
         "the region must be lowercase letters, digits and hyphens, e.g. us-east-1 or auto"}
  end

  defp region(_region), do: {:error, "the region is missing"}

  @doc """
  The prefix setting as segments (see the moduledoc), or `{:error, message}`.
  """
  @spec prefix(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def prefix(nil), do: {:ok, []}

  def prefix(prefix) when is_binary(prefix) do
    trimmed = prefix |> String.trim() |> String.trim("/")

    segments = if trimmed == "", do: [], else: String.split(trimmed, "/")

    cond do
      byte_size(trimmed) > @max_prefix ->
        {:error, "the prefix is too long"}

      Enum.any?(segments, &(&1 in [".", ".."] or not Regex.match?(@segment, &1))) ->
        {:error,
         "the prefix must be folder names of letters, digits, dots, hyphens and underscores, " <>
           "separated by /"}

      true ->
        {:ok, segments}
    end
  end

  def prefix(_prefix), do: {:error, "the prefix must be text"}
end
