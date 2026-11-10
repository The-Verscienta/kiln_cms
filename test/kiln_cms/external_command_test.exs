defmodule KilnCMS.ExternalCommandTest do
  @moduledoc """
  The wall-clock bound around a foreign program (#918, #1100).

  The whole reason this module exists rather than `System.cmd/3` is that the
  deadline must reach the *OS process*, so the test that matters is the one
  showing the child actually stops — not merely that the call returned. Closing
  an Erlang port shuts the pipes and signals nothing, so a version of this that
  only closed the port would pass every other assertion here.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.ExternalCommand

  @sh System.find_executable("sh")

  defp run(script, timeout_ms), do: ExternalCommand.run(@sh, ["-c", script], timeout_ms)

  describe "run/3" do
    test "returns stdout and a zero status" do
      assert {"hello", 0} = run("printf hello", 5_000)
    end

    test "folds stderr into the output, so a failure carries its reason" do
      assert {output, 3} = run("printf 'went wrong' >&2; exit 3", 5_000)
      assert output =~ "went wrong"
    end

    test "accumulates output across many chunks" do
      # Enough to arrive as more than one port message, which is what the
      # iodata accumulator is for.
      assert {output, 0} = run("for i in $(seq 1 5000); do printf 'abcdefghij'; done", 15_000)
      assert byte_size(output) == 50_000
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
      # it is stopped. Closing the port would leave the loop running, so a
      # port-close-only implementation fails here and nowhere else.
      marker = Path.join(dir, "alive")

      assert {_output, :timeout} =
               run("i=0; while true; do i=$((i+1)); echo $i > #{marker}; sleep 0.05; done", 300)

      at_timeout = File.read!(marker)

      # Long enough for several more loop iterations, had any been coming.
      Process.sleep(400)

      assert File.read!(marker) == at_timeout,
             "the child kept writing after the deadline — it was not killed"
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
               ExternalCommand.run(@sh, ["-c", "printf %s \"$KILN_TEST_VAR\""], 5_000,
                 env: [{"KILN_TEST_VAR", "s3cret-value"}]
               )
    end

    test ":tail keeps only the last bytes of the output" do
      assert {output, 0} =
               ExternalCommand.run(@sh, ["-c", "printf 'abcdefghij'; printf 'XYZ'"], 5_000,
                 tail: 5
               )

      assert output == "ijXYZ"
    end

    test "accepts :infinity as the timeout" do
      assert {"ok", 0} = ExternalCommand.run(@sh, ["-c", "printf ok"], :infinity)
    end
  end

  describe "run/4 when the caller dies" do
    @tag :tmp_dir
    test "kills the child OS process", %{tmp_dir: dir} do
      # The child records its own pid, then `exec`s so that pid is the long
      # sleeper: killing the caller must take that exact process down.
      pid_file = Path.join(dir, "pid")
      test = self()

      caller =
        spawn(fn ->
          send(test, :started)

          ExternalCommand.run(@sh, ["-c", "echo $$ > #{pid_file}; exec sleep 30"], :infinity)
        end)

      assert_receive :started
      os_pid = wait_for_pid(pid_file)
      assert alive?(os_pid)

      ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

      assert eventually(fn -> not alive?(os_pid) end),
             "the child outlived its killed caller"
    end
  end

  defp wait_for_pid(file, tries \\ 100) do
    case File.read(file) do
      {:ok, text} when text != "" ->
        text |> String.trim() |> String.to_integer()

      _ when tries > 0 ->
        Process.sleep(20)
        wait_for_pid(file, tries - 1)
    end
  end

  # `kill -0` probes without signalling. A killed child is a zombie until the
  # VM's port reaper collects it, which `kill -0` still reports alive for a
  # moment, hence the polling.
  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
