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
  spinning on CPU or blocked on a slow disk outlives every one of them.

  ## How the child is stopped: a group kill from inside

  The BEAM never signals the child by pid. A pid is only safe to signal while
  its parent has not reaped it, and the child's parent is the VM's
  `erl_child_setup`, which reaps it *before* the port's `{:exit_status, _}`
  reaches the caller. Any kill sent from here by number (on a deadline, or from
  a process watching the caller) can therefore land after the pid was freed,
  and on a reused pid that belongs to an unrelated process (#2624).

  Instead the port runs a fixed `/bin/sh` wrapper (`@wrapper` below) that
  starts the program as its own background child and a second background
  "stdin watcher". The watcher blocks reading the port's stdin pipe. The pipe
  reaches end-of-file only when the port closes, which happens when:

    * the deadline passes (`run/4` closes the port);
    * the caller dies (the port is linked to it);
    * the VM itself goes down (the OS closes the pipe).

  At end-of-file the watcher runs `kill -KILL 0`: SIGKILL to its own process
  group, which is the wrapper, the program, the program's own children, and
  the watcher itself. The port's child is a process-group leader (the wrapper
  checks this at start and refuses with status 125 otherwise), and a group id
  cannot be reused while any member of the group is alive, so the signal
  cannot reach a process outside the group. When the program exits first, the
  wrapper kills the watcher, which is its own unreaped child, and exits with
  the program's status.

  Everything the wrapper runs is a shell builtin (`kill`, `read`, `wait`,
  `exec`), so the kill needs no binary on `PATH`. The program and its
  arguments are passed positionally and expanded as `"$@"`: nothing is
  interpolated into shell syntax, so even a hostile *filename* arrives as one
  argv entry.

  Guarantees, and their limits:

    * No signal is ever sent to a pid that may have been reused.
    * The program and every process it starts in its group are killed when
      the deadline passes, the caller dies, or the VM exits.
    * The kill is **asynchronous**: `run/4` returns `:timeout` as soon as it
      has closed the port, and the group is gone a moment later (well under a
      millisecond on Linux, a few milliseconds on macOS). A caller that cleans
      up the program's output file right after a timeout can, in that window,
      race one last write.
    * A program that leaves the group (`setsid`, daemonizing) is not killed.
      None of the callers' programs do.

  ## Behavior a caller can see

    * The program's stdin is `/dev/null`; a read gets end-of-file at once.
    * A program killed by a signal reports `128 + signal` (137 for SIGKILL),
      as a direct port child does.
    * A missing `exe` returns status 127 and a non-executable one 126, with
      the shell's message as the output, rather than raising from
      `Port.open/2`. Every caller resolves `exe` with
      `System.find_executable/1` first.
    * Like any background job of a non-interactive shell, the program starts
      with SIGINT and SIGQUIT ignored.
    * Each run costs two small extra `sh` processes (the wrapper and the
      watcher).

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

  # Never write to the port (`Port.command/2`): the program never sees its
  # stdin, and a write after the wrapper has closed its copy of the pipe fails
  # with an `:epipe` exit. The watcher reads only to see end-of-file.
  #
  # fd 3 keeps the port's stdin for the watcher; fd 4 keeps the port's output
  # for the program's stderr. The wrapper's own stdin and stderr become
  # /dev/null so the shell's "Killed" job notices cannot reach the output.
  @wrapper ~S"""
  exec 3<&0 4>&2 </dev/null 2>/dev/null
  kill -0 -"$$" || { echo "kiln-run: not a process-group leader" >&4; exit 125; }
  "$@" 2>&4 3<&- 4>&- &
  child=$!
  { read -r _ <&3; kill -KILL 0; } 4>&- &
  watcher=$!
  exec 3<&- 4>&-
  wait "$child"
  status=$?
  kill -KILL "$watcher"
  wait "$watcher"
  exit "$status"
  """

  @shell "/bin/sh"

  @doc """
  Exec `exe` with `args`, giving it at most `timeout_ms` of wall clock.

  `exe` must be an absolute path — a `System.find_executable/1` result. It is
  run by path, never looked up on `PATH`.

  `timeout_ms` may be `:infinity` for a caller that is bounded some other way
  (an Oban job timeout). That bound kills the *caller*, which closes the port,
  which kills the program's process group as described in the moduledoc.

  ## Options

    * `:env` — `[{name, value}]` added to the child's environment, as
      `System.cmd/3`'s `:env`. The place for a secret that must not sit in argv
      (`/proc/<pid>/cmdline` is world-readable).
    * `:tail` — keep only the last this-many bytes of output instead of all of
      it, for a child whose output is unbounded (a `tar` listing).
  """
  @spec run(Path.t(), [String.t()], timeout(), keyword()) ::
          {binary(), non_neg_integer() | :timeout}
  def run(exe, args, timeout_ms, opts \\ [])
      when is_binary(exe) and is_list(args) and is_list(opts) and
             (timeout_ms == :infinity or (is_integer(timeout_ms) and timeout_ms > 0)) do
    port =
      Port.open({:spawn_executable, @shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        # `$0` is "kiln-run"; `exe` and `args` are `"$@"`, never shell syntax.
        {:args, ["-c", @wrapper, "kiln-run", exe | args]},
        {:env, port_env(Keyword.get(opts, :env, []))}
      ])

    deadline = deadline(timeout_ms)
    timed_out = "#{Path.basename(exe)} timed out after #{timeout_ms}ms"
    tail = Keyword.get(opts, :tail)

    collect(port, empty(tail), deadline, timed_out, tail)
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  # `System.cmd/3` takes strings; a port takes charlists.
  defp port_env(env) do
    for {name, value} <- env, do: {String.to_charlist(name), String.to_charlist(value)}
  end

  defp empty(nil), do: []
  defp empty(_tail), do: ""

  defp collect(port, acc, deadline, timed_out, tail) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, append(acc, chunk, tail), deadline, timed_out, tail)

      {^port, {:exit_status, code}} ->
        {IO.iodata_to_binary(acc), code}
    after
      remaining(deadline) ->
        # Closing the port is the kill: the wrapper's watcher sees end-of-file
        # on its stdin and SIGKILLs the whole process group.
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

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    # Already closed because the child exited in the race with the timeout.
    ArgumentError -> :ok
  end
end
