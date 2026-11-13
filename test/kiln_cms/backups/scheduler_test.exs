defmodule KilnCMS.Backups.SchedulerTest do
  @moduledoc """
  The backup scheduler (part of #2219): ticks fire each window once, the
  next window again, nothing before a schedule's baseline, and only the
  latest window after downtime; a deferred window logs once while it is asked
  for every minute; the crontab entry and its switch.

  Ticks are driven with `Scheduler.tick/1` at chosen instants (in the past:
  `request_scheduled/3` refuses a future one). Real `pg_dump` and `tar` run
  where a chain is drained (`:pg_tools`). `async: false`: it changes the
  VM-wide backup config, `PATH`, the crontab key and a `persistent_term`
  rate limit.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Scheduler, WorkState}
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  @baseline ~U[2026-03-01 00:00:00.000000Z]

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bksc_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(media)
    File.write!(Path.join(media, "f.bin"), "media")

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: media, keep_days: 3650)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{dir: dir}
  end

  defp set_config(overrides) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups), overrides)
    )
  end

  defp due!(attrs \\ %{}), do: force!(schedule!(attrs), baseline_at: @baseline)

  defp reload(s), do: Backups.get_backup_schedule!(s.id, actor: Backups.system())

  defp start_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.queue == "backup_steps" and fragment("?->>'step' = 'start'", j.args)
      )
    )
  end

  defp runs, do: Backups.list_runs!(actor: Backups.system())

  defp events(names, fun) do
    ref =
      :telemetry_test.attach_event_handlers(
        self(),
        Enum.map(names, &[:kiln_cms, :backups, :schedule, &1])
      )

    fun.()
    :telemetry.detach(ref)
    collect(ref, [])
  end

  defp collect(ref, acc) do
    receive do
      {[:kiln_cms, :backups, :schedule, name], ^ref, %{count: n}, meta} ->
        collect(ref, [{name, n, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "windows" do
    test "two ticks in the same minute, and one 59 minutes later in the same daily window, fire once" do
      s = due!()

      for at <- [~U[2026-03-10 03:00:05Z], ~U[2026-03-10 03:00:40Z], ~U[2026-03-10 03:59:00Z]] do
        assert :ok = Scheduler.tick(at)
      end

      assert [_one] = start_jobs()
      assert %{last_window_at: ~U[2026-03-10 03:00:00.000000Z]} = reload(s)
    end

    test "the next day fires again" do
      s = due!()
      :ok = Scheduler.tick(~U[2026-03-10 03:00:05Z])
      BackupChain.drain()
      :ok = Scheduler.tick(~U[2026-03-11 03:00:05Z])

      assert length(start_jobs()) == 2
      assert %{last_window_at: ~U[2026-03-11 03:00:00.000000Z]} = reload(s)
    end

    test "a schedule created after today's occurrence first fires tomorrow" do
      s = force!(schedule!(), baseline_at: ~U[2026-03-10 05:00:00.000000Z])

      :ok = Scheduler.tick(~U[2026-03-10 06:00:00Z])
      assert start_jobs() == []
      assert %{last_window_at: nil} = reload(s)

      :ok = Scheduler.tick(~U[2026-03-11 03:00:30Z])
      assert [_] = start_jobs()
      assert %{last_window_at: ~U[2026-03-11 03:00:00.000000Z]} = reload(s)
    end

    test "missed: last_window_at three days back fires the latest window once and emits :missed" do
      s = force!(due!(), last_window_at: ~U[2026-03-07 03:00:00.000000Z])

      {received, log} =
        with_log(fn ->
          events([:missed, :fired], fn ->
            :ok = Scheduler.tick(~U[2026-03-10 09:00:00Z])
            :ok = Scheduler.tick(~U[2026-03-10 09:01:00Z])
          end)
        end)

      assert log =~ "missed earlier windows"
      assert [{:fired, 1, _}, {:missed, 1, %{schedule_ids: [id]}}] = received
      assert id == s.id
      assert [_] = start_jobs()
      assert %{last_window_at: ~U[2026-03-10 03:00:00.000000Z]} = reload(s)
    end

    test "no schedules: no request, no log" do
      assert capture_log(fn -> :ok = Scheduler.tick(~U[2026-03-10 03:00:05Z]) end) == ""
      assert start_jobs() == []
      assert runs() == []
    end
  end

  describe "outcomes" do
    test "deferred: five ticks in one window log one 'waits' line and emit five :deferred events",
         %{dir: dir} do
      set_config(media_dir: nil)
      stamp = "20261101-101010"

      run =
        Backups.start_run!(%{stamp: stamp, trigger: "manual", components: [:db]},
          actor: Backups.system()
        )

      Backups.fail_run!(run, %{error: "pg_dump exited 1"}, actor: Backups.system())
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))

      {:ok, %{status: :started}} = Backups.request([], Backups.system())
      {:ok, %{status: :queued}} = Backups.request([resume: stamp], Backups.system())
      s = due!()

      {received, log} =
        with_log(fn ->
          events([:deferred, :fired], fn ->
            for minute <- 0..4,
                do: :ok = Scheduler.tick(DateTime.add(~U[2026-03-10 03:00:05Z], minute * 60))
          end)
        end)

      assert length(Regex.scan(~r/waits: a resume of #{stamp} is queued/, log)) == 1
      assert Enum.map(received, &elem(&1, 0)) == List.duplicate(:deferred, 5)
      assert %{last_window_at: nil, last_outcome: :deferred} = reload(s)
    end

    test "refused logs once per window" do
      s = due!()
      set_config(enabled: false)

      {received, log} =
        with_log(fn ->
          events([:refused], fn ->
            :ok = Scheduler.tick(~U[2026-03-10 03:00:05Z])
            :ok = Scheduler.tick(~U[2026-03-10 03:01:05Z])
          end)
        end)

      assert length(Regex.scan(~r/can't run here: :disabled/, log)) == 1
      assert [{:refused, 1, _}] = received

      assert %{last_outcome: :refused, last_window_at: ~U[2026-03-10 03:00:00.000000Z]} =
               reload(s)
    end

    test "no pg_dump on this node: deferred every tick, logged once per window as this node's, never claimed" do
      s = due!()

      {received, log} =
        without_pg_tools(fn ->
          with_log(fn ->
            events([:deferred, :refused], fn ->
              :ok = Scheduler.tick(~U[2026-03-10 03:00:05Z])
              :ok = Scheduler.tick(~U[2026-03-10 03:01:05Z])
            end)
          end)
        end)

      assert length(Regex.scan(~r/waits: :no_pg_dump on this node/, log)) == 1
      refute log =~ "can't run here"
      assert [{:deferred, 1, _}, {:deferred, 1, _}] = received

      assert %{
               last_window_at: nil,
               last_outcome: :deferred,
               last_deferred_window_at: ~U[2026-03-10 03:00:00.000000Z]
             } = reload(s)

      # Back on a node with pg_dump, the same window fires.
      assert [{:fired, 1, _}] =
               events([:fired], fn -> :ok = Scheduler.tick(~U[2026-03-10 03:02:05Z]) end)
    end

    test "no media directory on this node: the narrowing and the media-only refusal say it is this node's configuration" do
      due!(%{components: [:db, :media]})
      due!(%{components: [:media]})
      set_config(media_dir: nil)

      {:ok, log} = with_log(fn -> Scheduler.tick(~U[2026-03-10 03:00:05Z]) end)

      assert log =~ "this node has no media directory configured (MEDIA_DIR): only the database"
      assert log =~ "can't run here: :no_media_dir (this node has no media directory configured"
    end

    test "an unreadable schedule list logs (rate-limited) and does nothing" do
      due!()
      :persistent_term.erase({Scheduler, :unreadable_warned_at})
      on_exit(fn -> :persistent_term.erase({Scheduler, :unreadable_warned_at}) end)

      {received, log} =
        with_log(fn ->
          events([:unreadable], fn ->
            Backups.with_actor(KilnCMS.SystemActor.new(:firing), fn ->
              :ok = Scheduler.tick(~U[2026-03-10 03:00:05Z])
              :ok = Scheduler.tick(~U[2026-03-10 03:01:05Z])
            end)
          end)
        end)

      assert length(Regex.scan(~r/Backup schedules were not checked/, log)) == 1
      assert [{:unreadable, 1, _}, {:unreadable, 1, _}] = received
      assert start_jobs() == []
    end

    test "an invalid schedule is skipped and reported while the others fire" do
      bad = force!(due!(), interval: "every_minute")
      good = due!()

      received =
        events([:invalid, :fired], fn -> :ok = Scheduler.tick(~U[2026-03-10 03:00:05Z]) end)

      assert [{:invalid, 1, %{schedule_ids: [bad_id]}}, {:fired, 1, %{schedule_ids: [good_id]}}] =
               received

      assert bad_id == bad.id
      assert good_id == good.id
    end
  end

  # #2219's done-when: a DB daily and a media weekly schedule fire correctly
  # across a deploy (duplicate ticks) and downtime.
  test "DB daily and media weekly over eight days, with downtime and duplicate ticks" do
    # 2026-03-02 is a Monday.
    db = force!(schedule!(%{components: [:db]}), baseline_at: @baseline)

    media =
      force!(
        schedule!(%{
          components: [:media],
          interval: :weekly,
          time_of_day: ~T[04:00:00],
          starts_on: ~D[2026-03-02]
        }),
        baseline_at: @baseline
      )

    days = Date.range(~D[2026-03-02], ~D[2026-03-09])
    # Nothing ran the scheduler on the 4th and the 5th.
    down = [~D[2026-03-04], ~D[2026-03-05]]

    for day <- days,
        day not in down,
        time <- [~T[03:00:30], ~T[03:01:00], ~T[04:00:30], ~T[04:00:45]] do
      :ok = Scheduler.tick(DateTime.new!(day, time, "Etc/UTC"))
      BackupChain.drain()
    end

    by_schedule = Enum.group_by(runs(), & &1.schedule_ids)

    assert length(by_schedule[[db.id]]) == 6
    assert Enum.all?(by_schedule[[db.id]], &(&1.scheduled_components == [:db]))
    assert Enum.all?(by_schedule[[db.id]], &(&1.trigger == "schedule"))

    assert length(by_schedule[[media.id]]) == 2
    assert Enum.all?(by_schedule[[media.id]], &(&1.scheduled_components == [:media]))
    assert map_size(by_schedule) == 2

    assert %{last_window_at: ~U[2026-03-09 03:00:00.000000Z]} = reload(db)
    assert %{last_window_at: ~U[2026-03-09 04:00:00.000000Z]} = reload(media)
  end

  describe "the crontab" do
    defp crontab do
      plugins = Keyword.fetch!(KilnCMS.Application.oban_config(), :plugins)
      {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
      opts[:crontab]
    end

    defp put_cron(value) do
      original = Application.fetch_env(:kiln_cms, :backup_scheduler_cron)
      Application.put_env(:kiln_cms, :backup_scheduler_cron, value)

      on_exit(fn ->
        case original do
          {:ok, old} -> Application.put_env(:kiln_cms, :backup_scheduler_cron, old)
          :error -> Application.delete_env(:kiln_cms, :backup_scheduler_cron)
        end
      end)
    end

    test "every minute by default, on its own entry" do
      assert {"* * * * *", Scheduler} = List.keyfind(crontab(), Scheduler, 1)
      assert Scheduler.enabled?()
    end

    test "KILN_BACKUP_SCHEDULER_CRON=false takes it off the crontab, and enabled? says so" do
      for off <- ["false", "off", "", "not a cron"] do
        put_cron(off)
        # An unparseable value warns on stderr at boot; `enabled?/0` is silent.
        capture_io(:stderr, fn -> refute List.keymember?(crontab(), Scheduler, 1) end)
        assert capture_io(:stderr, fn -> refute Scheduler.enabled?() end) == ""
      end
    end

    test "an override replaces the default" do
      put_cron("*/5 * * * *")
      assert {"*/5 * * * *", Scheduler} = List.keyfind(crontab(), Scheduler, 1)
    end

    test "one attempt on the scheduling queue" do
      opts = Scheduler.__opts__()
      assert opts[:queue] == :scheduling
      assert opts[:max_attempts] == 1
    end
  end
end
