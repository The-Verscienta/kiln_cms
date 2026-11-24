defmodule KilnCMS.Backups.Command do
  @moduledoc """
  The external commands a backup runs (`pg_dump`, `pg_restore`, `rclone`), run
  the one way they are run: an argv list with no shell interpolation, killed
  with the process that started it, its output scrubbed through
  `KilnCMS.Backups.Redact` before anything keeps it.

  `KilnCMS.Backups.Steps` and the backup destinations
  (`KilnCMS.Backups.Destination.Rclone`) share it, so the off-site copy runs
  the same command, with the same environment and the same error, whichever
  of them starts it (#2220).
  """

  alias KilnCMS.Backups.Redact
  alias KilnCMS.ExternalCommand

  @typedoc """
  Why a command failed: it isn't installed, or it exited non-zero with its
  (redacted, at most 500 characters) output.
  """
  @type error ::
          {String.t(), :enoent}
          | {:exit_status, String.t(), non_neg_integer() | :timeout, String.t()}

  # An argv list with no shell interpolation (`ExternalCommand` passes it to
  # its fixed wrapper positionally, as `"$@"`), so nothing here can be
  # injected into even though the database URL carries a password.
  #
  # `ExternalCommand`, not `System.cmd/3`: a job killed mid-run (timeout,
  # cancel, a fenced node) must take `pg_dump`/`rclone` down with it rather
  # than leave it writing a `.partial` a retry collides with. No wall-clock
  # bound of its own; the job's timeout is the bound.
  #
  # stderr is captured rather than inherited so a failure can be reported with
  # its actual reason. It is NOT logged verbatim: `pg_dump`'s error output can
  # echo the connection string, and a backup failure should not put the
  # database password in the log.
  @doc """
  Runs `executable` with `args` and the `[{var, value}]` environment `env`.
  `:ok` on exit status 0, else `{:error, reason}` with the output redacted
  (see `t:error/0`).
  """
  @spec cmd(String.t(), [String.t()], [{String.t(), String.t()}]) :: :ok | {:error, error()}
  def cmd(executable, args, env \\ []) do
    # `rclone` arrives as an absolute path, `pg_dump`/`pg_restore` by name;
    # `System.find_executable/1` resolves both (`:spawn_executable` searches
    # no `PATH`).
    case System.find_executable(executable) do
      nil ->
        {:error, {executable, :enoent}}

      exe ->
        case ExternalCommand.run(exe, args, :infinity, env: env) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:exit_status, executable, status, redact(output, env)}}
        end
    end
  end

  @doc """
  `cmd/3` for a command whose output is the answer (`rclone lsjson`, `rclone
  cat`): `{:ok, output}` on exit status 0. The output is returned as the
  command wrote it, stderr included, and is not redacted: it is data for the
  caller to parse, never text to show. A failure is redacted as in `cmd/3`.
  """
  @spec output(String.t(), [String.t()], [{String.t(), String.t()}]) ::
          {:ok, binary()} | {:error, error()}
  def output(executable, args, env \\ []) do
    case System.find_executable(executable) do
      nil ->
        {:error, {executable, :enoent}}

      exe ->
        case ExternalCommand.run(exe, args, :infinity, env: env) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:exit_status, executable, status, redact(output, env)}}
        end
    end
  end

  # This string reaches the manifest, which the console renders.
  #
  # The scrubbing itself (known secrets, URL userinfo, `key=value`) lives in
  # `KilnCMS.Backups.Redact`, the single path every backup text goes through
  # (#2217); this just bounds the diagnostic to 500 characters.
  defp redact(output, env), do: Redact.text(output, env, 500)
end
