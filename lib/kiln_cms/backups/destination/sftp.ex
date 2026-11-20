defmodule KilnCMS.Backups.Destination.Sftp do
  @moduledoc """
  A backup destination on an SFTP server (#2222): a NAS, a storage box, any
  host with OpenSSH. Kiln's own, beside Local, Rclone and S3, built on OTP's
  `:ssh` and `:ssh_sftp`. No plain FTP: it sends credentials in the clear.

  Settings: `host`, `port` (22 when blank), `username`, `path` (absolute);
  secrets: `password` and/or `private_key` (both stored encrypted and never
  shown again). A file is kept as `<path>/<subdir>/<name>`. Where it may
  connect is `KilnCMS.Backups.Destination.Sftp.Target`'s to decide
  (`BACKUP_SFTP_PRIVATE_HOSTS` opens private hosts, ADR 0069); which
  credentials are usable, `KilnCMS.Backups.Destination.Sftp.Credentials`'.

  ## The host key (ADR 0079)

  A destination is trusted to one host key, which a platform admin confirms
  on the Destinations tab (`KilnCMS.Backups.trust_backup_destination_host_key/3`)
  and which is stored on the row, never in its editable settings. Until
  then every call refuses, and the destination can't be enabled. Every
  connection offers only the trusted key's algorithm and checks the key
  before logging in (`KilnCMS.Backups.Destination.Sftp.HostKey`). A key that
  changed fails the destination permanently and raises an instance security
  event and a platform security alert
  (`KilnCMS.Backups.Destination.Sftp.HostKeyAlert`).

  The core passes the trusted key in the config's settings, under
  `"__host_key_algorithm"` and `"__host_key_fingerprint"`
  (`KilnCMS.Backups.DestinationConfig.to_config/1`); no form can set them.

  ## Calls

  Every call parses the settings, pins the host and connects again
  (`KilnCMS.Backups.Destination.Sftp.Session`), and closes the connection
  before it returns, also when it is killed. Uploads resume
  (`KilnCMS.Backups.Destination.Sftp.Upload`); file operations refuse
  symbolic links where Kiln's own files and folders must be
  (`KilnCMS.Backups.Destination.Sftp.Files`).

  `test/1`, behind the form's Test button: connect (which checks the host
  key and the login), create the path where missing, then write, read back
  and delete a probe under `<path>/.kiln-test/`, whatever happened.
  """

  use Kiln.BackupDestination

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.Destination.RemotePath

  alias KilnCMS.Backups.Destination.Sftp.{
    Credentials,
    Errors,
    Files,
    HostKey,
    HostKeyAlert,
    Session,
    Target,
    Upload
  }

  @test_dir ".kiln-test"

  @doc "The settings key the trusted host key's type travels under."
  @spec algorithm_key() :: String.t()
  def algorithm_key, do: "__host_key_algorithm"

  @doc "The settings key the trusted host key's fingerprint travels under."
  @spec fingerprint_key() :: String.t()
  def fingerprint_key, do: "__host_key_fingerprint"

  @impl Kiln.BackupDestination
  def kind, do: "sftp"

  @impl Kiln.BackupDestination
  def label, do: "SFTP server"

  @impl Kiln.BackupDestination
  def fields do
    [
      %{
        name: "host",
        type: :string,
        required?: true,
        help: "The server's host name or IP address, e.g. nas.example.com."
      },
      %{name: "port", type: :integer, required?: false, help: "22 when left blank."},
      %{name: "username", type: :string, required?: true, help: nil},
      %{
        name: "path",
        type: :string,
        required?: true,
        help: "An absolute folder on the server to keep backups in, e.g. /backups/kiln."
      },
      %{name: "password", type: :secret, required?: false, help: nil},
      %{
        name: "private_key",
        type: :secret,
        required?: false,
        help:
          "An OpenSSH or PEM private key without a passphrase (Ed25519, ECDSA or RSA of " <>
            "2048 bits or more). A password, a key, or both."
      }
    ]
  end

  @impl Kiln.BackupDestination
  def supports, do: [:list, :delete, :resume]

  @impl Kiln.BackupDestination
  def validate(%Config{settings: settings, secrets: secrets}) do
    with {:ok, _target} <- Target.parse(settings), do: Credentials.validate(secrets)
  end

  @impl Kiln.BackupDestination
  def test(config) do
    session(config, [], fn session, target ->
      with {:ok, dir} <- Files.ensure_dir(session, target, @test_dir) do
        probe(session, dir)
      end
    end)
  end

  @impl Kiln.BackupDestination
  def put(config, %{subdir: subdir, name: name} = file, opts) do
    with :ok <- RemotePath.safe_ref(subdir, name) do
      session(config, opts, fn session, target -> Upload.put(session, target, file, opts) end)
    end
  end

  @impl Kiln.BackupDestination
  def abort_upload(config, %{subdir: subdir, name: name, checkpoint: checkpoint}, opts) do
    token = (checkpoint || %{})["token"]

    # A token is all that is read from the checkpoint, and only one of 16
    # hex digits: the path is the settings' own.
    with true <- Upload.token?(token),
         :ok <- RemotePath.safe_ref(subdir, name) do
      session(config, opts, fn session, target ->
        Upload.abort(session, target, subdir, name, token)
      end)
    else
      false -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl Kiln.BackupDestination
  def list(config) do
    session(config, [], &list_all/2)
  end

  defp list_all(session, target) do
    Enum.reduce_while(RemotePath.subdirs(), {:ok, []}, fn subdir, {:ok, acc} ->
      case Files.list(session, target, subdir) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @impl Kiln.BackupDestination
  def get(config, %{subdir: subdir, name: name}, to) do
    with :ok <- RemotePath.safe_ref(subdir, name) do
      session(config, [], &download(&1, &2, subdir, name, to))
    end
  end

  @impl Kiln.BackupDestination
  def delete(config, %{subdir: subdir, name: name}) do
    with :ok <- RemotePath.safe_ref(subdir, name) do
      session(config, [], &delete_file(&1, &2, subdir, name))
    end
  end

  defp download(session, target, subdir, name, to) do
    path = Target.file(target, subdir, name)
    with {:ok, _digest} <- Files.download(session, path, to, "#{subdir}/#{name}"), do: :ok
  end

  # A linked subdirectory is refused before the file in it is looked at.
  defp delete_file(session, target, subdir, name) do
    case Files.lstat(session, Target.dir(target, subdir), subdir) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, Files.link(subdir)}

      _dir_or_absent ->
        Files.delete(session, Target.file(target, subdir, name), "#{subdir}/#{name}")
    end
  end

  @impl Kiln.BackupDestination
  def describe(%Config{settings: settings}), do: Target.describe(settings)

  @doc """
  Where `config` writes, normalized for
  `KilnCMS.Backups.Destination.overlap?/2`: `{:sftp, host, port, username,
  segments}` (`Target.location/1`). The host key is no part of it.
  """
  @spec location(Config.t()) :: {:sftp, String.t(), non_neg_integer(), String.t(), [String.t()]}
  def location(%Config{settings: settings}), do: Target.location(settings)

  @doc """
  The host key `config` offers for `type` (or the one it prefers, with
  `nil`), read without logging in: `{:ok, {type, fingerprint}}`. The server
  is sent no credential. Behind the Destinations tab's "Check host key"
  (`KilnCMS.Backups.scan_destination_host_key/2`).

  Options: `:timeout` per connection (10 s).
  """
  @spec scan(Config.t(), String.t() | nil, keyword()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def scan(%Config{settings: settings}, type, opts \\ []) do
    with {:ok, target} <- permanent(Target.parse(settings)) do
      Session.scan(target, type, opts)
    end
  end

  @doc """
  The host key of `config`'s server whose fingerprint is `expected` (as
  `ssh-keygen -lf` prints it): each type Kiln trusts is asked for in turn,
  one connection each, stopping at the first that matches.
  `{:ok, {type, fingerprint}}`, `{:error, :no_match}` when the server
  offers none with that fingerprint, or `{:error, reason}` when it can't be
  reached at all. No credential is sent.
  """
  @spec match(Config.t(), String.t(), keyword()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def match(%Config{} = config, expected, opts \\ []) do
    with {:ok, _target} <- permanent(Target.parse(config.settings)) do
      case HostKey.normalize_fingerprint(expected) do
        {:ok, expected} -> match_types(config, expected, HostKey.types(), opts, :no_match)
        :error -> {:error, {:permanent, "that is not a SHA256 fingerprint"}}
      end
    end
  end

  defp match_types(_config, _expected, [], _opts, last), do: {:error, last}

  defp match_types(config, expected, [type | rest], opts, last) do
    case scan(config, type, opts) do
      {:ok, {^type, fingerprint} = found} ->
        if HostKey.same?(fingerprint, expected),
          do: {:ok, found},
          else: match_types(config, expected, rest, opts, last)

      # A type the server doesn't offer.
      {:error, {:not_offered, ^type}} ->
        match_types(config, expected, rest, opts, last)

      # Unreachable or refused: no other type will fare better.
      {:error, _reason} = error ->
        error
    end
  end

  ## Calls

  defp session(%Config{settings: settings, secrets: secrets} = config, opts, fun) do
    with {:ok, target} <- permanent(Target.parse(settings)),
         {:ok, trusted} <- trusted(settings),
         {:ok, credentials} <- permanent(Credentials.from_secrets(target.username, secrets)) do
      opened =
        Session.with_session(
          target,
          credentials,
          trusted,
          Keyword.take(opts, [:deadline]),
          fn session ->
            fun.(session, target)
          end
        )

      case opened do
        {:error, {:host_key_mismatch, _type, offered}} ->
          {_type, trusted_fingerprint} = trusted
          HostKeyAlert.mismatch(config.id, kind(), offered, trusted_fingerprint)
          {:error, Errors.mismatch(offered, trusted_fingerprint)}

        other ->
          other
      end
    end
  end

  defp trusted(settings) do
    case {settings[algorithm_key()], settings[fingerprint_key()]} do
      {type, fingerprint} when is_binary(type) and is_binary(fingerprint) ->
        {:ok, {type, fingerprint}}

      _none ->
        {:error,
         {:permanent,
          "confirm the server's host key first: a platform admin checks it on the " <>
            "Destinations tab (Check host key)"}}
    end
  end

  defp permanent({:error, message}) when is_binary(message), do: {:error, {:permanent, message}}
  defp permanent(other), do: other

  defp probe(session, dir) do
    hex = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    path = "#{dir}/kiln-test-#{hex}.txt"
    body = "Kiln backup destination test #{hex}\n"

    try do
      with {:ok, handle} <- Files.open(session, path, [:write, :binary], "a test file"),
           :ok <- write_probe(session, handle, body),
           {:ok, handle} <- Files.open(session, path, [:read, :binary], "the test file") do
        read = Files.read_range(session, handle, 0, byte_size(body), "the test file")
        Session.sftp(session, :close, [handle])

        case read do
          {:ok, ^body} -> :ok
          {:ok, _other} -> {:error, "the test file read back differs from what was written"}
          {:error, _reason} = error -> error
        end
      end
    after
      Files.remove(session, path, "the test file")
    end
  end

  defp write_probe(session, handle, body) do
    result = Session.sftp(session, :pwrite, [handle, 0, body])
    closed = Session.sftp(session, :close, [handle])

    case {result, closed} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _closed} -> {:error, Errors.op(:write, "writing a test file", reason)}
      {:ok, {:error, reason}} -> {:error, Errors.op(:write, "writing a test file", reason)}
    end
  end
end
