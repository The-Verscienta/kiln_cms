defmodule KilnCMS.Test.OsProcess do
  @moduledoc """
  Probes for an OS process a test started through a port, for the tests that
  check `KilnCMS.ExternalCommand` kills its child when the caller dies (#2564).

  `kill -0` (`alive?/1`) reports a **zombie** as alive: a SIGKILLed program
  stays one until it is reaped. Its parent, `ExternalCommand`'s wrapper, dies
  in the same group kill, so the program is reparented to PID 1 (or the
  nearest subreaper) and reaped by that, which on a loaded host can lag.
  Those tests assert the program was *killed*, not that it was reaped, so
  `gone?/1` counts a zombie as gone. It reads the state with `ps`, and falls
  back to `kill -0` (stricter: it waits for the reap) where `ps` is missing.
  """

  @doc "Whether `kill -0` reaches `os_pid` (a zombie counts as alive)."
  @spec alive?(integer() | String.t()) :: boolean()
  def alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  @doc "Whether `os_pid` has exited: no longer present, or a zombie awaiting its reap."
  @spec gone?(integer() | String.t()) :: boolean()
  def gone?(os_pid) do
    case state(os_pid) do
      :unknown -> not alive?(os_pid)
      "" -> true
      "Z" <> _ -> true
      _running -> false
    end
  end

  @doc """
  The `ps` state of `os_pid` (`"S"`, `"R+"`, `"Z"`, …), `""` when there is no
  such process, or `:unknown` without `ps`. For a failure message.
  """
  @spec state(integer() | String.t()) :: String.t() | :unknown
  def state(os_pid) do
    case System.find_executable("ps") do
      nil ->
        :unknown

      ps ->
        {out, _status} =
          System.cmd(ps, ["-o", "stat=", "-p", to_string(os_pid)], stderr_to_stdout: true)

        String.trim(out)
    end
  end
end
