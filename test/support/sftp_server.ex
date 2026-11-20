defmodule KilnCMS.Test.SftpServer do
  @moduledoc """
  A real SFTP server for the SFTP destination's tests (#2222): OTP's own
  `:ssh` daemon with `:ssh_sftpd`, on `127.0.0.1` and a free port, serving a
  temporary directory, with a host key of its own made per server.

  It behaves like OpenSSH's `sftp-server` where that matters: a write over
  256 KiB is refused (`sftp-server` ends the session), and reads answer at
  most 48 KiB, so a client that doesn't loop on short reads fails.

  Every authentication attempt is reported to the test process as
  `{:sftp_auth, method, user}`, and every write's size as
  `{:sftp_write, bytes}`, so a test can assert that no credential reached
  the server, or that no write was too large.

  Start with `start!/1`; stop with `stop/1` (the `on_exit` is the caller's).
  """

  alias KilnCMS.Backups.Destination.Sftp.HostKey

  @user "kiln"
  @password "correct horse battery"

  defmodule KeyCb do
    @moduledoc false
    @behaviour :ssh_server_key_api

    @impl :ssh_server_key_api
    def host_key(algorithm, options) do
      key = options[:key_cb_private][:host_key]

      if :ssh_transport.valid_key_sha_alg(:private, key, algorithm),
        do: {:ok, key},
        else: {:error, :no_key}
    end

    @impl :ssh_server_key_api
    def is_auth_key(public_key, user, options) do
      private = options[:key_cb_private]
      send(private[:test], {:sftp_auth, :publickey, to_string(user)})
      public_key == private[:authorized]
    end
  end

  defmodule Files do
    @moduledoc false
    @behaviour :ssh_sftpd_file_api

    @max_message 256 * 1024
    @short_read 48 * 1024

    @impl true
    def close(io, test), do: {:ssh_sftpd_file.close(io, []) |> elem(0), test}
    @impl true
    def delete(path, test), do: {:ssh_sftpd_file.delete(path, []) |> elem(0), test}
    @impl true
    def del_dir(path, test), do: {:ssh_sftpd_file.del_dir(path, []) |> elem(0), test}
    @impl true
    def get_cwd(test), do: {:ssh_sftpd_file.get_cwd([]) |> elem(0), test}
    @impl true
    def is_dir(path, test), do: {:ssh_sftpd_file.is_dir(path, []) |> elem(0), test}
    @impl true
    def list_dir(path, test), do: {:ssh_sftpd_file.list_dir(path, []) |> elem(0), test}
    @impl true
    def make_dir(path, test), do: {:ssh_sftpd_file.make_dir(path, []) |> elem(0), test}

    @impl true
    def make_symlink(a, b, test),
      do: {:ssh_sftpd_file.make_symlink(a, b, []) |> elem(0), test}

    @impl true
    def open(path, flags, test), do: {:ssh_sftpd_file.open(path, flags, []) |> elem(0), test}

    @impl true
    def position(io, offset, test),
      do: {:ssh_sftpd_file.position(io, offset, []) |> elem(0), test}

    # As OpenSSH: a read answers at most so much, however much was asked.
    @impl true
    def read(io, length, test),
      do: {:ssh_sftpd_file.read(io, min(length, @short_read), []) |> elem(0), test}

    @impl true
    def read_link(path, test), do: {:ssh_sftpd_file.read_link(path, []) |> elem(0), test}

    @impl true
    def read_link_info(path, test),
      do: {:ssh_sftpd_file.read_link_info(path, []) |> elem(0), test}

    @impl true
    def read_file_info(path, test),
      do: {:ssh_sftpd_file.read_file_info(path, []) |> elem(0), test}

    @impl true
    def rename(from, to, test) do
      # As `ssh_sftpd`: an existing target is refused, so the client's
      # delete-then-rename path is the one exercised.
      if File.exists?(to),
        do: {{:error, :eexist}, test},
        else: {:ssh_sftpd_file.rename(from, to, []) |> elem(0), test}
    end

    # As OpenSSH: a message over 256 KiB ends nothing here, but is refused.
    @impl true
    # The state is `{test_pid, write_delay_ms}`.
    def write(io, data, {test, delay} = state) do
      bytes = IO.iodata_length(data)
      send(test, {:sftp_write, bytes})
      if delay > 0, do: Process.sleep(delay)

      if bytes > @max_message,
        do: {{:error, :einval}, state},
        else: {:ssh_sftpd_file.write(io, data, []) |> elem(0), state}
    end

    @impl true
    def write_file_info(path, info, test),
      do: {:ssh_sftpd_file.write_file_info(path, info, []) |> elem(0), test}
  end

  @doc "The username the server accepts."
  def user, do: @user

  @doc "The password the server accepts."
  def password, do: @password

  @doc """
  Starts a server for the calling test. Options: `:host_key` (a private key;
  a fresh Ed25519 one by default), `:root` (a fresh temporary directory by
  default), `:write_delay_ms` (a pause in every write, to hold an upload
  mid-file). Returns a map: `daemon`, `port`, `root`, `host_key`, `type`,
  `fingerprint`, and `client_key`, the PEM of a key the server authorizes.
  """
  def start!(opts \\ []) do
    Application.ensure_all_started(:ssh)

    test = self()
    host_key = Keyword.get_lazy(opts, :host_key, fn -> ed25519() end)
    client = ed25519()
    root = Keyword.get_lazy(opts, :root, &tmp_dir/0)
    system_dir = tmp_dir()

    pwdfun = fn user, password ->
      send(test, {:sftp_auth, :password, to_string(user)})
      to_string(user) == @user and to_string(password) == @password
    end

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        system_dir: String.to_charlist(system_dir),
        key_cb: {KeyCb, host_key: host_key, authorized: public(client), test: test},
        pwdfun: pwdfun,
        auth_methods: ~c"publickey,password",
        subsystems: [
          :ssh_sftpd.subsystem_spec(
            root: String.to_charlist(root),
            cwd: ~c"/",
            file_handler: {Files, {test, Keyword.get(opts, :write_delay_ms, 0)}}
          )
        ]
      )

    {:ok, info} = :ssh.daemon_info(daemon)

    %{
      daemon: daemon,
      port: Keyword.fetch!(info, :port),
      root: root,
      host_key: host_key,
      type: HostKey.type(public(host_key)),
      fingerprint: HostKey.fingerprint(public(host_key)),
      client_key: pem(client)
    }
  end

  @doc "Stops the server and removes its directory."
  def stop(%{daemon: daemon, root: root}) do
    :ssh.stop_daemon(daemon)
    File.rm_rf(root)
    :ok
  end

  @doc "A fresh Ed25519 private key."
  def ed25519, do: :public_key.generate_key({:namedCurve, :ed25519})

  @doc "The public half of an EC (Ed25519 included) private key."
  def public(key) when elem(key, 0) == :ECPrivateKey,
    do: {{:ECPoint, elem(key, 4)}, elem(key, 3)}

  @doc "A private key as an unencrypted PKCS#8 PEM."
  def pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "kiln-sftp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
