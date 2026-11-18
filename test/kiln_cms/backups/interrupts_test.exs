defmodule KilnCMS.Backups.InterruptsTest do
  @moduledoc """
  The hand-off of what the backup lock sweep records after its commit
  (#3078): one task at a time, the rest in order and bounded, a crash logged
  and passed over. The heartbeat's side is in `HeartbeatTest`.

  `async: false`: it switches the VM-wide `Application` env from the test
  build's `:inline` mode to the task, and uses the VM-wide
  `KilnCMS.Backups.Interrupts` process.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Backups.Interrupts

  @moduletag :capture_log

  setup do
    parent = self()
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    # A task labeled "blocked" waits for `:release`, as one on a hung mount.
    hook = fn label ->
      if label == "blocked" do
        send(parent, {:blocked, self()})

        receive do
          :release -> :ok
        end
      end
    end

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, interrupts: :async, before_interrupt: hook)
    )

    on_exit(fn ->
      Enum.each(Task.Supervisor.children(KilnCMS.Backups.InterruptTasks), &send(&1, :release))
      Interrupts.await_idle()
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{parent: parent}
  end

  defp ran(parent, n), do: fn -> send(parent, {:ran, n}) end

  test "runs in order behind a blocked one; past 20 waiting, one is dropped with an error", %{
    parent: parent
  } do
    assert Interrupts.run("blocked", ran(parent, 0)) == :ok
    assert_receive {:blocked, blocked}

    for n <- 1..20, do: Interrupts.run("stamp-#{n}", ran(parent, n))

    log =
      capture_log([level: :error], fn ->
        Interrupts.run("stamp-21", ran(parent, 21))
        # The cast is handled before this call.
        assert Interrupts.await_idle(50) == :timeout
      end)

    assert log =~ "Backup stamp-21: not recorded as interrupted"
    assert log =~ "20 earlier records are waiting"
    refute_received {:ran, _}

    send(blocked, :release)
    assert Interrupts.await_idle() == :ok

    order =
      for _ <- 0..20 do
        assert_received {:ran, n}
        n
      end

    assert order == Enum.to_list(0..20)

    refute_received {:ran, 21}
  end

  test "a crash is logged and the next one runs", %{parent: parent} do
    log =
      capture_log([level: :error], fn ->
        Interrupts.run("crashing", fn -> raise "boom" end)
        Interrupts.run("next", ran(parent, 1))
        assert Interrupts.await_idle() == :ok
      end)

    assert log =~ "Backup crashing: recording it as interrupted crashed"
    assert_received {:ran, 1}
  end

  test "the caller never waits on the work" do
    {micros, :ok} = :timer.tc(fn -> Interrupts.run("blocked", fn -> :ok end) end)

    assert micros < 100_000
    assert_receive {:blocked, blocked}
    send(blocked, :release)
    assert Interrupts.await_idle() == :ok
  end

  test "inline mode runs the work in the caller", %{parent: parent} do
    env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(env, :interrupts, :inline))

    Interrupts.run("here", fn -> send(parent, {:ran_in, self()}) end)

    assert_received {:ran_in, pid}
    assert pid == self()
  end
end
