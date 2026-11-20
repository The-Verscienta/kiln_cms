defmodule KilnCMS.Backups.Destination.Sftp.Target do
  @moduledoc """
  Where an SFTP destination's files go (#2222), read from its settings
  without contacting anything, and whether it may go there at all.

  Settings:

    * `host` — a DNS name or an IP literal, nothing else (no scheme, user or
      port). An unlisted host is no `localhost`, `.local`, `.internal` or
      metadata name, and no private, loopback or link-local literal; one
      `BACKUP_SFTP_PRIVATE_HOSTS` lists (an exact, case-insensitive name)
      may be private or loopback, never link-local or metadata
      (`KilnCMS.Backups.Destination.HostPolicy`, ADR 0069);
    * `port` — 1 to 65535, 22 when blank;
    * `username` — no control characters, no `@`, at most 255 bytes;
    * `path` — absolute (`/backups/kiln`), segments of `A-Z a-z 0-9 . _ -`
      with no `.` or `..` (`KilnCMS.Backups.Destination.RemotePath`).
      Absolute only: a path relative to the login directory names the same
      place as an absolute one, which the overlap check could not see.

  Files are kept as `<path>/<subdir>/<name>`, every remote path built here
  from the settings and checked segments, never from a checkpoint or a
  listing.
  """

  alias KilnCMS.Backups.Destination.{HostPolicy, RemotePath}

  @enforce_keys [:host, :port, :username, :segments]
  defstruct [:host, :port, :username, :segments]

  @type t :: %__MODULE__{
          host: String.t(),
          port: 1..65_535,
          username: String.t(),
          segments: [String.t()]
        }

  @wording [env: "BACKUP_SFTP_PRIVATE_HOSTS", noun: "the host"]
  @host ~r/\A(?:[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.?|\[?[0-9A-Fa-f:.]+\]?)\z/

  @doc """
  The hosts `BACKUP_SFTP_PRIVATE_HOSTS` lists, lowercased: the only ones an
  SFTP destination may reach on a private or loopback address.
  """
  @spec private_hosts() :: [String.t()]
  def private_hosts, do: HostPolicy.private_hosts(KilnCMS.Backups.Destination.Sftp)

  @doc "How refusals are worded for an SFTP destination."
  @spec wording() :: HostPolicy.wording()
  def wording, do: @wording

  @doc "The settings as a target, or `{:error, message}`. See the moduledoc."
  @spec parse(map(), [String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse(settings, listed \\ private_hosts()) when is_map(settings) do
    with {:ok, host} <- host(settings["host"]),
         {:ok, port} <- port(settings["port"]),
         {:ok, username} <- username(settings["username"]),
         {:ok, segments} <- path(settings["path"]),
         :ok <- HostPolicy.check_host(host, host in listed, @wording) do
      {:ok, %__MODULE__{host: host, port: port, username: username, segments: segments}}
    end
  end

  @doc """
  The address to connect to (`HostPolicy.pin/3`): `{:ok, address}`,
  `{:ok, nil}` with DNS resolution off, `{:error, {:permanent, message}}`
  when an address is not allowed, or `{:error, message}` when the name does
  not resolve.
  """
  @spec pin(t(), [String.t()]) ::
          {:ok, :inet.ip_address() | nil} | {:error, String.t() | {:permanent, String.t()}}
  def pin(%__MODULE__{host: host}, listed \\ private_hosts()),
    do: HostPolicy.pin(host, host in listed, @wording)

  @doc """
  Where `settings` write, normalized for
  `KilnCMS.Backups.Destination.overlap?/2`: `{:sftp, host, port, username,
  segments}`, the host lowercased with no trailing dot and the port 22 when
  none is given. Read from the settings as stored, valid or not.
  """
  @spec location(map()) ::
          {:sftp, String.t(), non_neg_integer(), String.t(), [String.t()]}
  def location(settings) when is_map(settings) do
    host =
      settings["host"]
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.trim_trailing(".")
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    port =
      case port(settings["port"]) do
        {:ok, port} -> port
        {:error, _message} -> 0
      end

    segments = settings["path"] |> to_string() |> String.split("/", trim: true)

    {:sftp, host, port, settings["username"] |> to_string() |> String.trim(), segments}
  end

  @doc """
  The server and login `settings` name: `%{"host", "port", "username"}`, as
  `location/1` normalizes them. A host key is trusted for these
  (`KilnCMS.Backups.scan_destination_host_key/2`): a scan of one never
  vouches for another.
  """
  @spec server(map()) :: %{String.t() => String.t() | non_neg_integer()}
  def server(settings) when is_map(settings) do
    {:sftp, host, port, username, _segments} = location(settings)
    %{"host" => host, "port" => port, "username" => username}
  end

  @doc "The base directory, as an absolute path (`\"/\"` for none)."
  @spec base(t()) :: String.t()
  def base(%__MODULE__{segments: segments}), do: "/" <> Enum.join(segments, "/")

  @doc "Each directory from the first segment down to the base, absolute."
  @spec base_prefixes(t()) :: [String.t()]
  def base_prefixes(%__MODULE__{segments: segments}),
    do: Enum.scan(segments, "", &(&2 <> "/" <> &1))

  @doc ~s[The directory of `subdir` (`"db"`, `"media"`, `".kiln-test"`).]
  @spec dir(t(), String.t()) :: String.t()
  def dir(%__MODULE__{segments: segments}, subdir),
    do: "/" <> Enum.join(segments ++ [subdir], "/")

  @doc "The file `name` in `subdir`."
  @spec file(t(), String.t(), String.t()) :: String.t()
  def file(%__MODULE__{} = target, subdir, name), do: dir(target, subdir) <> "/" <> name

  @doc "`sftp://user@host:port/path`, for people to read."
  @spec describe(map()) :: String.t()
  def describe(settings) when is_map(settings) do
    {:sftp, host, port, username, segments} = location(settings)
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    "sftp://#{username}@#{host}:#{port}/#{Enum.join(segments, "/")}"
  end

  ## Settings

  defp host(host) when is_binary(host) do
    host = host |> String.trim() |> String.downcase()

    cond do
      host == "" ->
        {:error, "the host is missing"}

      not Regex.match?(@host, host) or byte_size(host) > 253 ->
        {:error, "the host must be a host name or an IP address, with no scheme or port"}

      String.contains?(host, ":") and not HostPolicy.ip_literal?(host) ->
        {:error, "the host must be a host name or an IP address, with no scheme or port"}

      true ->
        {:ok,
         host
         |> String.trim_trailing(".")
         |> String.trim_leading("[")
         |> String.trim_trailing("]")}
    end
  end

  defp host(_host), do: {:error, "the host is missing"}

  defp port(nil), do: {:ok, 22}
  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp port(_port), do: {:error, "the port must be a number from 1 to 65535"}

  defp username(username) when is_binary(username) do
    username = String.trim(username)

    cond do
      username == "" ->
        {:error, "the username is missing"}

      byte_size(username) > 255 ->
        {:error, "the username is too long"}

      username =~ ~r/[\x00-\x1f\x7f@]/u ->
        {:error, "the username must not contain @ or control characters"}

      not String.valid?(username) ->
        {:error, "the username must be text"}

      true ->
        {:ok, username}
    end
  end

  defp username(_username), do: {:error, "the username is missing"}

  defp path(path) when is_binary(path) do
    path = String.trim(path)

    if String.starts_with?(path, "/"),
      do: RemotePath.segments(path, "the path"),
      else: {:error, "the path must be absolute, e.g. /backups/kiln"}
  end

  defp path(_path), do: {:error, "the path is missing"}
end
