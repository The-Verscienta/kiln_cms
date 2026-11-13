defmodule KilnCMS.Backups.SchedulerRaceTest do
  @moduledoc """
  Backup schedules under real concurrency (#2219, part 2): two nodes ticking
  in the same minute (a deploy, a leader change) must fire a window once.

  As in `ChainRaceTest`, the sandbox's single connection never makes anything
  wait, so these run **outside** it (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`)
  on real connections whose writes commit, and delete what they committed on
  exit. `async: false`: committed rows and the VM-wide backup directory.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Schedule
  alias KilnCMS.Repo

  @moduletag :pg_tools
  @moduletag :capture_log

  # A daily window well after the seeded baseline.
  @w ~U[2026-03-02 03:00:00.000000Z]

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bks_#{System.unique_integer([:positive])}")
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil)
    )

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(j in "oban_jobs", where: j.queue == "backup_steps"))
        Repo.delete_all(from(l in "backup_locks"))
        Repo.delete_all(from(r in "backup_runs"))
        Repo.delete_all(from(s in "backup_schedules"))
      end)

      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(dir)
    end)

    :ok
  end

  # Committed outside the sandbox, so seeded rather than created: a create
  # needs a platform admin, whose user row would have to be committed (and
  # cleaned up) too. The columns are what `:create` would write.
  defp seed_schedule!(attrs \\ %{}) do
    unboxed(fn ->
      Ash.Seed.seed!(
        Schedule,
        Map.merge(
          %{
            components: [:db],
            interval: :daily,
            time_of_day: ~T[03:00:00],
            starts_on: ~D[2026-01-01],
            time_zone: "Etc/UTC",
            enabled: true,
            baseline_at: ~U[2026-01-01 00:00:00.000000Z]
          },
          attrs
        )
      )
    end)
  end

  defp claim(schedule) do
    Backups.claim_backup_schedule_window(schedule, %{window_at: @w, outcome: :started},
      actor: Backups.system()
    )
  end

  test "two concurrent claims of one window: exactly one succeeds" do
    schedule = seed_schedule!()
    parent = self()

    # The first claims inside a transaction and holds it open; the second's
    # update waits on the row, then re-reads it once the first commits.
    first =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            result = claim(schedule)
            send(parent, {:claimed, self()})

            receive do
              :commit -> result
            end
          end)
        end)
      end)

    assert_receive {:claimed, holder}, 10_000

    second = Task.async(fn -> unboxed(fn -> claim(schedule) end) end)

    # Blocked on the row the first holds.
    assert Task.yield(second, 300) == nil

    send(holder, :commit)

    assert {:ok, {:ok, %{last_window_at: @w}}} = Task.await(first, 10_000)
    assert {:error, %Ash.Error.Invalid{}} = Task.await(second, 10_000)

    assert %{last_window_at: @w, last_outcome: :started} =
             unboxed(fn -> Backups.get_backup_schedule!(schedule.id, actor: Backups.system()) end)
  end

  defp fire(schedule, at),
    do: Backups.request_scheduled([schedule.id], at, Backups.system())

  defp start_jobs do
    unboxed(fn ->
      Repo.all(
        from(j in Oban.Job,
          where: j.queue == "backup_steps" and fragment("?->>'step' = 'start'", j.args)
        )
      )
    end)
  end

  defp get(schedule),
    do: unboxed(fn -> Backups.get_backup_schedule!(schedule.id, actor: Backups.system()) end)

  # A pause as the table sees it: the claim's filter reads `enabled`.
  defp pause_sql(schedule) do
    {:ok, id} = Ecto.UUID.dump(schedule.id)
    Repo.update_all(from(s in "backup_schedules", where: s.id == ^id), set: [enabled: false])
  end

  test "deploy double-fire: two ticks for one minute on two connections make one chain, one start job, one claim" do
    schedule = seed_schedule!()
    at = DateTime.utc_now()
    gate = make_ref()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          receive do
            ^gate -> unboxed(fn -> fire(schedule, at) end)
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: send(pid, gate)
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    statuses = results |> Enum.map(fn {:ok, %{status: s}} -> s end) |> Enum.sort()
    assert statuses == [:nothing_due, :started]

    assert [%{args: %{"schedule_ids" => [id]}}] = start_jobs()
    assert id == schedule.id
    assert %{last_outcome: :started, last_window_at: %DateTime{}} = get(schedule)

    # The loser's queued request was rolled back with its claim.
    assert %{waiting: nil} = unboxed(fn -> Backups.in_flight() end)
  end

  test "a schedule paused between the read and the claim: :nothing_due, and the lock and its Oban insert roll back" do
    schedule = seed_schedule!()
    parent = self()

    # Holds the schedule's row, so the tick's claim waits on it.
    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            {:ok, id} = Ecto.UUID.dump(schedule.id)
            Repo.query!("SELECT 1 FROM backup_schedules WHERE id = $1 FOR UPDATE", [id])
            send(parent, {:holding, self()})

            receive do
              :pause -> pause_sql(schedule)
            end
          end)
        end)
      end)

    assert_receive {:holding, pid}, 10_000

    tick = Task.async(fn -> unboxed(fn -> fire(schedule, DateTime.utc_now()) end) end)

    # Read the schedule, decided to start, and now waits on the claim.
    assert Task.yield(tick, 500) == nil

    send(pid, :pause)
    Task.await(holder, 10_000)

    assert {:ok, %{status: :nothing_due, claimed: []}} = Task.await(tick, 30_000)
    assert start_jobs() == []
    assert unboxed(fn -> Backups.in_flight() end) == nil
    assert %{enabled: false, last_window_at: nil} = get(schedule)
  end

  test "a pause racing a tick: the window either fired before the pause or not at all" do
    for _ <- 1..5 do
      schedule = seed_schedule!()
      gate = make_ref()

      tick =
        Task.async(fn ->
          receive do
            ^gate -> unboxed(fn -> fire(schedule, DateTime.utc_now()) end)
          end
        end)

      pause =
        Task.async(fn ->
          receive do
            ^gate -> unboxed(fn -> pause_sql(schedule) end)
          end
        end)

      send(tick.pid, gate)
      send(pause.pid, gate)
      {:ok, result} = Task.await(tick, 30_000)
      Task.await(pause, 10_000)

      stored = get(schedule)
      chains = start_jobs() |> Enum.filter(&(&1.args["schedule_ids"] == [schedule.id]))

      case result.status do
        :started ->
          assert [_] = chains
          assert %DateTime{} = stored.last_window_at

        :nothing_due ->
          assert chains == []
          assert stored.last_window_at == nil
      end

      unboxed(fn ->
        Repo.delete_all(from(j in "oban_jobs", where: j.queue == "backup_steps"))
        Repo.delete_all(from(l in "backup_locks"))
      end)
    end
  end
end
