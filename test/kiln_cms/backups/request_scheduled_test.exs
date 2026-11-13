defmodule KilnCMS.Backups.RequestScheduledTest do
  @moduledoc """
  `Backups.request_scheduled/3` (part of #2219): one backup for every due
  window, the windows claimed in the lock transaction that starts, queues or
  folds it; refused windows claimed as refused; deferred ones (#2540) left due
  and noted once per window. Every outcome is driven through the public
  function, nothing stubbed. Concurrency (two nodes, a pause racing a tick) is
  in `SchedulerRaceTest`.

  `async: false`: it changes the VM-wide backup config.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, WorkState}
  alias KilnCMS.Backups.Schedule.Window
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  @baseline ~U[2026-01-01 00:00:00.000000Z]

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkrs_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(media)
    File.write!(Path.join(media, "f.bin"), "media")

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: media, keep_days: 14)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{dir: dir, media: media}
  end

  defp set_config(overrides) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups), overrides)
    )
  end

  # A schedule whose latest window is due now (its baseline long past).
  defp due!(attrs \\ %{}), do: force!(schedule!(attrs), baseline_at: @baseline)

  defp window(s, at) do
    {:ok, w} = Window.latest(s, at)
    w
  end

  defp fire(ids, at \\ DateTime.utc_now()),
    do: Backups.request_scheduled(List.wrap(ids), at, Backups.system())

  defp reload(s), do: Backups.get_backup_schedule!(s.id, actor: Backups.system())

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp start_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.queue == "backup_steps" and fragment("?->>'step' = 'start'", j.args),
        order_by: j.id
      )
    )
  end

  defp runs, do: Backups.list_runs!(actor: Backups.system())

  defp request(opts \\ []), do: Backups.request(opts, Backups.system())

  # A failed in-app run that kept its state: one `request(resume: stamp)` takes.
  defp resumable!(dir, stamp) do
    run =
      Backups.start_run!(%{stamp: stamp, trigger: "manual", components: [:db]},
        actor: Backups.system()
      )

    Backups.fail_run!(run, %{error: "pg_dump exited 1"}, actor: Backups.system())
    work = WorkState.path(dir, stamp)
    File.mkdir_p!(work)
    :ok = WorkState.write(work, WorkState.new(stamp))
    stamp
  end

  defp snapshot do
    row = lock()

    {Map.take(row, [
       :chain_id,
       :step_job_id,
       :waiting_trigger,
       :waiting_resume_stamp,
       :waiting_requested_at,
       :waiting_folds,
       :waiting_schedule_ids
     ]), Enum.map(runs(), & &1.id) |> Enum.sort(), Repo.aggregate(Oban.Job, :count)}
  end

  describe "the request" do
    test "a free lock: :started; every due window claimed in the same commit; the start job carries the schedule" do
      s = due!()
      at = DateTime.utc_now()
      w = window(s, at)

      assert {:ok, %{status: :started, chain: chain, claimed: [{id, ^w}]}} = fire(s.id, at)
      assert id == s.id

      assert %{last_window_at: ^w, last_outcome: :started, last_error: nil} = reload(s)

      assert [%{args: args}] = start_jobs()
      assert args["chain"] == chain
      assert args["trigger"] == "schedule"
      assert args["components"] == ["db"]
      assert args["scheduled"] == ["db"]
      assert args["schedule_ids"] == [s.id]
    end

    test "a running chain: :queued, and the claim says so" do
      {:ok, %{status: :started}} = request()
      s = due!()

      assert {:ok, %{status: :queued}} = fire(s.id)
      assert %{last_outcome: :queued} = reload(s)
      assert %{waiting_trigger: "schedule", waiting_schedule_ids: [id]} = lock()
      assert id == s.id
    end

    test "a queued fresh backup: :folded, and components, scheduled and schedule_ids are unioned" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(components: [:media])
      s = due!()

      assert {:ok, %{status: :folded}} = fire(s.id)
      assert %{last_outcome: :folded} = reload(s)

      row = lock()
      scope = Chain.waiting_scope(row)
      assert scope.components == [:db, :media]
      assert scope.scheduled == [:db]
      assert scope.schedule_ids == [s.id]
    end

    test "W-e: two schedules due together make one request and one start job; both windows claimed" do
      a = due!()
      b = due!(%{time_of_day: ~T[02:00:00]})
      at = DateTime.utc_now()

      assert {:ok, %{status: :started, claimed: claimed}} = fire([a.id, b.id], at)
      assert Enum.sort(claimed) == Enum.sort([{a.id, window(a, at)}, {b.id, window(b, at)}])

      assert [%{args: %{"schedule_ids" => ids}}] = start_jobs()
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      assert %{last_outcome: :started} = reload(a)
      assert %{last_outcome: :started} = reload(b)
    end

    test "the start step records the run's scheduled_components and schedule_ids" do
      s = due!()
      {:ok, %{status: :started}} = fire(s.id)

      BackupChain.drain(with_recursion: false, with_scheduled: false)

      assert [run] = runs()
      assert run.trigger == "schedule"
      assert run.scheduled_components == [:db]
      assert run.schedule_ids == [s.id]
    end

    test "nothing due: no request" do
      s = due!()
      {:ok, %{status: :started}} = fire(s.id)

      assert {:ok, %{status: :nothing_due, claimed: []}} = fire(s.id)
      assert length(start_jobs()) == 1
    end

    test "a paused schedule is never due" do
      admin = platform_admin()
      s = due!(%{}) |> then(&Backups.update_backup_schedule!(&1, %{enabled: false}, actor: admin))

      assert {:ok, %{status: :nothing_due}} = fire(s.id)
      assert start_jobs() == []
    end
  end

  describe "#2540: a queued Resume" do
    setup %{dir: dir} do
      set_config(media_dir: nil)
      stamp = resumable!(dir, "20261101-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)
      %{stamp: stamp}
    end

    test "gives :deferred and changes nothing but the note, once per window", %{stamp: stamp} do
      s = due!()
      at = DateTime.utc_now()
      w = window(s, at)
      before = snapshot()

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:kiln_cms, :backups, :request, :folded]])

      assert {:ok, %{status: :deferred, claimed: [], deferred: [{id, ^w, reason, true}]}} =
               fire(s.id, at)

      assert id == s.id
      assert reason == {:queue_busy, {:resume, stamp}}

      assert snapshot() == before
      refute_received {[:kiln_cms, :backups, :request, :folded], ^ref, _, _}

      assert %{last_window_at: nil, last_deferred_window_at: ^w, last_outcome: :deferred} =
               reload(s)

      assert reload(s).last_error =~ "a resume of #{stamp} is queued"

      # The next tick in the same window: asked again, deferred again, not noted.
      assert {:ok, %{status: :deferred, deferred: [{_, ^w, _, false}]}} = fire(s.id, at)
      assert snapshot() == before
    end

    test "once the resume is promoted and the queue clears, the next call queues and claims the window",
         %{stamp: stamp} do
      s = due!()
      at = DateTime.utc_now()
      w = window(s, at)
      {:ok, %{status: :deferred}} = fire(s.id, at)

      # The running chain ends: the queued resume takes the lock.
      {:ok, _promoted} = Chain.with_lock(&Chain.release_in_txn/1)
      assert %{stamp: ^stamp, waiting: nil} = Backups.in_flight()

      assert {:ok, %{status: :queued, claimed: [{_, ^w}]}} = fire(s.id, at)
      assert %{last_window_at: ^w, last_outcome: :queued} = reload(s)
    end
  end

  describe "the media directory (W-d)" do
    test "a db+media schedule with no media directory backs up the database, reported as narrowed" do
      s = due!(%{components: [:db, :media]})
      set_config(media_dir: nil)

      assert {:ok, %{status: :started, narrowed: [id]}} = fire(s.id)
      assert id == s.id
      assert [%{args: %{"components" => ["db"], "scheduled" => ["db"]}}] = start_jobs()
    end

    test "a media-only schedule with no media directory is refused, and a db schedule due in the same tick fires" do
      media = due!(%{components: [:media]})
      db = due!()
      set_config(media_dir: nil)
      at = DateTime.utc_now()
      mw = window(media, at)

      assert {:ok, %{status: :started, refused: [{id, ^mw, :no_media_dir, true}], claimed: [_]}} =
               fire([media.id, db.id], at)

      assert id == media.id

      assert %{last_window_at: ^mw, last_outcome: :refused, last_error: "no_media_dir"} =
               reload(media)

      assert %{last_outcome: :started} = reload(db)
      assert [%{args: %{"schedule_ids" => [db_id]}}] = start_jobs()
      assert db_id == db.id
    end
  end

  describe "refused and failed windows" do
    test "W-g: BACKUP_ENABLED=false refuses every due window once; the next call does nothing" do
      a = due!()
      b = due!(%{time_of_day: ~T[01:00:00]})
      set_config(enabled: false)
      at = DateTime.utc_now()

      assert {:ok, %{status: :refused, refused: refused}} = fire([a.id, b.id], at)
      assert Enum.all?(refused, &match?({_, _, :disabled, true}, &1))
      assert length(refused) == 2

      assert %{last_window_at: %DateTime{}, last_outcome: :refused, last_error: "disabled"} =
               reload(a)

      assert {:ok, %{status: :nothing_due, refused: []}} = fire([a.id, b.id], at)
      assert start_jobs() == []
    end

    test "an unexpected error is deferred, not claimed" do
      s = due!()
      at = DateTime.utc_now()
      w = window(s, at)

      # A lock row this release can't read: the lock transaction raises.
      Backups.ensure_backup_lock!(%{}, actor: Backups.system())
      Repo.update_all(from(l in "backup_locks"), set: [phase: "exploded"])

      assert {:ok, %{status: :deferred, deferred: [{_, ^w, _reason, true}]}} = fire(s.id, at)

      assert %{last_window_at: nil, last_deferred_window_at: ^w} = reload(s)
      assert start_jobs() == []
    end

    test "a schedule whose window can't be computed is skipped as invalid while the others fire" do
      bad = force!(due!(), interval: "every_minute")
      good = due!()

      assert {:ok, %{status: :started, invalid: [bad_id], claimed: [{good_id, _}]}} =
               fire([bad.id, good.id])

      assert bad_id == bad.id
      assert good_id == good.id
      assert %{last_window_at: nil} = reload(bad)
    end

    test "missed windows are reported" do
      at = DateTime.utc_now()
      s = due!()
      s = force!(s, last_window_at: DateTime.add(window(s, at), -3 * 86_400, :second))

      assert {:ok, %{status: :started, missed: [id]}} = fire(s.id, at)
      assert id == s.id
    end

    test "a future at is refused" do
      s = due!()

      assert {:error, :future_at} =
               fire(s.id, DateTime.add(DateTime.utc_now(), 3600, :second))

      assert %{last_window_at: nil} = reload(s)
    end

    test "a failed schedule read returns {:error, {:schedules, _}} and writes nothing" do
      s = due!()
      system = Backups.system()

      assert {:error, {:schedules, Ash.Error.Forbidden}} =
               Backups.with_actor(KilnCMS.SystemActor.new(:firing), fn ->
                 Backups.request_scheduled([s.id], DateTime.utc_now(), system)
               end)

      assert %{last_window_at: nil, last_outcome: nil} = reload(s)
      assert start_jobs() == []
    end
  end
end
