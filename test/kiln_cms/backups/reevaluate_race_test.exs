defmodule KilnCMS.Backups.ReevaluateRaceTest do
  @moduledoc """
  Re-evaluating an Interrupted import against retention's marks, under real
  row locks (#2846).

  `:mark_pruned` and `:reevaluate_interrupted` both lock the row and compute
  what they write from it as locked. As in `ChainRaceTest`, the sandbox's
  single connection never makes anything wait, so these run **outside** it
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) on real connections whose
  writes commit, and delete what they committed on exit. One side holds its
  write's transaction open while the other is shown to wait on the lock.
  `async: false`: committed rows and the VM-wide backup directory.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Importer, Recorder}
  alias KilnCMS.Repo

  @moduletag :capture_log

  @stamp "20260801-031700"
  @at "2026-08-02T03:00:00Z"
  @db "kiln-db-#{@stamp}.dump"
  @media "kiln-media-#{@stamp}.tar.gz"
  @reevaluated "Re-evaluated: the stamp's .partial files are gone and its set is complete"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bkr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(original, dir: dir))

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(r in "backup_runs")) end)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp artifact(kind, name),
    do: %{kind: kind, name: name, bytes: 100, destinations: %{"local" => %{"status" => "ok"}}}

  # An Interrupted import, committed.
  defp interrupted!(artifacts) do
    unboxed(fn ->
      Backups.import_run!(
        %{
          stamp: @stamp,
          trigger: "cron",
          status: :failed,
          error: Importer.interrupted_message(),
          components: [:db, :media],
          artifacts: artifacts
        },
        actor: Backups.system()
      )
    end)
  end

  defp current, do: unboxed(fn -> Backups.get_run_by_stamp!(@stamp, actor: Backups.system()) end)

  defp rewrite(run, artifacts) do
    Backups.reevaluate_interrupted_run(
      run,
      %{status: :succeeded, error: nil, artifacts: artifacts},
      actor: Backups.system()
    )
  end

  # Runs `write` in a transaction that stays open until `release/1`.
  defp hold(write) do
    parent = self()

    task = Task.async(fn -> unboxed(fn -> in_transaction(write, parent) end) end)

    assert_receive {:holding, pid}, 10_000
    {task, pid}
  end

  defp in_transaction(write, parent),
    do: Repo.transaction(fn -> hold_open(write, parent) end)

  defp hold_open(write, parent) do
    result = write.()
    send(parent, {:holding, self()})

    receive do
      :commit -> result
    end
  end

  defp release({task, pid}) do
    send(pid, :commit)
    assert {:ok, result} = Task.await(task, 10_000)
    result
  end

  defp waits(fun) do
    task = Task.async(fn -> unboxed(fun) end)
    # It reached the lock and is waiting on it.
    assert Task.yield(task, 500) == nil
    task
  end

  defp reevaluated_lines(run), do: Enum.count(run.log, &(&1.message == @reevaluated))

  test "retention's mark first: the rewrite waits, then sees the mark and is refused" do
    row = interrupted!([artifact(:db, @db)])

    held =
      hold(fn ->
        Backups.mark_run_pruned!(row, %{names: [@db], key: "local", at: @at},
          actor: Backups.system()
        )
      end)

    rewriting = waits(fn -> rewrite(row, [artifact(:db, @db), artifact(:media, @media)]) end)
    release(held)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Task.await(rewriting, 10_000)

    run = current()
    assert %{status: :failed, components: [:db, :media]} = run
    assert run.error == Importer.interrupted_message()
    assert [%{name: @db} = db] = run.artifacts
    assert db.destinations["local"] == %{"status" => "pruned", "at" => @at}
    assert reevaluated_lines(run) == 0
  end

  test "the rewrite first: retention's mark waits, then lands on the rewritten artifacts" do
    row = interrupted!([artifact(:db, @db)])

    held = hold(fn -> rewrite(row, [artifact(:db, @db), artifact(:media, @media)]) end)

    # Retention reads the run as it was (the rewrite hasn't committed), and
    # its mark waits on the rewrite's lock.
    pruning = waits(fn -> Recorder.mark_pruned([@media]) end)
    assert {:ok, %{status: :succeeded}} = release(held)
    assert :ok = Task.await(pruning, 10_000)

    run = current()
    assert %{status: :succeeded, error: nil} = run
    assert [%{name: @db} = db, %{name: @media} = media] = run.artifacts
    assert db.destinations["local"] == %{"status" => "ok"}
    assert media.destinations["local"]["status"] == "pruned"
    assert reevaluated_lines(run) == 1
  end

  test "two re-evaluations of one row: the second waits, then gets StaleRecord" do
    row = interrupted!([artifact(:db, @db)])

    held = hold(fn -> rewrite(row, [artifact(:db, @db)]) end)
    second = waits(fn -> rewrite(row, [artifact(:db, @db), artifact(:media, @media)]) end)
    assert {:ok, _} = release(held)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Task.await(second, 10_000)

    run = current()
    assert [%{name: @db}] = run.artifacts
    assert reevaluated_lines(run) == 1
  end

  test "two importers at once rewrite the row once", %{dir: dir} do
    interrupted!([artifact(:db, @db)])

    for {sub, name, body} <- [
          {"db", @db, String.duplicate("x", 100)},
          {"db", Artifact.sidecar_name(:db, @stamp), "#{String.duplicate("b", 64)}  #{@db}\n"},
          {"media", Artifact.part_name(@stamp, 1), String.duplicate("x", 100)},
          {"media", Artifact.sidecar_name(:media, @stamp),
           "#{String.duplicate("a", 64)}  #{Artifact.part_name(@stamp, 1)}\n"}
        ] do
      path = Path.join([dir, sub, name])
      File.write!(path, body)
      File.touch!(path, System.os_time(:second) - 30 * 60)
    end

    gate = make_ref()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          receive do
            ^gate -> unboxed(fn -> Importer.run(dir) end)
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: send(pid, gate)
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert results |> Enum.map(fn {:ok, %{reevaluated: n}} -> n end) |> Enum.sum() == 1
    assert Enum.all?(results, &match?({:ok, %{failed: 0}}, &1))

    run = current()
    assert %{status: :succeeded, components: [:db, :media]} = run
    assert reevaluated_lines(run) == 1
  end

  # The accepted gap (#2846, the importer's moduledoc): a row recorded with
  # only partials has no artifact for retention to mark. A file it deletes
  # after the importer's stat and before the rewrite's lock leaves no trace
  # the rewrite could see, so the rewrite records it as present. The
  # importer's stat, just before the write, is the only guard.
  test "a row with no artifacts: a mark between the stat and the rewrite is not seen" do
    row = interrupted!([])

    assert :ok = Recorder.mark_pruned([@db])
    assert %{artifacts: []} = current()

    assert {:ok, _} = unboxed(fn -> rewrite(row, [artifact(:db, @db)]) end)

    assert [%{name: @db} = db] = current().artifacts
    assert db.destinations["local"] == %{"status" => "ok"}
  end
end
