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
end
