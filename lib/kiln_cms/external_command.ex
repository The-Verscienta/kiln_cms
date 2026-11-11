defmodule KilnCMS.ExternalCommand do
  @moduledoc """
  Run an external binary under a **wall-clock** deadline that can actually stop
  it.

  Two modules hand a user-supplied file to a foreign program — `qpdf` in
  `KilnCMS.DocumentProcessor` and `ffmpeg`/`ffprobe` in `KilnCMS.AVProcessor` —
  and both need the same containment. This is that containment, in one place,
  because the two got it in different orders: the PDF path grew a real timeout
  in #918 while the A/V path was still on `System.cmd/3`, which has none (#1100).
  The backup pipeline's `pg_dump`, `pg_restore`, `rclone` and `tar` run here too
  (#2218), for the other half of the containment: a child that must not outlive
  a caller killed mid-run.

  ## Why a port rather than `System.cmd/3`

  `System.cmd/3` cannot be interrupted at all: it blocks until the child exits.
  Nor can an enclosing `Task.shutdown/2` or Oban job timeout help — **closing an
  Erlang port shuts the pipes but sends the OS child no signal**, so a program
  spinning on CPU or blocked on a slow disk outlives every one of them. Only a
  port hands back the child's OS pid, and only that pid can be signalled.

  So the deadline here is enforced the one way that reaches the process: wait
  `timeout_ms`, then `kill -9` the pid.

  ## The three details that are easy to get wrong

    * **`acc` is an iodata list, not a binary.** `acc <> chunk` in a receive
      loop is quadratic — it reallocates everything accumulated per chunk —
      which on a large `--json-output` dump was the difference between tens of
      megabytes and most of a gigabyte resident, in the LiveView process
      handling the upload.

    * **The deadline is absolute, not per-message.** A `receive ... after` that
      is re-entered with the full timeout resets on every chunk, so a slow but
      chatty child can outlive its budget indefinitely.

    * **The mailbox is drained.** `Port.close/1` stops further delivery but does
      not purge what the port already sent, and this runs in the caller's
      process — `KilnCMSWeb.MediaLive` has no catch-all `handle_info/2`, so one
      stray `{port, {:data, _}}` left behind crashes the editor's media page
      instead of showing them the refusal.

  Returns `{output, status}`, mirroring `System.cmd/3`'s shape, where `status`
  is the child's exit code or `:timeout` when the deadline killed it. `output`
  is stdout and stderr interleaved, so a failure can be logged with its actual
  reason rather than a bare status code.
  """

  @doc """
  Exec `exe` with `args`, giving it at most `timeout_ms` of wall clock.

  `exe` must be an absolute path — a `System.find_executable/1` result — since
  `:spawn_executable` does not search `PATH`.

  `timeout_ms` may be `:infinity` for a caller that is bounded some other way
  (an Oban job timeout). That bound kills the *caller*, which is why the
  caller-death watcher below exists.

  ## Options

    * `:env` — `[{name, value}]` added to the child's environment, as
      `System.cmd/3`'s `:env`. The place for a secret that must not sit in argv
      (`/proc/<pid>/cmdline` is world-readable).
    * `:tail` — keep only the last this-many bytes of output instead of all of
      it, for a child whose output is unbounded (a `tar` listing).

  ## The caller dying

  The port is linked to the caller, so a caller killed mid-run (a job timeout,
  `Oban.cancel_job/1`, a supervisor shutdown) closes it — and closing a port
  signals nothing. A watcher process *outside* the caller's link set monitors
  it and `kill -9`s the OS pid if the caller dies before the child exits, so
  the child cannot go on writing a file a retry then collides with.
  """
  # `Port.open/2` with `:spawn_executable` execs directly rather than through a
  # shell, so neither the program nor the argument list can be injected into.
  # Even a hostile *filename* arrives as one exec argv entry, not shell syntax.
  @spec run(Path.t(), [String.t()], timeout(), keyword()) ::
          {binary(), non_neg_integer() | :timeout}
  def run(exe, args, timeout_ms, opts \\ [])
      when is_binary(exe) and is_list(args) and is_list(opts) and
             (timeout_ms == :infinity or (is_integer(timeout_ms) and timeout_ms > 0)) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:env, port_env(Keyword.get(opts, :env, []))}
      ])

    os_pid = os_pid(port)
    watcher = watch(os_pid)
    deadline = deadline(timeout_ms)
    timed_out = "#{Path.basename(exe)} timed out after #{timeout_ms}ms"
    tail = Keyword.get(opts, :tail)

    try do
      collect(port, os_pid, empty(tail), deadline, timed_out, tail)
    after
      send(watcher, :done)
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _closed -> nil
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  # `System.cmd/3` takes strings; a port takes charlists.
  defp port_env(env) do
    for {name, value} <- env, do: {String.to_charlist(name), String.to_charlist(value)}
  end

  # A process that is not linked to the caller, so it outlives a caller killed
  # with an untrappable exit, and kills the OS child when that happens.
  defp watch(nil), do: spawn(fn -> :ok end)

  defp watch(os_pid) do
    caller = self()

    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        :done -> :ok
        {:DOWN, ^ref, :process, _pid, _reason} -> kill(os_pid)
      end
    end)
  end

  defp empty(nil), do: []
  defp empty(_tail), do: ""

  defp collect(port, os_pid, acc, deadline, timed_out, tail) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, os_pid, append(acc, chunk, tail), deadline, timed_out, tail)

      {^port, {:exit_status, code}} ->
        {IO.iodata_to_binary(acc), code}
    after
      remaining(deadline) ->
        kill(os_pid)
        close(port)
        drain(port)
        {timed_out, :timeout}
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp append(acc, chunk, nil), do: [acc | chunk]

  defp append(acc, chunk, tail) do
    bin = acc <> chunk

    if byte_size(bin) <= tail,
      do: bin,
      else: binary_part(bin, byte_size(bin) - tail, tail)
  end

  defp drain(port) do
    receive do
      {^port, _anything} -> drain(port)
    after
      0 -> :ok
    end
  end

  # SIGKILL, because the point is that the process stops now: it is holding CPU
  # or disk on work the caller has already given up on, and none of qpdf,
  # ffmpeg, pg_dump, tar or rclone has cleanup worth waiting for. Closing the
  # port does not signal it. A pid that already exited is not an error.
  #
  # `os_pid` is an integer from `Port.info/2`, never caller input.
  # sobelow_skip ["CI.System"]
  defp kill(nil), do: :ok

  defp kill(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    # No `kill` binary on PATH. The child is orphaned rather than stopped, which
    # is worse than killing it and better than crashing the caller — the
    # deadline itself still holds, which is what the caller is waiting on.
    _error -> :ok
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    # Already closed because the child exited in the race with the timeout.
    ArgumentError -> :ok
  end
end
