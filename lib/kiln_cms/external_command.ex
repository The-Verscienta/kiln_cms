defmodule KilnCMS.ExternalCommand do
  @moduledoc """
  Run an external binary under a **wall-clock** deadline that can actually stop
  it.

  Two modules hand a user-supplied file to a foreign program — `qpdf` in
  `KilnCMS.DocumentProcessor` and `ffmpeg`/`ffprobe` in `KilnCMS.AVProcessor` —
  and both need the same containment. This is that containment, in one place,
  because the two got it in different orders: the PDF path grew a real timeout
  in #918 while the A/V path was still on `System.cmd/3`, which has none (#1100).

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
  """
  # `Port.open/2` with `:spawn_executable` execs directly rather than through a
  # shell, so neither the program nor the argument list can be injected into.
  # Even a hostile *filename* arrives as one exec argv entry, not shell syntax.
  @spec run(Path.t(), [String.t()], pos_integer()) :: {binary(), non_neg_integer() | :timeout}
  def run(exe, args, timeout_ms)
      when is_binary(exe) and is_list(args) and is_integer(timeout_ms) and timeout_ms > 0 do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _closed -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    timed_out = "#{Path.basename(exe)} timed out after #{timeout_ms}ms"

    collect(port, os_pid, [], deadline, timed_out)
  end

  defp collect(port, os_pid, acc, deadline, timed_out) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} -> collect(port, os_pid, [acc | chunk], deadline, timed_out)
      {^port, {:exit_status, code}} -> {IO.iodata_to_binary(acc), code}
    after
      remaining ->
        kill(os_pid)
        close(port)
        drain(port)
        {timed_out, :timeout}
    end
  end

  defp drain(port) do
    receive do
      {^port, _anything} -> drain(port)
    after
      0 -> :ok
    end
  end

  # SIGKILL, because the point is that the process stops now: it is holding CPU
  # or disk on work the caller has already given up on, and neither qpdf nor
  # ffmpeg has cleanup worth waiting for. Closing the port does not signal it.
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
