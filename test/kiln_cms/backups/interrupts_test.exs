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

  test "runs in order behind a blocked one; past 20 waiting, one is dropped and logged", %{
    parent: parent
  } do
    assert Interrupts.run("blocked", ran(parent, 0)) == :ok
    assert_receive {:blocked, blocked}

    for n <- 1..20, do: Interrupts.run("stamp-#{n}", ran(parent, n))

    log =
      capture_log([level: :warning], fn ->
        Interrupts.run("stamp-21", ran(parent, 21),
          dropped: {:error, "Its run reads Running until the stale-run check fails it."}
        )

        Interrupts.run("stamp-22", ran(parent, 22))
        # The casts are handled before this call.
        assert Interrupts.await_idle(50) == :timeout
      end)

    assert log =~
             ~r/\[error\] Backup stamp-21: dropped from the interrupt records, 20 are waiting .*Its run reads Running until the stale-run check fails it\./

    assert log =~ ~r/\[warning\] Backup stamp-22: dropped from the interrupt records/
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
    refute_received {:ran, 22}
  end

  test "a crash is logged and the next one runs", %{parent: parent} do
    log =
      capture_log([level: :error], fn ->
        Interrupts.run("crashing", fn -> raise "boom" end)
        Interrupts.run("next", ran(parent, 1))
        assert Interrupts.await_idle() == :ok
      end)

    assert log =~ "Backup crashing: the interrupt record crashed"
    assert_received {:ran, 1}
  end

  test "the caller never waits on the work" do
    {micros, :ok} = :timer.tc(fn -> Interrupts.run("blocked", fn -> :ok end) end)

    assert micros < 100_000
    assert_receive {:blocked, blocked}
    send(blocked, :release)
    assert Interrupts.await_idle() == :ok
  end

  # A restarted `Interrupts` finds the task its predecessor left and starts
  # no other until it ends: never two at once.
  test "after a crash, the restarted process waits for the task left running", %{
    parent: parent
  } do
    Interrupts.run("blocked", ran(parent, 0))
    assert_receive {:blocked, blocked}

    old = Process.whereis(Interrupts)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    assert Process.alive?(blocked)

    new = wait_for_restart(old)
    assert new != old
    assert Interrupts.stalled?() == false

    Interrupts.run("after", ran(parent, 1))
    assert Interrupts.await_idle(100) == :timeout
    refute_received {:ran, _}

    send(blocked, :release)
    assert Interrupts.await_idle() == :ok
    assert_received {:ran, 0}
    assert_received {:ran, 1}
  end

  test "stalled? is true only while a task has run past the threshold" do
    env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(env, :interrupt_slow_ms, 0))

    refute Interrupts.stalled?()
    Interrupts.run("blocked", fn -> :ok end)
    assert_receive {:blocked, blocked}
    assert Interrupts.stalled?()

    send(blocked, :release)
    assert Interrupts.await_idle() == :ok
    refute Interrupts.stalled?()
  end

  defp wait_for_restart(old, tries \\ 100) do
    case Process.whereis(Interrupts) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when tries > 0 ->
        Process.sleep(10)
        wait_for_restart(old, tries - 1)
    end
  end

  test "inline mode runs the work in the caller", %{parent: parent} do
    env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(env, :interrupts, :inline))

    Interrupts.run("here", fn -> send(parent, {:ran_in, self()}) end)

    assert_received {:ran_in, pid}
    assert pid == self()
  end
end
