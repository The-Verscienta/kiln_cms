defmodule KilnCMS.Backups.Destination.Sftp.Errors do
  @moduledoc """
  What an SFTP destination's failures mean, and how they are said (#2222).

  A fixed table: no text the server sent is ever repeated, since a hostile
  or broken server could put anything in it. Each failure is either
  **permanent** (`{:permanent, message}`: the off-site step fails the
  destination at once) or worth retrying (a plain message):

    * permanent — the login or key refused, the host key changed or not yet
      confirmed, an algorithm the server no longer offers, permission
      denied, no space or over quota, a path that can't be created, and an
      SFTP `FAILURE` on a rename, remove, mkdir or setstat of Kiln's own
      paths;
    * retried — refused, timed out, closed or unreachable connections, a
      `FAILURE` on connect, read or write, and anything unknown.

  `:no_such_file` is the caller's to decide (absent is success for a
  delete, an empty listing for a missing subdirectory).
  """

  alias KilnCMS.Backups.Destination.Sftp.HostKey

  @transient_connect [
    :econnrefused,
    :econnreset,
    :timeout,
    :etimedout,
    :closed,
    :ehostunreach,
    :enetunreach,
    :ehostdown,
    :enetdown,
    :nxdomain,
    :connection_start_timeout
  ]

  @doc """
  A connection failure as `Session.open/4` answers it. `offered` is the
  host key the server presented, when it got that far.
  """
  @spec connect_reason(term(), {String.t(), String.t()} | nil, tuple()) :: term()
  # The key checked out: what failed after it is classified as any other
  # failure, so a connection dropped or timed out mid-login stays worth
  # retrying (and a recorded upload is kept, ADR 0068); only a refused login
  # is permanent.
  def connect_reason(reason, {type, fingerprint}, {:verify, trusted_type, trusted} = mode) do
    if type == trusted_type and HostKey.same?(fingerprint, trusted),
      do: connect_reason(reason, nil, mode),
      else: {:host_key_mismatch, type, fingerprint}
  end

  def connect_reason(_reason, offered, {:scan, _type}) when offered != nil,
    do: {:scanned, offered}

  def connect_reason(reason, nil, mode) when is_atom(reason) do
    if reason in @transient_connect,
      do: "couldn't connect to the server (#{connect_atom(reason)})",
      else: unknown_connect(mode)
  end

  def connect_reason(reason, nil, mode) when is_list(reason) or is_binary(reason) do
    text = reason |> to_string() |> String.downcase()

    cond do
      # OTP says only "Key exchange failed" when no algorithm is shared (the
      # detail goes to its log): with host keys limited to one type, that
      # type is the likely one.
      String.contains?(text, ["no common", "key exchange failed"]) ->
        no_common_host_key(mode)

      String.contains?(text, "authentication") ->
        {:permanent, "the server refused the username and credentials"}

      true ->
        unknown_connect(mode)
    end
  end

  def connect_reason(_reason, nil, mode), do: unknown_connect(mode)

  defp no_common_host_key({:verify, type, _fingerprint}),
    do:
      {:permanent,
       "the server no longer offers its trusted #{type} host key, or no algorithm Kiln " <>
         "accepts (Kiln refuses SHA-1); if its key changed, a platform admin checks and " <>
         "trusts its new key"}

  # A scan for one type: the caller asks for the next.
  defp no_common_host_key({:scan, type}) when is_binary(type), do: {:not_offered, type}

  defp no_common_host_key(_mode),
    do:
      {:permanent, "the server offers no host key or algorithm Kiln accepts (Kiln refuses SHA-1)"}

  defp unknown_connect(_mode), do: "couldn't connect to the server"

  defp connect_atom(:econnrefused), do: "connection refused"
  defp connect_atom(:econnreset), do: "connection reset"
  defp connect_atom(reason) when reason in [:timeout, :etimedout], do: "timed out"
  defp connect_atom(:closed), do: "connection closed"
  defp connect_atom(:nxdomain), do: "the name doesn't resolve"
  defp connect_atom(_unreachable), do: "unreachable"

  @doc """
  How `KilnCMS.Backups.Retry` treats a connection failure: a string is
  worth retrying; anything else is answered at once.
  """
  @spec connect_class(term()) :: :transient | :permanent
  def connect_class(reason) when is_binary(reason), do: :transient
  def connect_class(_reason), do: :permanent

  @doc "The host-key mismatch, as the destination's error."
  @spec mismatch(String.t(), String.t()) :: {:permanent, String.t()}
  def mismatch(offered, trusted),
    do:
      {:permanent,
       "the server's host key changed (offered #{offered}, trusted #{trusted}); " <>
         "if the change is expected, a platform admin checks and trusts the new key"}

  @doc """
  An SFTP operation's failure, said for `what` (`"writing db/x.dump"`).
  `op` is `:connect`, `:read`, `:write` (where an SFTP `FAILURE` is
  retried) or `:change` (rename, remove, mkdir, setstat: permanent).
  """
  @spec op(atom(), String.t(), term()) :: String.t() | {:permanent, String.t()}
  def op(op, what, reason)

  def op(_op, what, :permission_denied),
    do: {:permanent, "#{what}: permission denied on the server"}

  def op(_op, what, reason) when reason in [:no_space_on_filesystem, :quota_exceeded],
    do: {:permanent, "#{what}: the server is out of space or over its quota"}

  def op(_op, what, :no_such_path),
    do: {:permanent, "#{what}: the folder doesn't exist and couldn't be created"}

  def op(_op, what, reason) when reason in [:no_such_file, :not_a_directory],
    do: {:permanent, "#{what}: a folder in the path is missing or not a folder"}

  def op(_op, what, :op_unsupported),
    do: {:permanent, "#{what}: the server doesn't support this operation"}

  def op(:change, what, :failure),
    do: {:permanent, "#{what}: the server refused (SFTP failure)"}

  def op(_op, what, :file_already_exists), do: "#{what}: the file already exists"

  def op(_op, what, reason) when reason in [:timeout, :closed, :connection_lost, :no_connection],
    do: "#{what}: the connection was lost or timed out"

  def op(_op, what, _reason), do: "#{what}: the server reported an error"
end
