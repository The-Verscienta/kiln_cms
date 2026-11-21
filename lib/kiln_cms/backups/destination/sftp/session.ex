defmodule KilnCMS.Backups.Destination.Sftp.Session do
  @moduledoc """
  One SFTP connection of a call (#2222): opened to the pinned address,
  checked against the trusted host key before anything is sent, and closed
  whatever happens to the process that opened it.

  ## Connecting

  The host is pinned first (`Target.pin/2`, ADR 0069); the TCP socket is
  opened here, to that address, and handed to `:ssh.connect/3`, so the name
  is never resolved twice. The connection:

    * offers only the trusted key's host key algorithms (an RSA key with
      `rsa-sha2-512`/`rsa-sha2-256` only) and no SHA-1 key exchange;
    * checks the offered key in `HostKey.is_host_key/5` before user
      authentication, so a server presenting another key gets no password
      and no signature;
    * never asks anyone anything: `user_interaction: false`,
      `silently_accept_hosts: false`, `save_accepted_host: false`;
    * tries `publickey` and `password` only, never keyboard-interactive.

  A connection is retried up to three times on a transient failure (refused,
  timed out, unreachable), within the call's deadline
  (`KilnCMS.Backups.Retry`); a refused login or key is not retried.

  ## The guard

  `KilnCMS.Backups.Destination.call/4` kills the process running an adapter
  when a deadline passes or a backup is canceled. OTP's connection lives
  under its own supervisor (`sshc_sup`) and would outlive that process, so a
  guard, linked to it and trapping exits, closes the socket and the
  connection when it goes. The socket is registered with the guard before
  the handshake starts, so a call killed mid-handshake leaves nothing open.

  ## Time

  Connecting and the SSH negotiation get `min(15 s, deadline − now)`; each
  file operation `min(60 s, deadline − now)`, at least one second. A call
  with no deadline (list, get, delete under retention's own bound) gets 60 s
  per operation.
  """

  alias KilnCMS.Backups.Destination.Sftp.{Credentials, Errors, HostKey, Target}
  alias KilnCMS.Backups.Retry

  @enforce_keys [:conn, :channel, :guard]
  defstruct [:conn, :channel, :guard, :deadline]

  @type t :: %__MODULE__{
          conn: pid(),
          channel: pid(),
          guard: pid(),
          deadline: integer() | nil
        }

  # Only `conn` and `channel` pids: nothing of the credentials is kept here.
  defimpl Inspect do
    def inspect(%{conn: conn}, _opts), do: "#Session<#{Kernel.inspect(conn)}>"
  end

  @connect_ms :timer.seconds(15)
  @op_ms :timer.seconds(60)
  @min_ms :timer.seconds(1)
  @connect_attempts 3

  @doc """
  Connects to `target` as `credentials`, trusting only `trusted`
  (`{type, fingerprint}`), and opens an SFTP channel.

  `{:ok, session}`, or `{:error, reason}` where reason is one of:

    * `{:host_key_mismatch, type, fingerprint}` — the server offered
      another key (what it offered);
    * `{:permanent, message}` — a refused login, an algorithm the server no
      longer offers, a refused address;
    * `:deadline` — no time left to try again;
    * a message string — a failure worth retrying.

  Options: `:deadline`.
  """
  @spec open(Target.t(), Credentials.t(), {String.t(), String.t()}, keyword()) ::
          {:ok, t()} | {:error, term()}
  def open(%Target{} = target, %Credentials{} = credentials, {type, fingerprint}, opts \\ []) do
    deadline = Keyword.get(opts, :deadline)

    with {:ok, address} <- pin(target) do
      guard = guard(self())
      mode = {:verify, type, fingerprint}

      connected =
        Retry.run(
          fn -> connect(target, address, credentials, mode, guard, deadline) end,
          &Errors.connect_class/1,
          retry_opts(deadline)
        )

      with {:ok, conn} <- connected,
           {:ok, channel} <- channel(conn, deadline) do
        {:ok, %__MODULE__{conn: conn, channel: channel, guard: guard, deadline: deadline}}
      else
        {:error, reason} ->
          release(guard)
          {:error, reason}
      end
    end
  end

  @doc """
  Connects to `target` without credentials and reports the host key it
  offers for `type` (or for whatever it prefers, with `nil`), refusing it,
  so nothing is ever sent: `{:ok, {type, fingerprint}}` or
  `{:error, reason}`.

  Options: `:timeout` (10 s), the bound on the whole connection.
  """
  @spec scan(Target.t(), String.t() | nil, keyword()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def scan(%Target{} = target, type, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 10_000)

    with {:ok, address} <- pin(target) do
      guard = guard(self())
      credentials = %Credentials{username: "kiln", key_algorithms: []}

      try do
        case connect(target, address, credentials, {:scan, type}, guard, deadline) do
          {:error, {:scanned, offered}} -> {:ok, offered}
          {:ok, conn} -> refuse_open(conn)
          {:error, reason} -> {:error, reason}
        end
      after
        release(guard)
      end
    end
  end

  # A server that let a login with no credentials in: never trusted for
  # anything, and the scan ends there.
  defp refuse_open(conn) do
    close_conn(conn)
    {:error, {:permanent, "the server accepted a login with no credentials"}}
  end

  @doc "Closes the channel and the connection, and lets the guard go."
  @spec close(t()) :: :ok
  def close(%__MODULE__{conn: conn, channel: channel, guard: guard}) do
    _ = safely(fn -> :ssh_sftp.stop_channel(channel) end)
    close_conn(conn)
    release(guard)
    :ok
  end

  @doc """
  Runs `fun` with an open session to `target` and closes it after, whatever
  `fun` answers or raises.
  """
  @spec with_session(Target.t(), Credentials.t(), {String.t(), String.t()}, keyword(), (t() ->
                                                                                          result)) ::
          result | {:error, term()}
        when result: term()
  def with_session(target, credentials, trusted, opts, fun) do
    with {:ok, session} <- open(target, credentials, trusted, opts) do
      try do
        fun.(session)
      after
        close(session)
      end
    end
  end

  @doc "The time one file operation may take now. See the moduledoc."
  @spec op_timeout(t() | integer() | nil) :: pos_integer()
  def op_timeout(%__MODULE__{deadline: deadline}), do: op_timeout(deadline)
  def op_timeout(nil), do: @op_ms
  def op_timeout(deadline), do: bounded(deadline, @op_ms)

  @doc """
  `:ssh_sftp.<fun>` on the session's channel with `args` and the operation's
  timeout appended: `sftp(session, :read_link_info, [path])`.
  """
  @spec sftp(t(), atom(), list()) :: term()
  def sftp(%__MODULE__{channel: channel} = session, fun, args),
    do: apply(:ssh_sftp, fun, [channel | args] ++ [op_timeout(session)])

  ## Connecting

  defp pin(target) do
    case Target.pin(target) do
      {:ok, nil} -> {:ok, String.to_charlist(target.host)}
      {:ok, address} -> {:ok, address}
      {:error, {:permanent, _message}} = refused -> refused
      {:error, message} -> {:error, message}
    end
  end

  defp retry_opts(nil), do: [attempts: @connect_attempts, margin_ms: 0]

  defp retry_opts(deadline),
    do: [attempts: @connect_attempts, deadline: deadline, margin_ms: @min_ms]

  defp connect(target, address, credentials, mode, guard, deadline) do
    timeout = bounded(deadline, @connect_ms)

    # Passive and in list mode, as `:ssh.connect/4` opens its own: OTP's
    # handshake reads the version line from a list-mode socket and stalls
    # on a binary one.
    case :gen_tcp.connect(address, target.port, [active: false], timeout) do
      {:ok, socket} ->
        send(guard, {:socket, socket})
        handshake(socket, credentials, mode, guard, timeout)

      {:error, reason} ->
        {:error, Errors.connect_reason(reason, nil, mode)}
    end
  end

  defp handshake(socket, credentials, mode, guard, timeout) do
    tag = make_ref()

    result =
      try do
        :ssh.connect(socket, options(credentials, mode, tag), timeout)
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    offered =
      receive do
        {^tag, :offered, type, fingerprint} -> {type, fingerprint}
      after
        0 -> nil
      end

    case result do
      {:ok, conn} ->
        send(guard, {:conn, conn})
        {:ok, conn}

      {:error, reason} ->
        _ = safely(fn -> :gen_tcp.close(socket) end)
        {:error, Errors.connect_reason(reason, offered, mode)}
    end
  end

  # No SHA-1 key exchange; host keys of the trusted type only. Every other
  # algorithm class keeps OTP's defaults.
  defp options(credentials, mode, tag) do
    private =
      [mode: mode, reply_to: self(), tag: tag] ++
        if(credentials.key, do: [user_key: credentials.key], else: [])

    [
      user: String.to_charlist(credentials.username),
      key_cb: {HostKey, private},
      user_interaction: false,
      silently_accept_hosts: false,
      save_accepted_host: false,
      quiet_mode: true,
      auth_methods: auth_methods(credentials),
      preferred_algorithms: [kex: kex(), public_key: host_algorithms(mode)],
      idle_time: :timer.minutes(5)
    ]
    |> put_password(credentials)
    |> put_key_algorithms(credentials)
  end

  defp auth_methods(%{key: key, password: password}) do
    [if(key, do: "publickey"), if(password, do: "password")]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ~c"publickey"
      methods -> methods |> Enum.join(",") |> String.to_charlist()
    end
  end

  # A charlist option, unlike the key: OTP has no other way to take it. It
  # sits in the connection's state like the vault key sits in this node's.
  defp put_password(options, %{password: password}) when is_binary(password),
    do: [{:password, String.to_charlist(password)} | options]

  defp put_password(options, _credentials), do: options

  defp put_key_algorithms(options, %{key: key, key_algorithms: [_ | _] = algorithms})
       when is_function(key, 0),
       do: [{:pref_public_key_algs, supported(algorithms, :public_key)} | options]

  defp put_key_algorithms(options, _credentials), do: options

  defp host_algorithms({:verify, type, _fingerprint}),
    do: supported(HostKey.algorithms(type), :public_key)

  defp host_algorithms({:scan, nil}),
    do: supported(Enum.flat_map(HostKey.types(), &HostKey.algorithms/1), :public_key)

  defp host_algorithms({:scan, type}), do: supported(HostKey.algorithms(type), :public_key)

  defp kex do
    :ssh.default_algorithms()
    |> Keyword.fetch!(:kex)
    |> Enum.reject(&String.contains?(Atom.to_string(&1), "sha1"))
  end

  defp supported(algorithms, class) do
    available = Keyword.fetch!(:ssh.default_algorithms(), class)

    case Enum.filter(algorithms, &(&1 in available)) do
      [] -> algorithms
      supported -> supported
    end
  end

  defp channel(conn, deadline) do
    timeout = bounded(deadline, @connect_ms)

    case safely(fn -> :ssh_sftp.start_channel(conn, timeout: timeout) end) do
      {:ok, channel} -> {:ok, channel}
      _error -> {:error, "the server didn't open an SFTP session (is the SFTP subsystem on?)"}
    end
  end

  defp bounded(nil, cap), do: cap

  defp bounded(deadline, cap),
    do: max(@min_ms, min(cap, deadline - System.monotonic_time(:millisecond)))

  defp close_conn(conn) do
    _ = safely(fn -> :ssh.close(conn) end)
    :ok
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> {:error, :closed}
  catch
    :exit, _reason -> {:error, :closed}
  end

  ## The guard

  defp guard(owner) do
    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      ref = Process.monitor(owner)
      watch(owner, ref, nil, nil)
    end)
  end

  defp release(guard) do
    send(guard, :release)
    :ok
  end

  defp watch(owner, ref, socket, conn) do
    receive do
      {:socket, socket} ->
        watch(owner, ref, socket, conn)

      {:conn, conn} ->
        watch(owner, ref, socket, conn)

      :release ->
        :ok

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        clean_up(socket, conn)

      {:EXIT, ^owner, _reason} ->
        clean_up(socket, conn)
    end
  end

  defp clean_up(socket, conn) do
    if conn, do: close_conn(conn)
    if socket, do: safely(fn -> :gen_tcp.close(socket) end)
    :ok
  end
end
