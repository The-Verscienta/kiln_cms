defmodule KilnCMS.ExternalCommandTest do
  @moduledoc """
  The wall-clock bound around a foreign program (#918, #1100), and the kill
  that enforces it (#2218, #2624).

  The whole reason this module exists rather than `System.cmd/3` is that the
  deadline must reach the *OS process*, so the tests that matter are the ones
  showing the child actually stops — not merely that the call returned.
  Closing an Erlang port shuts the pipes and signals nothing by itself, so a
  version of this that only closed the port would pass every other assertion
  here.

  The kill is the wrapper's: its stdin watcher SIGKILLs its own process group
  when the port closes. It is asynchronous, so every "the child is gone" check
  polls with `Eventually` against a generous deadline rather than asserting
  at the instant `run/4` returns.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.ExternalCommand
  alias KilnCMS.Test.Eventually
  alias KilnCMS.Test.OsProcess

  @sh System.find_executable("sh")

  defp run(script, timeout_ms, opts \\ []),
    do: ExternalCommand.run(@sh, ["-c", script], timeout_ms, opts)

  describe "run/3" do
    test "returns stdout and a zero status" do
      assert {"hello", 0} = run("printf hello", 5_000)
    end

    test "folds stderr into the output, so a failure carries its reason" do
      assert {"went wrong", 3} = run("printf 'went wrong' >&2; exit 3", 5_000)
    end

    test "accumulates output across many chunks" do
      # Enough to arrive as more than one port message, which is what the
      # iodata accumulator is for.
      assert {output, 0} = run("for i in $(seq 1 5000); do printf 'abcdefghij'; done", 15_000)
      assert output == String.duplicate("abcdefghij", 5_000)
    end

    test "passes arguments through untouched, never as shell syntax" do
      hostile = "a b; echo injected $(echo nope) \"q\" '$HOME' *"

      assert {^hostile, 0} =
               ExternalCommand.run(@sh, ["-c", "printf %s \"$1\"", "argv0", hostile], 5_000)
    end

    test "a child killed by a signal reports 128 + the signal, as a direct child does" do
      assert {"", 137} = run("kill -9 $$", 5_000)
    end

    test "the child's stdin is /dev/null, so a read gets end-of-file at once" do
      assert {"1\n", 0} = run("read x; echo $?", 5_000)
    end

    test "a missing executable is an exit status, not a raise" do
      assert {_output, 127} = ExternalCommand.run("/nonexistent/kiln-no-such-binary", [], 5_000)
    end

    @tag :tmp_dir
    test "a non-executable file is an exit status, not a raise", %{tmp_dir: dir} do
      script = Path.join(dir, "not-executable")
      File.write!(script, "#!/bin/sh\nprintf ran\n")
      File.chmod!(script, 0o644)

      assert {output, 126} = ExternalCommand.run(script, [], 5_000)
      refute output =~ "ran"
    end
  end

  describe "run/3 deadline" do
    test "returns :timeout with a message naming the limit" do
      assert {output, :timeout} = run("sleep 30", 200)
      assert output =~ "timed out after 200ms"
    end

    test "does not outlive its deadline" do
      started = System.monotonic_time(:millisecond)
      assert {_output, :timeout} = run("sleep 30", 200)
      elapsed = System.monotonic_time(:millisecond) - started

      # Generous upper bound — the point is that it returned in the region of
      # the deadline rather than in thirty seconds.
      assert elapsed < 5_000
    end

    @tag :tmp_dir
    test "actually kills the child rather than just closing the port", %{tmp_dir: dir} do
      # A child that keeps *proving* it is alive: it rewrites this file until
      # it is stopped. A port close that signalled nothing would leave the loop
      # running, so that implementation fails here and nowhere else.
      pid_file = Path.join(dir, "pid")
      marker = Path.join(dir, "alive")

      assert {_output, :timeout} =
               run(
                 "echo $$ > #{q(pid_file)}; " <>
                   "i=0; while true; do i=$((i+1)); echo $i > #{q(marker)}; sleep 0.05; done",
                 300
               )

      assert_killed(read_pid(pid_file))
      assert_marker_stable(marker)
    end

    @tag :tmp_dir
    test "kills a grandchild the child started", %{tmp_dir: dir} do
      grandchild_file = Path.join(dir, "grandchild")

      assert {_output, :timeout} =
               run("sleep 30 & echo $! > #{q(grandchild_file)}; wait", 300)

      assert_killed(read_pid(grandchild_file))
    end

    @tag :tmp_dir
    test "kills the child with no `kill` binary on the PATH", %{tmp_dir: dir} do
      # The kill is a shell builtin run by the wrapper, so nothing on PATH is
      # needed. The child uses absolute paths for the same reason.
      pid_file = Path.join(dir, "pid")

      assert {_output, :timeout} =
               run("echo $$ > #{q(pid_file)}; exec /bin/sleep 30", 300,
                 env: [{"PATH", "/nonexistent"}]
               )

      assert_killed(read_pid(pid_file))
    end

    test "leaves no port messages in the caller's mailbox" do
      # `Port.close/1` stops delivery but does not purge what was already sent.
      # A stray `{port, {:data, _}}` reaching a LiveView with no catch-all
      # `handle_info/2` crashes the editor's media page.
      assert {_output, :timeout} =
               run("while true; do printf 'noise'; done", 200)

      {:messages, messages} = Process.info(self(), :messages)

      refute Enum.any?(messages, &match?({p, _} when is_port(p), &1)),
             "port messages were left behind: #{inspect(messages)}"
    end
  end

  describe "run/4 options" do
    test "passes :env to the child" do
      assert {"s3cret-value", 0} =
               run("printf %s \"$KILN_TEST_VAR\"", 5_000,
                 env: [{"KILN_TEST_VAR", "s3cret-value"}]
               )
    end

    test ":tail keeps only the last bytes of the output" do
      assert {"ijXYZ", 0} = run("printf 'abcdefghij'; printf 'XYZ'", 5_000, tail: 5)
    end

    test "accepts :infinity as the timeout" do
      assert {"ok", 0} = run("printf ok", :infinity)
    end
  end

  describe "run/4 when the caller dies" do
    @tag :tmp_dir
    test "kills the child OS process", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "pid")
      caller = start_caller("echo $$ > #{q(pid_file)}; exec sleep 30")

      os_pid = read_pid(pid_file)
      assert OsProcess.alive?(os_pid)

      kill_caller(caller)
      assert_killed(os_pid)
    end

    @tag :tmp_dir
    test "kills a grandchild the child started", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "pid")
      grandchild_file = Path.join(dir, "grandchild")

      caller =
        start_caller("sleep 30 & echo $! > #{q(grandchild_file)}; echo $$ > #{q(pid_file)}; wait")

      os_pid = read_pid(pid_file)
      grandchild = read_pid(grandchild_file)

      kill_caller(caller)
      assert_killed(os_pid)
      assert_killed(grandchild)
    end

    @tag :tmp_dir
    test "kills the child with no `kill` binary on the PATH", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "pid")

      caller =
        start_caller("echo $$ > #{q(pid_file)}; exec /bin/sleep 30",
          env: [{"PATH", "/nonexistent"}]
        )

      os_pid = read_pid(pid_file)
      kill_caller(caller)
      assert_killed(os_pid)
    end

    @tag :tmp_dir
    test "the wrapper leads its own process group, and the child is in it", %{tmp_dir: dir} do
      # The group kill reaches no stranger only because the port's child is a
      # process-group leader. The wrapper refuses to start otherwise (status
      # 125); this pins the invariant on whatever OS the suite runs on.
      pid_file = Path.join(dir, "pid")
      caller = start_caller("echo $$ > #{q(pid_file)}; exec sleep 30")

      os_pid = read_pid(pid_file)
      wrapper = wrapper_pid(caller)

      assert pgid(wrapper) == wrapper
      assert pgid(os_pid) == wrapper

      kill_caller(caller)
      assert_killed(os_pid)
    end

    @tag :tmp_dir
    test "never signals by pid once the child has exited and been reaped (#2624)", %{
      tmp_dir: dir
    } do
      # The race: the child exits and the VM reaps it, so its pid is free for
      # reuse, but the caller has not yet handled `{:exit_status, _}`. If the
      # caller dies in that window, anything that then kills "the child" by
      # pid could hit an unrelated process that took the number.
      #
      # This holds the caller in exactly that window (suspended, with the
      # exit status in its mailbox and both OS processes gone), kills it, and
      # checks that nothing it started reaches for `System.cmd/3` or
      # `:os.cmd/1,2` (the ways to run `kill`) or spawns a process to do so.
      # It is a tripwire for those calls, not a proof about every possible
      # signal: the design's guarantee is that the BEAM sends none at all.
      #
      # Tracing starts before `run/4`, with `set_on_spawn`, so a process
      # `run/4` spawns is traced too. A session keeps the trace patterns out
      # of other tests' way.
      pid_file = Path.join(dir, "pid")
      go_file = Path.join(dir, "go")

      caller =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          run(
            "echo $$ > #{q(pid_file)}; while [ ! -e #{q(go_file)} ]; do sleep 0.02; done",
            :infinity
          )
        end)

      session = :trace.session_create(:kiln_external_command_test, self(), [])
      on_exit(fn -> :trace.session_destroy(session) end)

      for mfa <- [{System, :cmd, :_}, {:os, :cmd, :_}] do
        :trace.function(session, mfa, true, [:global])
      end

      1 = :trace.process(session, caller, true, [:call, :procs, :set_on_spawn])
      send(caller, :go)

      os_pid = read_pid(pid_file)
      port = port_of(caller)
      wrapper = wrapper_pid(caller)

      true = :erlang.suspend_process(caller)
      File.touch!(go_file)

      Eventually.eventually(
        fn ->
          {:messages, messages} = Process.info(caller, :messages)

          {port, {:exit_status, 0}} in messages and OsProcess.gone?(os_pid) and
            OsProcess.gone?(wrapper)
        end,
        timeout_ms: 10_000,
        message: "the child never exited with its exit status left unhandled"
      )

      ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

      refute_receive {:trace, _pid, :call, _mfa_args}, 1_000
      refute_received {:trace, _pid, :spawn, _child, _mfa}
      refute_received {:trace, _pid, :spawned, _parent, _mfa}
    end
  end

  # A path single-quoted for a test script: a `tmp_dir` is named after its
  # test, and a test name can hold shell syntax (backticks, parentheses).
  defp q(path), do: "'" <> path <> "'"

  # A process that runs `script` under `run/4` with no deadline, so only its
  # own death can stop the child.
  defp start_caller(script, opts \\ []) do
    spawn(fn -> run(script, :infinity, opts) end)
  end

  defp kill_caller(caller) do
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
  end

  # The kill is an OS event chain (port close, end-of-file, group SIGKILL), so
  # the bound is a wall-clock deadline, not a try count. A killed child is a
  # zombie until it is reaped; `gone?/1` counts that.
  defp assert_killed(os_pid) do
    Eventually.eventually(fn -> OsProcess.gone?(os_pid) end,
      timeout_ms: 10_000,
      message: fn ->
        "pid #{os_pid} was not killed: ps state #{inspect(OsProcess.state(os_pid))}"
      end
    )
  end

  defp assert_marker_stable(marker) do
    at_kill = File.read!(marker)

    # Long enough for several more loop iterations, had any been coming.
    Process.sleep(300)

    assert File.read!(marker) == at_kill,
           "the child kept writing after it was reported gone"
  end

  defp port_of(caller) do
    Eventually.eventually(
      fn ->
        {:links, links} = Process.info(caller, :links)
        Enum.find(links, &is_port/1)
      end,
      timeout_ms: 10_000,
      message: "the caller never opened its port"
    )
  end

  defp wrapper_pid(caller) do
    {:os_pid, os_pid} = Port.info(port_of(caller), :os_pid)
    os_pid
  end

  defp pgid(os_pid) do
    {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(os_pid)])
    out |> String.trim() |> String.to_integer()
  end

  defp read_pid(file) do
    Eventually.eventually(
      fn ->
        with {:ok, text} <- File.read(file),
             {pid, ""} <- text |> String.trim() |> Integer.parse() do
          pid
        else
          _not_yet -> nil
        end
      end,
      timeout_ms: 10_000,
      message: "the child never wrote its pid to #{file}"
    )
  end
end

defmodule KilnCMS.ExternalCommandNoPathTest do
  @moduledoc """
  The kill on a host with no `kill` binary anywhere: the VM's own `PATH` is
  emptied for the run, not only the child's.

  `async: false` because `System.put_env/2` changes `PATH` for the whole VM,
  and a concurrent test resolving an executable would see it. The probes use
  `ps` by the absolute path found at compile time for the same reason.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.ExternalCommand
  alias KilnCMS.Test.Eventually

  @sh System.find_executable("sh")
  @ps System.find_executable("ps")

  if is_nil(@ps), do: @moduletag(skip: "needs ps to probe the child")

  setup do
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)
    System.put_env("PATH", "/nonexistent")
    :ok
  end

  @tag :tmp_dir
  test "the deadline kills the child", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "pid")

    assert {_output, :timeout} =
             ExternalCommand.run(
               @sh,
               ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "sh", pid_file],
               300
             )

    assert_killed(read_pid(pid_file))
  end

  @tag :tmp_dir
  test "the caller's death kills the child", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "pid")

    caller =
      spawn(fn ->
        ExternalCommand.run(
          @sh,
          ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "sh", pid_file],
          :infinity
        )
      end)

    os_pid = read_pid(pid_file)
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    assert_killed(os_pid)
  end

  defp assert_killed(os_pid) do
    Eventually.eventually(
      fn -> gone?(state(os_pid)) end,
      timeout_ms: 10_000,
      message: fn -> "pid #{os_pid} was not killed: ps state #{inspect(state(os_pid))}" end
    )
  end

  # No such process, or a zombie awaiting its reap: either way, killed.
  defp gone?(""), do: true
  defp gone?("Z" <> _rest), do: true
  defp gone?(_running), do: false

  defp state(os_pid) do
    {out, _status} = System.cmd(@ps, ["-o", "stat=", "-p", to_string(os_pid)])
    String.trim(out)
  end

  defp read_pid(file) do
    Eventually.eventually(
      fn ->
        with {:ok, text} <- File.read(file),
             {pid, ""} <- text |> String.trim() |> Integer.parse() do
          pid
        else
          _not_yet -> nil
        end
      end,
      timeout_ms: 10_000,
      message: "the child never wrote its pid to #{file}"
    )
  end
end
