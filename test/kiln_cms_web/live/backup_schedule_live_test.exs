defmodule KilnCMSWeb.BackupScheduleLiveTest do
  @moduledoc """
  The Schedule tab (`/editor/backups/schedules`, part of #2219): who may use
  it, the forms, what a schedule's card says, the warnings, and that a
  schedule the form can't offer is never re-submitted through it.

  `async: false`: the backup config (directory, media directory, enabled) and
  the scheduler's crontab key are VM-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.Test.BackupSchedules,
    only: [schedule!: 2, force!: 2, user: 1, site_admin: 0, platform_admin: 0]

  import Phoenix.LiveViewTest

  alias KilnCMS.Backups
  alias KilnCMSWeb.BackupScheduleLive

  @baseline ~U[2026-01-01 00:00:00.000000Z]

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bksl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil, keep_days: 14)
    )

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(signed_in(user))
  end

  # Signed in through the password strategy, as `BackupLiveTest` does, so the
  # session carries a real token. The fixtures' password.
  defp signed_in(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(user.email), "password" => "password123456"},
        []
      )

    user
  end

  defp mount(conn, user, locale \\ nil) do
    conn = log_in(conn, user)
    conn = if locale, do: Plug.Conn.put_session(conn, "locale", locale), else: conn
    {:ok, lv, _html} = live(conn, ~p"/editor/backups/schedules")
    settle(lv)
  end

  # `Backups.status/0` is read in the background (#2986), on mount and after
  # each write: wait for the read to land.
  # A read that lands after a reload was asked for starts one more from
  # `handle_async/3`, so this waits until no read is running.
  defp settle(lv) do
    render_async(lv, 2_000)

    if :sys.get_state(lv.pid).socket.assigns.status_running?,
      do: settle(lv),
      else: lv
  end

  defp put_backups(key, value) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), key, value)
    )
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

  defp stored(schedule), do: Backups.get_backup_schedule!(schedule.id, actor: Backups.system())

  defp events(type) do
    KilnCMS.Security.list_instance_events!(actor: platform_admin(), page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  # A backup host cron made here `hours` ago, as the importer records one.
  defp cron_import!(components, hours) do
    at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    stamp = KilnCMS.Backups.Artifact.stamp(at)

    Backups.import_run!(
      %{
        stamp: stamp,
        trigger: "cron",
        status: :succeeded,
        components: components,
        started_at: at,
        finished_at: at,
        artifacts:
          for(
            c <- components,
            do: %{kind: c, name: "kiln-#{c}-#{stamp}", bytes: 10, verified: true}
          )
      },
      actor: Backups.system()
    )
  end

  defp assert_keep_host_hint(lv) do
    assert has_element?(
             lv,
             "#schedule-keep #schedule-keep-host-hint",
             "If host cron prunes this backup directory, its scripts/backup.sh must be from " <>
               "this release"
           )

    assert has_element?(
             lv,
             ~s|#schedule-keep-host-hint a[href$="backups.md#the-hold-markers"]|
           )
  end

  defp all_schedules, do: Backups.list_backup_schedules!(actor: Backups.system())

  defp form_params(overrides) do
    Map.merge(
      %{
        "components" => ["", "db"],
        "interval" => "daily",
        "time_of_day" => "04:15",
        "starts_on" => "2026-02-01",
        "time_zone" => "Etc/UTC",
        "enabled" => "true"
      },
      overrides
    )
  end

  # A Scheduler job that started at `at`, as Oban records one.
  defp tick_at!(at) do
    KilnCMS.Repo.insert!(%Oban.Job{
      worker: "KilnCMS.Backups.Scheduler",
      queue: "scheduling",
      args: %{},
      state: "completed",
      attempted_at: at,
      completed_at: at
    })
  end

  describe "who can use it" do
    test "anonymous is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/backups/schedules")
    end

    test "an editor and a viewer are turned away", %{conn: conn} do
      for role <- [:editor, :viewer] do
        assert {:error, {:redirect, _}} =
                 conn |> log_in(user(role)) |> live(~p"/editor/backups/schedules")
      end
    end

    # The route's gate is a per-org admin tier; a schedule is instance-wide.
    test "an org admin who is not a platform admin is turned away by the page itself",
         %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/access-denied?needs=platform"}}} =
               conn |> log_in(site_admin()) |> live(~p"/editor/backups/schedules")
    end

    test "a platform admin gets the tab, marked current", %{conn: conn} do
      lv = mount(conn, platform_admin())

      assert has_element?(lv, "#backup-tab-schedule[aria-current=page]", "Schedule")
      assert has_element?(lv, "#backup-tab-history[href='/editor/backups']", "Backups")
      refute has_element?(lv, "#backup-tab-history[aria-current]")
    end
  end

  # Called directly: a refused mount leaves no socket to push events down, so
  # the question is what each handler does on its own with a socket whose
  # user is not a platform admin.
  # A user who stopped being a platform admin mid-session (#2875) is sent to
  # the access-denied page by every handler, as the mount would have, and
  # nothing is written first: an editor, and a former admin whose grant has
  # expired.
  describe "each handler refuses a socket that isn't a platform admin's" do
    setup do
      schedule = schedule!(%{}, platform_admin())

      expired = %{
        role: :editor,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      # The premise: the same grant, still live, would pass.
      assert KilnCMSWeb.LiveUserAuth.platform_admin_user?(%{
               expired
               | granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
             })

      sockets =
        for user <- [%{role: :editor}, expired] do
          %Phoenix.LiveView.Socket{
            assigns: %{
              __changed__: %{},
              flash: %{},
              current_user: user,
              form: nil,
              editing: nil
            }
          }
        end

      %{schedule: schedule, sockets: sockets}
    end

    defp assert_denied({:noreply, socket}) do
      assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = socket.redirected
      assert socket.assigns.flash == %{}
    end

    # The form was opened while they were a platform admin, so it carries
    # that actor: the handler's own check is what stands in front of it.
    test "save and validate create nothing, even with a form opened earlier", %{sockets: sockets} do
      form =
        KilnCMS.Backups.Schedule
        |> AshPhoenix.Form.for_create(:create, actor: platform_admin(), as: "schedule")
        |> Phoenix.Component.to_form()

      params = %{"schedule" => form_params(%{})}

      for socket <- sockets do
        socket = %{socket | assigns: %{socket.assigns | form: form, editing: :new}}

        for event <- ["validate", "save", "new", "cancel"] do
          assert_denied(BackupScheduleLive.handle_event(event, params, socket))
        end
      end

      assert length(all_schedules()) == 1
    end

    test "a sub-daily save with its keep days creates nothing (#2219)", %{sockets: sockets} do
      form =
        KilnCMS.Backups.Schedule
        |> AshPhoenix.Form.for_create(:create, actor: platform_admin(), as: "schedule")
        |> Phoenix.Component.to_form()

      params = %{"schedule" => form_params(%{"interval" => "every_2h", "keep_days" => "3"})}

      for socket <- sockets do
        socket = %{socket | assigns: %{socket.assigns | form: form, editing: :new}}
        assert_denied(BackupScheduleLive.handle_event("save", params, socket))
      end

      assert [%{interval: :daily}] = all_schedules()
    end

    test "toggle, delete and edit leave the schedule as it was", %{
      schedule: s,
      sockets: sockets
    } do
      for socket <- sockets, event <- ["toggle", "delete", "edit"] do
        assert_denied(BackupScheduleLive.handle_event(event, %{"id" => s.id}, socket))
      end

      assert stored(s).enabled
    end

    test "handle_params and the refresh send them away", %{sockets: sockets} do
      for socket <- sockets do
        assert_denied(BackupScheduleLive.handle_params(%{}, "/editor/backups/schedules", socket))

        # Sent away rather than re-armed: no `load/1` (it would need assigns
        # this socket doesn't have) and no next refresh.
        assert_denied(BackupScheduleLive.handle_info(:refresh, socket))
        refute_received :refresh
      end
    end

    # #2986: a status read the page started while they were an admin lands
    # after they stopped being one. Nothing of it is applied.
    test "the background status read and its timeout give them nothing", %{sockets: sockets} do
      status = Backups.status()

      for socket <- sockets do
        for reply <- [
              BackupScheduleLive.handle_async(:status, {:ok, status}, socket),
              BackupScheduleLive.handle_async(:status, {:exit, :boom}, socket),
              BackupScheduleLive.handle_info({:status_timeout, make_ref()}, socket)
            ] do
          assert_denied(reply)
          {:noreply, denied} = reply

          for key <- [:status, :entries, :runs, :stale_tick, :status_state] do
            refute Map.has_key?(denied.assigns, key)
          end
        end
      end
    end

    test "a connected page whose admin lost the role is sent away on the next click", %{
      conn: conn,
      schedule: s
    } do
      admin = platform_admin()
      lv = mount(conn, admin)

      :sys.replace_state(lv.pid, fn state ->
        update_in(
          state.socket,
          &Phoenix.Component.assign(&1, :current_user, %{admin | role: :editor})
        )
      end)

      assert {:error, {:live_redirect, %{to: "/access-denied?needs=platform"}}} =
               lv |> element("#backup-schedule-#{s.id} [data-role=toggle]") |> render_click()

      assert stored(s).enabled
    end
  end

  describe "adding, editing, pausing, resuming and deleting" do
    test "a new schedule is saved as entered, with a live preview", %{conn: conn} do
      lv = mount(conn, platform_admin())

      lv |> element("#schedule-new") |> render_click()
      assert has_element?(lv, "#schedule-form")

      # 2026-02-03 is a Tuesday.
      lv
      |> form("#schedule-form",
        schedule: form_params(%{"interval" => "weekly", "starts_on" => "2026-02-03"})
      )
      |> render_change()

      assert has_element?(
               lv,
               "#schedule-preview [data-role=cadence]",
               "Every week on Tuesday at 04:15 (Etc/UTC)"
             )

      assert has_element?(lv, "#schedule-preview [data-role=first]", "Next backup:")

      lv
      |> form("#schedule-form",
        schedule: form_params(%{"interval" => "weekly", "starts_on" => "2026-02-03"})
      )
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      refute has_element?(lv, "#schedule-form")

      assert [s] = all_schedules()
      assert s.interval == :weekly
      assert s.components == [:db]
      assert s.time_of_day == ~T[04:15:00]
      assert s.starts_on == ~D[2026-02-03]
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=cadence]", "Tuesday")
    end

    test "the form shows the time as HH:MM and the zone suggestions", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{time_of_day: ~T[02:30:00], time_zone: "Pacific/Chatham"}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()

      assert has_element?(lv, "#schedule-form input[type=time][value='02:30']")
      assert has_element?(lv, "#schedule-form input[list=schedule-time-zones]")
      assert has_element?(lv, "#schedule-time-zones option[value='Pacific/Chatham']")
      assert has_element?(lv, "#schedule-time-zones option[value='America/New_York']")

      assert has_element?(
               lv,
               "#schedule-time-zones option[value='#{KilnCMS.Events.default_time_zone()}']"
             )
    end

    test "an edit is saved and flashed", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()

      lv
      |> form("#schedule-form", schedule: form_params(%{"interval" => "monthly"}))
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      assert stored(s).interval == :monthly
    end

    test "pause, resume and delete flash and persist; delete asks first", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=toggle]", "Pause") |> render_click()
      assert render(lv) =~ "Schedule paused."
      settle(lv)
      refute stored(s).enabled
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=paused]", "Paused")

      lv |> element("#backup-schedule-#{s.id} [data-role=toggle]", "Resume") |> render_click()
      assert render(lv) =~ "Schedule resumed."
      settle(lv)
      assert stored(s).enabled

      assert has_element?(
               lv,
               ~s|#backup-schedule-#{s.id} [data-role=delete][data-confirm*="age out after 14 days (BACKUP_KEEP_DAYS)"]|
             )

      lv |> element("#backup-schedule-#{s.id} [data-role=delete]") |> render_click()
      assert render(lv) =~ "Schedule deleted."
      settle(lv)
      assert all_schedules() == []
      refute has_element?(lv, "#backup-schedule-#{s.id}")
    end

    test "delete says the backups then age out under BACKUP_KEEP_DAYS, never sooner",
         %{conn: conn} do
      admin = platform_admin()
      plain = schedule!(%{}, admin)
      keeping = schedule!(%{keep_count: 3, keep_days: 3}, admin)
      lv = mount(conn, admin)

      assert has_element?(
               lv,
               ~s|#backup-schedule-#{plain.id} [data-role=delete][data-confirm*="age out after 14 days (BACKUP_KEEP_DAYS), never sooner"]|
             )

      refute has_element?(
               lv,
               ~s|#backup-schedule-#{plain.id} [data-role=delete][data-confirm*="keep settings"]|
             )

      assert has_element?(
               lv,
               ~s|#backup-schedule-#{keeping.id} [data-role=delete][data-confirm*="Its keep settings stop applying"]|
             )

      assert has_element?(
               lv,
               ~s|#backup-schedule-#{keeping.id} [data-role=delete][data-confirm*="never sooner"]|
             )
    end
  end

  describe "keep fields" do
    test "are offered, optional, and empty by default", %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      assert has_element?(lv, "#schedule-keep input[name='schedule[keep_count]'][type=number]")
      assert has_element?(lv, "#schedule-keep input[name='schedule[keep_days]'][type=number]")
      refute has_element?(lv, "#schedule-keep input[name='schedule[keep_count]'][value]")
      assert has_element?(lv, "#schedule-keep", "BACKUP_KEEP_DAYS, 14 days on this deployment")
    end

    # #2931: always there, whatever the preview says, in both forms.
    test "always say host cron needs this release's backup.sh", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#schedule-new") |> render_click()
      assert_keep_host_hint(lv)
      lv |> element("#schedule-form button", "Cancel") |> render_click()

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      assert_keep_host_hint(lv)
    end

    test "are saved, audited, shown on the card, and cleared by emptying them", %{conn: conn} do
      admin = platform_admin()
      lv = mount(conn, admin)
      lv |> element("#schedule-new") |> render_click()

      lv
      |> form("#schedule-form",
        schedule: form_params(%{"keep_count" => "7", "keep_days" => "30"})
      )
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      assert [s] = all_schedules()
      assert {s.keep_count, s.keep_days} == {7, 30}
      assert [created] = events(:backup_schedule_created)
      assert created.metadata["keep_count"] == 7
      assert created.metadata["keep_days"] == 30

      assert has_element?(
               lv,
               "#backup-schedule-#{s.id} [data-role=keep]",
               "Keeps its newest 7 backups, and every one from the last 30 days"
             )

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      assert has_element?(lv, "#schedule-form input[name='schedule[keep_count]'][value='7']")

      lv
      |> form("#schedule-form", schedule: form_params(%{"keep_count" => "", "keep_days" => ""}))
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      assert {nil, nil} == {stored(s).keep_count, stored(s).keep_days}

      assert [changed] = events(:backup_schedule_changed)
      assert changed.metadata["changed"] =~ "keep_count"
      assert changed.metadata["keep_count_before"] == 7
      assert changed.metadata["keep_count_after"] == nil

      assert has_element?(
               lv,
               "#backup-schedule-#{s.id} [data-role=keep]",
               "Keeps its backups for 14 days (BACKUP_KEEP_DAYS)"
             )
    end

    test "keep days shorter than the interval, with no count, is refused under the field",
         %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      lv
      |> form("#schedule-form",
        schedule: form_params(%{"interval" => "weekly", "keep_days" => "3"})
      )
      |> render_submit()

      assert has_element?(
               lv,
               "#schedule-form #schedule_keep_days-error",
               "at least as long as the schedule's interval"
             )

      assert all_schedules() == []
    end

    test "the preview estimates what is kept at a time, counting the run in flight",
         %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      # Daily under BACKUP_KEEP_DAYS (14): 14 days back, plus the new one.
      preview_of(lv, %{})
      assert has_element?(lv, "#schedule-preview [data-role=estimate]", "about 15 backups")
      assert has_element?(lv, "#schedule-preview [data-role=estimate]", "Database")

      # Keep the newest 30: N + 1.
      preview_of(lv, %{"keep_count" => "30"})
      assert has_element?(lv, "#schedule-preview [data-role=estimate]", "about 31 backups")

      # Weekly, 28 days: four weeks back, plus the new one.
      preview_of(lv, %{"interval" => "weekly", "keep_count" => "", "keep_days" => "28"})
      assert has_element?(lv, "#schedule-preview [data-role=estimate]", "about 5 backups")
    end

    test "estimate/3 never says fewer than two" do
      assert BackupScheduleLive.estimate(:monthly, nil, 14) == 2
      assert BackupScheduleLive.estimate(:monthly, 1, 31) == 2
      assert BackupScheduleLive.estimate(:daily, 3, 2) == 4
      assert BackupScheduleLive.estimate(:fortnightly, nil, 60) == 5
    end

    test "keep days shorter than BACKUP_KEEP_DAYS says so; equal or longer doesn't",
         %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      preview_of(lv, %{"keep_days" => "5"})

      assert has_element?(
               lv,
               "#schedule-preview [data-role=keep-shorter]",
               "age out after 5 days, sooner than BACKUP_KEEP_DAYS (14)"
             )

      for days <- ["", "14", "30"] do
        preview_of(lv, %{"keep_days" => days})
        refute has_element?(lv, "#schedule-preview [data-role=keep-shorter]")
      end
    end

    test "keeping past BACKUP_KEEP_DAYS while host cron backs up here asks for the new backup.sh",
         %{conn: conn} do
      cron_import!([:db], 30)
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      # Within BACKUP_KEEP_DAYS: nothing for cron to delete.
      # Both keys every time: the form keeps whatever the last change left.
      for {count, days} <- [{"", ""}, {"", "10"}, {"14", ""}, {"14", "14"}] do
        preview_of(lv, %{"keep_count" => count, "keep_days" => days})
        refute has_element?(lv, "#schedule-preview [data-role=keep-cron]")
      end

      for {count, days} <- [{"", "30"}, {"15", ""}] do
        preview_of(lv, %{"keep_count" => count, "keep_days" => days})

        assert has_element?(
                 lv,
                 "#schedule-preview [data-role=keep-cron]",
                 "Replace the host's scripts/backup.sh"
               )

        assert has_element?(lv, "#schedule-preview [data-role=keep-cron]", "Database")
      end
    end

    test "without host cron backing up here, a long keep needs no backup.sh notice",
         %{conn: conn} do
      # Older than the eight days that count as "backs up here".
      cron_import!([:db], 24 * 20)
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      preview_of(lv, %{"keep_days" => "60", "keep_count" => "100"})
      assert has_element?(lv, "#schedule-preview [data-role=estimate]")
      refute has_element?(lv, "#schedule-preview [data-role=keep-cron]")
    end

    test "the keep notice is translated", %{conn: conn} do
      lv = mount(conn, platform_admin(), "fr")
      lv |> element("#schedule-new") |> render_click()

      preview_of(lv, %{"keep_days" => "5"})

      assert has_element?(
               lv,
               "#schedule-preview [data-role=keep-shorter]",
               "BACKUP_KEEP_DAYS (14)"
             )

      refute has_element?(lv, "#schedule-preview [data-role=keep-shorter]", "sooner than")
      assert has_element?(lv, "#schedule-preview [data-role=keep-shorter]", "5 jours")
    end
  end

  describe "the form's preview says when it won't run" do
    defp preview_of(lv, overrides) do
      lv |> form("#schedule-form", schedule: form_params(overrides)) |> render_change()
    end

    test "unchecking Enabled: no next backup, it says it won't run", %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      preview_of(lv, %{})
      assert has_element?(lv, "#schedule-preview [data-role=first]", "Next backup:")

      preview_of(lv, %{"enabled" => "false"})
      assert has_element?(lv, "#schedule-preview [data-role=cadence]")
      refute has_element?(lv, "#schedule-preview [data-role=first]")
      assert has_element?(lv, "#schedule-preview [data-role=wont-run]", "paused")
    end

    test "the scheduler off: no next backup", %{conn: conn} do
      put_cron("false")
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      preview_of(lv, %{})
      refute has_element?(lv, "#schedule-preview [data-role=first]")
      assert has_element?(lv, "#schedule-preview [data-role=wont-run]", "warning above")
    end

    test "backups that can't run here: no next backup", %{conn: conn} do
      put_backups(:enabled, false)
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      preview_of(lv, %{})
      refute has_element?(lv, "#schedule-preview [data-role=first]")
      assert has_element?(lv, "#schedule-preview [data-role=wont-run]", "warning above")
    end
  end

  # E6: the client names a schedule by id; the handler reads it again.
  describe "a schedule that changed or went away meanwhile" do
    test "a deleted schedule's buttons say so instead of crashing", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      :ok = Backups.destroy_backup_schedule(s, actor: admin)

      for event <- ["toggle", "delete", "edit"] do
        assert render_click(lv, event, %{"id" => s.id}) =~ "That schedule no longer exists."
      end

      settle(lv)

      refute has_element?(lv, "#backup-schedule-#{s.id}")
    end

    test "a forged id is no schedule", %{conn: conn} do
      lv = mount(conn, platform_admin())

      assert render_click(lv, "toggle", %{"id" => Ecto.UUID.generate()}) =~
               "That schedule no longer exists."

      assert render_click(lv, "delete", %{"id" => "not-a-uuid"}) =~
               "That schedule no longer exists."
    end

    test "saving an edit whose schedule was deleted closes the form", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      :ok = Backups.destroy_backup_schedule(s, actor: admin)

      html = lv |> form("#schedule-form", schedule: form_params(%{})) |> render_submit()

      assert html =~ "That schedule no longer exists."
      settle(lv)
      refute has_element?(lv, "#schedule-form")
      assert all_schedules() == []
    end

    # A form opened before another admin's change would overwrite it with
    # what it still shows: the save is refused instead.
    # The refused form stays open on the stored values, with what was typed
    # shown beside them (#2875).
    test "an edit whose schedule another admin changed meanwhile is refused, keeping what was typed",
         %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()

      Backups.update_backup_schedule!(s, %{time_of_day: ~T[05:00:00], keep_count: 4},
        actor: platform_admin()
      )

      html =
        lv
        |> form("#schedule-form",
          schedule: form_params(%{"time_of_day" => "03:30", "keep_days" => "20"})
        )
        |> render_submit()

      assert html =~ "This schedule changed since you opened it"
      settle(lv)
      assert stored(s).time_of_day == ~T[05:00:00]
      assert stored(s).keep_days == nil

      # The form stays, on the stored values.
      assert has_element?(lv, "#schedule-form input[type=time][value='05:00']")
      assert has_element?(lv, "#schedule-form input[name='schedule[keep_count]'][value='4']")

      # What was typed, beside what is stored, differences marked.
      panel = "#schedule-refused-values"
      assert has_element?(lv, "#{panel} tr[data-field=time_of_day] [data-role=yours]", "03:30")
      assert has_element?(lv, "#{panel} tr[data-field=time_of_day] [data-role=stored]", "05:00")
      assert has_element?(lv, "#{panel} tr[data-field=time_of_day][data-differs]")
      assert has_element?(lv, "#{panel} tr[data-field=keep_days] [data-role=yours]", "20")
      assert has_element?(lv, "#{panel} tr[data-field=keep_days] [data-role=stored]", "Not set")
      assert has_element?(lv, "#{panel} tr[data-field=keep_count] [data-role=yours]", "Not set")
      assert has_element?(lv, "#{panel} tr[data-field=keep_count] [data-role=stored]", "4")
      assert has_element?(lv, "#{panel} tr[data-field=keep_count][data-differs]")
      refute has_element?(lv, "#{panel} tr[data-field=interval][data-differs]")

      # Saving again is now compared with what the form was rebuilt on, and
      # goes through; the panel goes with it.
      lv
      |> form("#schedule-form",
        schedule: form_params(%{"time_of_day" => "03:30", "keep_days" => "20"})
      )
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      refute has_element?(lv, panel)
      refute has_element?(lv, "#schedule-form")
      assert stored(s).time_of_day == ~T[03:30:00]
      assert stored(s).keep_days == 20
    end

    test "Cancel clears a refused save's typed values", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      Backups.update_backup_schedule!(s, %{keep_days: 9}, actor: platform_admin())
      lv |> form("#schedule-form", schedule: form_params(%{})) |> render_submit()
      assert has_element?(lv, "#schedule-refused-values")

      lv |> element("#schedule-form button", "Cancel") |> render_click()
      refute has_element?(lv, "#schedule-refused-values")

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      refute has_element?(lv, "#schedule-refused-values")
    end

    # Rendered as text, never as markup.
    test "the typed values are escaped", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      Backups.update_backup_schedule!(s, %{keep_days: 9}, actor: platform_admin())

      html =
        render_submit(lv, "save", %{
          "schedule" =>
            form_params(%{
              "time_zone" => "<script>alert(1)</script>",
              "components" => ["", "<b>x</b>"]
            })
        })

      refute html =~ "<script>alert(1)</script>"
      refute html =~ "<b>x</b>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"

      assert has_element?(
               lv,
               "#schedule-refused-values tr[data-field=time_zone] [data-role=yours]",
               "<script>"
             )
    end

    test "a save does not resume a schedule another admin paused meanwhile", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      Backups.update_backup_schedule!(s, %{enabled: false}, actor: platform_admin())

      html =
        lv
        |> form("#schedule-form", schedule: form_params(%{"interval" => "weekly"}))
        |> render_submit()

      assert html =~ "This schedule changed since you opened it"
      settle(lv)
      after_save = stored(s)
      refute after_save.enabled
      assert after_save.interval == :daily

      # The form shows it paused, and what was typed says enabled.
      refute has_element?(lv, "#schedule-form input[name='schedule[enabled]'][checked]")

      assert has_element?(
               lv,
               "#schedule-refused-values tr[data-field=enabled][data-differs] [data-role=stored]",
               "Paused"
             )

      assert has_element?(
               lv,
               "#schedule-refused-values tr[data-field=interval] [data-role=yours]",
               "Every week"
             )
    end

    # The scheduler writes the window's claim on the row while the form is
    # open; that is not an edit, and the save goes through.
    test "the scheduler's own writes don't refuse a save", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      force!(s, last_outcome: "started", last_window_at: DateTime.utc_now())

      lv
      |> form("#schedule-form", schedule: form_params(%{"interval" => "monthly"}))
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      assert stored(s).interval == :monthly
    end

    test "an id in capitals is the same schedule as the form's", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      render_click(lv, "edit", %{"id" => String.upcase(s.id)})
      assert has_element?(lv, "#schedule-form")
      assert has_element?(lv, "#backup-schedule-#{s.id}.bg-base-200\\/40")

      # Deleting it closes the form it was open in.
      lv |> element("#backup-schedule-#{s.id} [data-role=delete]") |> render_click()
      refute has_element?(lv, "#schedule-form")
      assert all_schedules() == []
    end

    test "while a form is open, Add and Edit are hidden and ignored", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      other = schedule!(%{time_of_day: ~T[05:00:00]}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()

      refute has_element?(lv, "#schedule-new")
      refute has_element?(lv, "[data-role=edit]")

      lv
      |> form("#schedule-form", schedule: form_params(%{"time_of_day" => "07:45"}))
      |> render_change()

      # A click already on its way doesn't replace the open form.
      render_click(lv, "edit", %{"id" => other.id})
      render_click(lv, "new", %{})
      assert has_element?(lv, "#schedule-form input[type=time][value='07:45']")
      assert has_element?(lv, "#schedule-form-panel h2", "Edit schedule")

      lv |> element("#schedule-form button", "Cancel") |> render_click()
      assert has_element?(lv, "#schedule-new")
      assert has_element?(lv, "#backup-schedule-#{other.id} [data-role=edit]")
    end

    test "the minute's refresh leaves an open form as it is", %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      lv
      |> form("#schedule-form", schedule: form_params(%{"time_zone" => "Europe/Paris"}))
      |> render_change()

      send(lv.pid, :refresh)

      assert has_element?(
               lv,
               "#schedule-form input[name='schedule[time_zone]'][value='Europe/Paris']"
             )
    end
  end

  # E1: what the form can't offer, it never re-submits.
  describe "a schedule the form can't offer" do
    defp assert_locked(lv, s) do
      refute has_element?(lv, "#backup-schedule-#{s.id} [data-role=edit]")
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=locked]")
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=toggle]")
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=delete]")

      assert render_click(lv, "edit", %{"id" => s.id}) =~ "can only be paused, resumed or deleted"
      refute has_element?(lv, "#schedule-form")
    end

    test "a component this release doesn't know", %{conn: conn} do
      admin = platform_admin()
      s = force!(schedule!(%{}, admin), components: ["db", "cloud"])
      before = stored(s)
      lv = mount(conn, admin)

      assert_locked(lv, s)
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=locked]", "A newer release")
      assert stored(s) == before
    end

    test "an interval this release doesn't know", %{conn: conn} do
      admin = platform_admin()
      s = force!(schedule!(%{}, admin), interval: "every_90m")
      lv = mount(conn, admin)

      assert_locked(lv, s)
      assert %KilnCMS.Types.UnknownAtom{value: "every_90m"} = stored(s).interval
    end

    test "media on a deployment that no longer archives it", %{conn: conn} do
      admin = platform_admin()
      put_backups(:media_dir, System.tmp_dir!())
      s = schedule!(%{components: [:db, :media]}, admin)
      put_backups(:media_dir, nil)
      before = stored(s)
      lv = mount(conn, admin)

      assert_locked(lv, s)
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=locked]", "backs up media")
      assert stored(s) == before
    end

    test "an open edit is refused when the stored row became one", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      force!(s, interval: "every_90m")
      before = stored(s)

      html = lv |> form("#schedule-form", schedule: form_params(%{})) |> render_submit()

      assert html =~ "can only be paused, resumed or deleted"
      refute has_element?(lv, "#schedule-form")
      assert stored(s) == before
    end
  end

  describe "sub-daily schedules (#2219)" do
    test "the form offers them, shortest first", %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      options =
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("#schedule-form select[name='schedule[interval]'] option")
        |> Floki.attribute("value")

      assert options ==
               ~w(every_2h every_4h every_8h every_12h daily weekly fortnightly monthly)
    end

    test "Keep for (days) is required, with hints, only while the interval is sub-daily",
         %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      refute has_element?(lv, "#schedule-keep input[name='schedule[keep_days]'][required]")
      assert has_element?(lv, "#schedule-keep", "Empty keeps them for BACKUP_KEEP_DAYS")
      refute has_element?(lv, "#schedule-form", "the others follow every")

      preview_of(lv, %{"interval" => "every_4h"})

      assert has_element?(lv, "#schedule-keep input[name='schedule[keep_days]'][required]")

      assert has_element?(
               lv,
               "#schedule-keep",
               "Required for a schedule that runs more often than daily."
             )

      refute has_element?(lv, "#schedule-keep", "Empty keeps them for BACKUP_KEEP_DAYS")

      assert has_element?(
               lv,
               "#schedule-form",
               "One backup at this time, and the others every 4 hours around the clock."
             )

      preview_of(lv, %{"interval" => "weekly"})
      refute has_element?(lv, "#schedule-keep input[name='schedule[keep_days]'][required]")
    end

    test "adding one without Keep for (days) shows the error and saves nothing; with it, saves",
         %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      params = %{"interval" => "every_2h", "time_of_day" => "03:00", "keep_days" => ""}
      lv |> form("#schedule-form", schedule: form_params(params)) |> render_submit()

      assert has_element?(
               lv,
               "#schedule-form #schedule_keep_days-error",
               "is required for a schedule that runs more often than daily"
             )

      assert all_schedules() == []

      lv
      |> form("#schedule-form", schedule: form_params(%{params | "keep_days" => "2"}))
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      assert [%{interval: :every_2h, keep_days: 2} = s] = all_schedules()

      assert has_element?(
               lv,
               "#backup-schedule-#{s.id} [data-role=cadence]",
               "Every 2 hours from 03:00 (Etc/UTC)"
             )

      refute has_element?(lv, "#backup-schedule-#{s.id} [data-role=locked]")
      refute has_element?(lv, "#backup-schedule-#{s.id} [data-role=needs-keep-days]")
    end

    test "one with Keep for (days) is edited and saved like any other", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{interval: :every_8h, keep_days: 3}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()

      lv
      |> form("#schedule-form",
        schedule: form_params(%{"interval" => "every_12h", "keep_days" => "3"})
      )
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      assert %{interval: :every_12h, keep_days: 3} = stored(s)
    end

    # Written from a console, or by a release that allowed it: it keeps
    # firing on BACKUP_KEEP_DAYS, and must stay pausable and deletable.
    test "one stored without Keep for (days): not locked, says so, pauses, and saves only with it",
         %{conn: conn} do
      admin = platform_admin()
      s = force!(schedule!(%{}, admin), interval: "every_2h")
      before = stored(s)
      lv = mount(conn, admin)

      refute has_element?(lv, "#backup-schedule-#{s.id} [data-role=locked]")

      assert has_element?(
               lv,
               "#backup-schedule-#{s.id} [data-role=needs-keep-days]",
               "Set Keep for (days) to edit it"
             )

      # Pausing writes `enabled` alone.
      lv |> element("#backup-schedule-#{s.id} [data-role=toggle]") |> render_click()
      paused = stored(s)
      refute paused.enabled

      assert Map.drop(paused, [:enabled, :updated_at]) ==
               Map.drop(before, [:enabled, :updated_at])

      lv |> element("#backup-schedule-#{s.id} [data-role=toggle]") |> render_click()
      assert stored(s).enabled
      settle(lv)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      assert has_element?(lv, "#schedule-form")
      refute has_element?(lv, "#schedule-keep input[name='schedule[keep_days]'][value]")
      assert has_element?(lv, "#schedule-keep input[name='schedule[keep_days]'][required]")

      params = %{"interval" => "every_2h", "time_of_day" => "05:00", "keep_days" => ""}
      lv |> form("#schedule-form", schedule: form_params(params)) |> render_submit()

      assert has_element?(lv, "#schedule-form #schedule_keep_days-error", "is required")
      assert %{keep_days: nil} = unsaved = stored(s)
      assert Time.compare(unsaved.time_of_day, ~T[03:00:00]) == :eq

      lv
      |> form("#schedule-form", schedule: form_params(%{params | "keep_days" => "3"}))
      |> render_submit()

      assert render(lv) =~ "Schedule saved."
      settle(lv)
      assert %{interval: :every_2h, keep_days: 3} = stored(s)
      refute has_element?(lv, "#backup-schedule-#{s.id} [data-role=needs-keep-days]")

      s = force!(s, keep_days: nil)
      lv |> element("#backup-schedule-#{s.id} [data-role=delete]") |> render_click()
      assert all_schedules() == []
    end

    test "the preview counts the backups kept in hours: two-hourly for 7 days is about 85",
         %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      preview_of(lv, %{"interval" => "every_2h", "keep_days" => "7"})

      assert has_element?(
               lv,
               "#schedule-preview [data-role=cadence]",
               "Every 2 hours from 04:15 (Etc/UTC)"
             )

      assert has_element?(lv, "#schedule-preview [data-role=estimate]", "about 85 backups")
    end

    test "estimate/3 in hours; daily and longer unchanged" do
      assert BackupScheduleLive.estimate(:every_2h, nil, 7) == 85
      assert BackupScheduleLive.estimate(:every_4h, nil, 7) == 43
      assert BackupScheduleLive.estimate(:every_8h, nil, 1) == 4
      assert BackupScheduleLive.estimate(:every_12h, 30, 1) == 31
      assert BackupScheduleLive.estimate(:daily, nil, 14) == 15
      assert BackupScheduleLive.estimate(:weekly, nil, 28) == 5
      assert BackupScheduleLive.estimate(:monthly, nil, 62) == 3
      assert BackupScheduleLive.estimate(%KilnCMS.Types.UnknownAtom{value: "x"}, nil, 14) == 15
    end

    test "beyond_default?/4 measures a keep count in hours" do
      # 100 two-hourly backups reach back 200 hours: under 14 days.
      refute BackupScheduleLive.beyond_default?(:every_2h, 100, nil, 14)
      # 200 reach back 400 hours: past 14 days.
      assert BackupScheduleLive.beyond_default?(:every_2h, 200, nil, 14)
      refute BackupScheduleLive.beyond_default?(:daily, 14, 14, 14)
      assert BackupScheduleLive.beyond_default?(:daily, 15, nil, 14)
      assert BackupScheduleLive.beyond_default?(:weekly, 3, nil, 14)
      assert BackupScheduleLive.beyond_default?(:every_2h, nil, 15, 14)
      refute BackupScheduleLive.beyond_default?(:every_2h, nil, nil, 14)
    end
  end

  describe "validation messages" do
    test "an unknown zone says so, also in French", %{conn: conn} do
      admin = platform_admin()

      for {locale, text} <- [{nil, "is not a known time zone"}, {"fr", "fuseau horaire"}] do
        lv = mount(conn, admin, locale)
        lv |> element("#schedule-new") |> render_click()

        html =
          lv
          |> form("#schedule-form", schedule: form_params(%{"time_zone" => "Mars/Olympus_Mons"}))
          |> render_change()

        assert html =~ text
      end
    end

    test "a sub-daily schedule without keep days says so, also in French (#2219)", %{conn: conn} do
      admin = platform_admin()

      for {locale, text} <- [
            {nil, "is required for a schedule that runs more often than daily"},
            {"fr", "est obligatoire pour une planification plus fréquente"}
          ] do
        lv = mount(conn, admin, locale)
        lv |> element("#schedule-new") |> render_click()

        html =
          lv
          |> form("#schedule-form",
            schedule: form_params(%{"interval" => "every_2h", "keep_days" => ""})
          )
          |> render_submit()

        assert html =~ text
      end

      assert all_schedules() == []
    end

    test "unchecking every component shows an error and saves nothing", %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      lv
      |> form("#schedule-form", schedule: form_params(%{"components" => [""]}))
      |> render_submit()

      assert has_element?(lv, "#schedule-components-error")
      assert all_schedules() == []
    end

    test "the media box is disabled without a media directory", %{conn: conn} do
      admin = platform_admin()
      lv = mount(conn, admin)
      lv |> element("#schedule-new") |> render_click()

      assert has_element?(lv, "#schedule-components-media[disabled]")
      assert has_element?(lv, "#schedule-media-hint", "Media isn't archived on this deployment")

      put_backups(:media_dir, System.tmp_dir!())
      lv = mount(conn, admin)
      lv |> element("#schedule-new") |> render_click()

      refute has_element?(lv, "#schedule-components-media[disabled]")
      assert has_element?(lv, "#schedule-components-media[checked]")
    end
  end

  # Moved from the Backups page (2a's read-only list).
  describe "what a schedule's card says" do
    test "no schedules: says how backups run instead", %{conn: conn} do
      lv = mount(conn, platform_admin())
      assert has_element?(lv, "#backup-schedules", "No schedules yet")
      assert has_element?(lv, "#backup-schedule-retention", "BACKUP_KEEP_DAYS (14 days)")
    end

    @tag :pg_tools
    test "cadence, components, next run, paused and a refused window", %{conn: conn} do
      admin = platform_admin()

      # 2026-01-01 is a Thursday.
      weekly =
        force!(schedule!(%{interval: :weekly, time_of_day: ~T[02:30:00]}, admin),
          baseline_at: @baseline
        )

      paused = schedule!(%{enabled: false, time_of_day: ~T[05:00:00]}, admin)

      refused =
        force!(schedule!(%{time_of_day: ~T[06:00:00]}, admin),
          last_outcome: "refused",
          last_error: "disabled",
          baseline_at: @baseline
        )

      lv = mount(conn, admin)

      assert has_element?(
               lv,
               "#backup-schedule-#{weekly.id} [data-role=cadence]",
               "Every week on Thursday at 02:30 (Etc/UTC)"
             )

      assert has_element?(lv, "#backup-schedule-#{weekly.id} [data-role=components]", "Database")
      assert has_element?(lv, "#backup-schedule-#{weekly.id} [data-role=next]", "Next run:")
      assert has_element?(lv, "#backup-schedule-#{paused.id} [data-role=paused]", "Paused")
      refute has_element?(lv, "#backup-schedule-#{paused.id} [data-role=next]")

      assert has_element?(
               lv,
               "#backup-schedule-#{refused.id} [data-role=last-outcome]",
               "Last window refused: disabled"
             )
    end

    test "a deferred window says why it waits", %{conn: conn} do
      admin = platform_admin()

      queued =
        force!(schedule!(%{time_of_day: ~T[01:00:00]}, admin),
          last_outcome: "deferred",
          last_error: "queue_busy: a resume of 20260101-000000 is queued"
        )

      no_tools =
        force!(schedule!(%{time_of_day: ~T[02:00:00]}, admin),
          last_outcome: "deferred",
          last_error: "no_pg_dump"
        )

      lv = mount(conn, admin)

      assert has_element?(
               lv,
               "#backup-schedule-#{queued.id} [data-role=last-outcome]",
               "another kind of backup is queued"
             )

      assert has_element?(
               lv,
               "#backup-schedule-#{no_tools.id} [data-role=last-outcome]",
               "the server that checked can't run backups (no_pg_dump)"
             )

      refute has_element?(lv, "#backup-schedule-#{no_tools.id} [data-role=last-outcome]", "queue")
    end

    test "the weekday is translated", %{conn: conn} do
      admin = platform_admin()
      weekly = schedule!(%{interval: :weekly}, admin)

      for {locale, day} <- [{"fr", "jeudi"}, {"es", "jueves"}] do
        lv = mount(conn, admin, locale)
        assert has_element?(lv, "#backup-schedule-#{weekly.id} [data-role=cadence]", day)
      end
    end

    test "the real outcome of the schedule's newest run, not just its claim", %{conn: conn} do
      admin = platform_admin()
      s = force!(schedule!(%{}, admin), last_outcome: "started")
      other = schedule!(%{time_of_day: ~T[05:00:00]}, admin)

      run =
        %{stamp: "20260102-030000", trigger: "schedule", schedule_ids: [s.id]}
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.fail_run!(%{error: "boom"}, actor: Backups.system())

      lv = mount(conn, admin)

      # #2875: the run's own History row, not just the Backups tab.
      assert has_element?(
               lv,
               ~s|#backup-schedule-#{s.id} [data-role=last-run] a[href="/editor/backups?run=#{run.id}"]|
             )

      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=last-outcome]", "started")

      assert has_element?(
               lv,
               "#backup-schedule-#{s.id} [data-role=last-run]",
               "Last scheduled run: Failed"
             )

      assert has_element?(
               lv,
               "#backup-schedule-#{other.id} [data-role=last-run]",
               "No scheduled run yet"
             )
    end
  end

  describe "when the last runs can't be read" do
    test "a refused read is :unreadable, not an empty map" do
      s = schedule!(%{}, platform_admin())

      assert BackupScheduleLive.last_runs([s.id], user(:editor)) == :unreadable
      assert BackupScheduleLive.last_runs([s.id], platform_admin()) == %{s.id => nil}
    end

    # The read itself fails only for an actor the page never mounts for, so
    # the page is put in that state directly to check what it renders.
    test "the page says so once, and no card claims there was no run", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      :sys.replace_state(lv.pid, fn state ->
        update_in(state.socket, &Phoenix.Component.assign(&1, :runs, :unreadable))
      end)

      render_click(lv, "cancel", %{})

      assert has_element?(lv, "#backup-schedule-runs-unreadable", "Couldn't load the last runs.")
      refute has_element?(lv, "#backup-schedule-#{s.id} [data-role=last-run]")
    end
  end

  describe "warnings" do
    # #2931: backups a schedule keeps, deleted by a host prune that ignores
    # their `.hold` markers.
    test "a held backup deleted outside the app", %{conn: conn} do
      admin = platform_admin()
      refute has_element?(mount(conn, admin), "#schedule-held-deleted")

      Backups.report_backup_notice!(
        %{
          kind: :held_deleted,
          scope: "local",
          units: ["db:20261110-020000", "media:20261110-020000"],
          total: 2,
          at: DateTime.utc_now()
        },
        actor: Backups.system()
      )

      lv = mount(conn, admin)

      assert has_element?(
               lv,
               "#schedule-held-deleted",
               "2 backups a schedule keeps were deleted outside the app: " <>
                 "Database backup of 2026-11-10 02:00 UTC, Media backup of 2026-11-10 02:00 UTC."
             )

      assert has_element?(
               lv,
               ~s|#schedule-held-deleted-docs[href$="backups.md#the-hold-markers"]|
             )
    end

    test "the scheduler turned off", %{conn: conn} do
      put_cron("false")
      lv = mount(conn, platform_admin())

      assert has_element?(lv, "#schedule-scheduler-off", "KILN_BACKUP_SCHEDULER_CRON")
      refute has_element?(lv, "#schedule-scheduler-invalid")
      refute has_element?(lv, "#schedule-stale-tick")
    end

    # #2935: a cron that never matches (31 February) used to hang the mount
    # in `Oban.Cron.Expression.last_at/2`. Oban 2.24 refuses it at parse, so it
    # reads as invalid; the timeout turns a hang into a failure.
    @tag timeout: 30_000
    test "a scheduler cron that can never match", %{conn: conn} do
      put_cron("0 0 31 2 *")
      admin = platform_admin()
      force!(schedule!(%{}, admin), baseline_at: DateTime.add(DateTime.utc_now(), -600, :second))
      lv = mount(conn, admin)

      assert has_element?(
               lv,
               "#schedule-scheduler-invalid",
               "KILN_BACKUP_SCHEDULER_CRON isn't a valid cron expression, so the scheduler is off and these schedules don't run."
             )

      refute has_element?(lv, "#schedule-scheduler-off")
      refute has_element?(lv, "#schedule-stale-tick")
    end

    # Only an Oban that parses a cron naming no real date gets here (2.24
    # doesn't), so the warnings are rendered with that status.
    test "a scheduler cron that never matches says so" do
      status = %{
        scheduler_enabled?: false,
        scheduler_cron: :never_matches,
        available?: true,
        reason: nil,
        held_deleted: []
      }

      html =
        render_component(&BackupScheduleLive.warnings/1,
          status: status,
          entries: [],
          stale_tick: nil,
          media_dir?: true
        )

      assert html =~ ~s(id="schedule-scheduler-never")

      assert html =~
               "KILN_BACKUP_SCHEDULER_CRON only matches a date that doesn&#39;t exist, such as 31 February, so these schedules never run."

      refute html =~ "schedule-scheduler-off"
      refute html =~ "schedule-scheduler-invalid"
    end

    test "a scheduler cron that isn't one", %{conn: conn} do
      put_cron("not a cron")
      lv = mount(conn, platform_admin())

      assert has_element?(lv, "#schedule-scheduler-invalid")
      refute has_element?(lv, "#schedule-scheduler-off")
    end

    test "backups that can't run here", %{conn: conn} do
      put_backups(:enabled, false)
      lv = mount(conn, platform_admin())

      assert has_element?(
               lv,
               "#schedule-unavailable",
               "In-app backups can't run here, so schedules are skipped: In-app backups are turned off (BACKUP_ENABLED)."
             )
    end

    test "a schedule naming media on a deployment without any", %{conn: conn} do
      admin = platform_admin()
      put_backups(:media_dir, System.tmp_dir!())
      schedule!(%{components: [:db, :media]}, admin)
      put_backups(:media_dir, nil)

      lv = mount(conn, admin)
      assert has_element?(lv, "#schedule-media-missing")
    end

    # E8: only an enabled schedule older than five minutes expects a tick.
    test "the scheduler hasn't ticked", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)

      # Just created: no tick expected yet.
      refute has_element?(mount(conn, admin), "#schedule-stale-tick")

      force!(s, baseline_at: DateTime.add(DateTime.utc_now(), -600, :second))
      assert has_element?(mount(conn, admin), "#schedule-stale-tick", "hasn't run yet")

      tick_at!(DateTime.add(DateTime.utc_now(), -900, :second))
      assert has_element?(mount(conn, admin), "#schedule-stale-tick", "hasn't run since")

      tick_at!(DateTime.add(DateTime.utc_now(), -60, :second))
      refute has_element?(mount(conn, admin), "#schedule-stale-tick")
    end

    test "a paused schedule expects no tick", %{conn: conn} do
      admin = platform_admin()

      force!(schedule!(%{enabled: false}, admin),
        baseline_at: DateTime.add(DateTime.utc_now(), -600, :second)
      )

      refute has_element?(mount(conn, admin), "#schedule-stale-tick")
    end

    # The threshold follows KILN_BACKUP_SCHEDULER_CRON: a tick is late only
    # once the cron's slot (five minutes after it) has passed without
    # one. At */10, 10:08 expects the 10:00 tick, and a 25-minute-old one is
    # late whenever the page looks.
    test "a coarser scheduler cron stretches the threshold", %{conn: conn} do
      put_cron("*/10 * * * *")
      admin = platform_admin()
      s = force!(schedule!(%{}, admin), baseline_at: @baseline)
      entries = [%{schedule: s}]
      on = %{scheduler_enabled?: true}

      tick_at!(~U[2026-03-02 09:50:10.000000Z])

      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-02 09:58:00Z]) == nil

      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-02 10:08:00Z]) ==
               {:stale, ~U[2026-03-02 09:50:10.000000Z]}

      tick_at!(~U[2026-03-02 10:00:20.000000Z])
      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-02 10:08:00Z]) == nil

      tick_at!(DateTime.add(DateTime.utc_now(), -25 * 60, :second))
      assert has_element?(mount(conn, admin), "#schedule-stale-tick", "hasn't run since")
    end

    # #2875: the threshold used to come from the next few gaps of the cron,
    # which at `* * * * 1-5` never include the weekend, so a healthy
    # scheduler read as stale from Saturday on. 2026-03-06 is a Friday.
    test "a weekday-only scheduler cron is not stale over the weekend" do
      put_cron("* * * * 1-5")
      s = force!(schedule!(%{}, platform_admin()), baseline_at: @baseline)
      entries = [%{schedule: s}]
      on = %{scheduler_enabled?: true}
      friday = ~U[2026-03-06 23:59:04.000000Z]
      tick_at!(friday)

      # Saturday noon and Sunday night: Friday's last tick is the latest due.
      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-07 12:00:00Z]) == nil
      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-08 23:59:00Z]) == nil

      # Monday: like any slot, the 00:00 tick has five minutes, then it is due.
      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-09 00:00:30Z]) == nil
      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-09 00:04:30Z]) == nil

      assert BackupScheduleLive.stale_tick(on, entries, ~U[2026-03-09 00:06:00Z]) ==
               {:stale, friday}
    end

    test "with the scheduler off, or at @reboot, no slot stretches the five minutes" do
      s = force!(schedule!(%{}, platform_admin()), baseline_at: @baseline)
      entries = [%{schedule: s}]
      now = ~U[2026-03-07 12:00:00Z]
      tick_at!(~U[2026-03-07 11:56:00.000000Z])

      assert BackupScheduleLive.stale_tick(%{scheduler_enabled?: false}, entries, now) == nil

      put_cron("@reboot")
      on = %{scheduler_enabled?: true}
      assert BackupScheduleLive.stale_tick(on, entries, now) == nil

      assert BackupScheduleLive.stale_tick(on, entries, DateTime.add(now, 300, :second)) ==
               {:stale, ~U[2026-03-07 11:56:00.000000Z]}
    end

    test "a tick that couldn't be read says so instead of crashing", %{conn: conn} do
      admin = platform_admin()

      force!(schedule!(%{}, admin),
        baseline_at: DateTime.add(DateTime.utc_now(), -600, :second)
      )

      original = Application.get_env(:kiln_cms, Oban)
      on_exit(fn -> Application.put_env(:kiln_cms, Oban, original) end)
      Application.put_env(:kiln_cms, Oban, Keyword.put(original, :prefix, "kiln_no_such_schema"))

      lv = mount(conn, admin)
      assert has_element?(lv, "#schedule-tick-unknown", "Couldn't check")
      refute has_element?(lv, "#schedule-stale-tick")
    end
  end

  describe "a scheduler that ticks less often than a schedule (#2983)" do
    setup do
      admin = platform_admin()
      s = schedule!(%{interval: :every_2h, keep_days: 3}, admin)
      %{admin: admin, s: s}
    end

    test "every six hours warns on a two-hourly schedule's card and in its form", %{
      conn: conn,
      admin: admin,
      s: s
    } do
      put_cron("0 */6 * * *")
      daily = schedule!(%{}, admin)
      lv = mount(conn, admin)

      assert has_element?(
               lv,
               ~s|#backup-schedule-#{s.id} [data-role="tick-coarse"]|,
               "can go 6 hours between runs"
             )

      refute has_element?(lv, ~s|#backup-schedule-#{daily.id} [data-role="tick-coarse"]|)

      lv |> element("#schedule-new") |> render_click()
      preview_of(lv, %{"interval" => "every_4h", "keep_days" => "3"})

      assert has_element?(
               lv,
               ~s|#schedule-preview [data-role="tick-coarse"]|,
               "some of its backups are skipped"
             )

      preview_of(lv, %{"interval" => "every_8h", "keep_days" => "3"})
      refute has_element?(lv, ~s|#schedule-preview [data-role="tick-coarse"]|)
    end

    test "a weekday-only scheduler cron warns on a daily schedule", %{conn: conn, admin: admin} do
      daily = schedule!(%{}, admin)

      for {cron, gap} <- [{"*/5 * * * 1-5", "over 48 hours"}, {"0 3 * * 0", "7 days"}] do
        put_cron(cron)
        lv = mount(conn, admin)

        assert has_element?(
                 lv,
                 ~s|#backup-schedule-#{daily.id} [data-role="tick-coarse"]|,
                 "can go #{gap} between runs"
               ),
               cron
      end
    end

    test "the default, every minute, never warns", %{conn: conn, admin: admin, s: s} do
      put_cron("* * * * *")
      lv = mount(conn, admin)

      assert has_element?(lv, "#backup-schedule-#{s.id}")
      refute has_element?(lv, ~s|[data-role="tick-coarse"]|)

      lv |> element("#schedule-new") |> render_click()
      preview_of(lv, %{"interval" => "every_2h", "keep_days" => "3"})
      assert has_element?(lv, "#schedule-preview")
      refute has_element?(lv, ~s|[data-role="tick-coarse"]|)
    end

    test "nor does a scheduler that is off", %{conn: conn, admin: admin} do
      put_cron(false)
      lv = mount(conn, admin)

      assert has_element?(lv, "#schedule-scheduler-off")
      refute has_element?(lv, ~s|[data-role="tick-coarse"]|)
    end

    test "the warning is translated", %{conn: conn, admin: admin, s: s} do
      put_cron("0 */6 * * *")

      for {locale, text} <- [
            {"fr", "peut rester 6 heures sans s’exécuter"},
            {"es", "puede pasar 6 horas entre ejecuciones"}
          ] do
        lv = mount(conn, admin, locale)

        assert has_element?(
                 lv,
                 ~s|#backup-schedule-#{s.id} [data-role="tick-coarse"]|,
                 text
               )

        refute has_element?(lv, ~s|#backup-schedule-#{s.id} [data-role="tick-coarse"]|, "hours")
      end
    end

    test "the sub-daily keep days hint links to the guide", %{conn: conn, admin: admin} do
      lv = mount(conn, admin)
      lv |> element("#schedule-new") |> render_click()
      refute has_element?(lv, "#schedule-keep-days-hint")

      preview_of(lv, %{"interval" => "every_4h"})

      assert has_element?(
               lv,
               "#schedule-keep #schedule-keep-days-hint",
               "Required for a schedule that runs more often than daily."
             )

      assert has_element?(
               lv,
               ~s|#schedule-keep-days-hint a[href$="backups.md#back-up-more-often-than-daily"]|
             )
    end
  end

  describe "the status is read off the LiveView process (#2986)" do
    setup do
      on_exit(fn -> Application.delete_env(:kiln_cms, BackupScheduleLive) end)
      :ok
    end

    # A `Backups.status/0` that waits for `:go`, telling the test it started.
    defp blocking_reader do
      test = self()

      fn ->
        send(test, {:status_read, self()})

        receive do
          :go -> Backups.status()
        end
      end
    end

    defp release(pid) do
      ref = Process.monitor(pid)
      send(pid, :go)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    test "a read that blocks: the tab renders, says it couldn't check in time, starts no " <>
           "other, and shows the schedules when it comes",
         %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)

      Application.put_env(:kiln_cms, BackupScheduleLive,
        status_timeout_ms: 0,
        status_reader: blocking_reader()
      )

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/backups/schedules")
      assert_receive {:status_read, first}

      # The mount's own render: the tab and its controls, the list pending.
      assert html =~ "Reading the schedules…"
      assert has_element?(lv, "#schedule-new")
      assert has_element?(lv, "#backup-tab-schedule[aria-current=page]")

      eventually(lv, "so the schedules can")

      assert has_element?(lv, "#schedule-status-timeout", "Couldn't check this server's backup")
      assert has_element?(lv, "#schedule-status-timeout", "can't be shown")
      refute has_element?(lv, "#schedule-status-pending")
      refute has_element?(lv, "#backup-schedule-#{s.id}")

      # The form still opens and previews meanwhile, saying nothing of
      # whether it would run here.
      lv |> element("#schedule-new") |> render_click()
      preview_of(lv, %{})
      assert has_element?(lv, "#schedule-preview [data-role=cadence]")
      refute has_element?(lv, "#schedule-preview [data-role=first]")
      refute has_element?(lv, "#schedule-preview [data-role=wont-run]")
      lv |> element("#schedule-form button", "Cancel") |> render_click()

      # One at a time: the minute's refresh starts none while it hangs.
      for _ <- 1..3, do: send(lv.pid, :refresh)
      render(lv)
      refute_received {:status_read, _pid}

      release(first)
      render(lv)
      assert has_element?(lv, "#backup-schedule-#{s.id}")
      refute has_element?(lv, "#schedule-status-timeout", "can't be shown")

      # The refreshes asked meanwhile start one more read, not three.
      assert_receive {:status_read, second}
      release(second)
      render(lv)
      refute_received {:status_read, _pid}
      refute has_element?(lv, "#schedule-status-timeout")
    end

    test "a read that times out after an earlier one: the list stays, marked out of date",
         %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)
      assert has_element?(lv, "#backup-schedule-#{s.id}")

      Application.put_env(:kiln_cms, BackupScheduleLive,
        status_timeout_ms: 0,
        status_reader: blocking_reader()
      )

      send(lv.pid, :refresh)
      assert_receive {:status_read, pending}

      # The timer is sent, not run inline: wait for it to land.
      eventually(lv, "may be out of date")
      assert has_element?(lv, "#schedule-status-timeout", "may be out of date")
      assert has_element?(lv, "#backup-schedule-#{s.id}")

      release(pending)
      render(lv)
      refute has_element?(lv, "#schedule-status-timeout")
    end

    test "a read that crashes says so, with no schedules shown", %{conn: conn} do
      admin = platform_admin()
      schedule!(%{}, admin)
      Application.put_env(:kiln_cms, BackupScheduleLive, status_reader: fn -> exit(:boom) end)

      lv = mount(conn, admin)

      assert has_element?(lv, "#schedule-status-failed", "Couldn't read this server's backup")
      refute has_element?(lv, "#schedule-status-pending")
    end
  end
end
