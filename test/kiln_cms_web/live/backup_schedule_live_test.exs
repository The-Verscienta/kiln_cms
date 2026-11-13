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
    lv
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
  describe "each handler refuses a socket that isn't a platform admin's" do
    setup do
      schedule = schedule!(%{}, platform_admin())

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_user: %{role: :editor},
          form: nil,
          editing: nil
        }
      }

      %{schedule: schedule, socket: socket}
    end

    # The form was opened while they were a platform admin, so it carries
    # that actor: the handler's own check is what stands in front of it.
    test "save and validate create nothing, even with a form opened earlier", %{socket: socket} do
      form =
        KilnCMS.Backups.Schedule
        |> AshPhoenix.Form.for_create(:create, actor: platform_admin(), as: "schedule")
        |> Phoenix.Component.to_form()

      socket = %{socket | assigns: %{socket.assigns | form: form, editing: :new}}
      params = %{"schedule" => form_params(%{})}

      assert {:noreply, ^socket} = BackupScheduleLive.handle_event("validate", params, socket)
      assert {:noreply, ^socket} = BackupScheduleLive.handle_event("save", params, socket)
      assert length(all_schedules()) == 1
    end

    test "toggle and delete leave the schedule as it was", %{schedule: s, socket: socket} do
      for event <- ["toggle", "delete", "edit"] do
        assert {:noreply, ^socket} =
                 BackupScheduleLive.handle_event(event, %{"id" => s.id}, socket)
      end

      assert stored(s).enabled
    end

    test "handle_params sends them away, and the refresh reads nothing", %{socket: socket} do
      assert {:noreply, %{redirected: {:live, :redirect, %{to: "/access-denied?needs=platform"}}}} =
               BackupScheduleLive.handle_params(%{}, "/editor/backups/schedules", socket)

      assert {:noreply, ^socket} = BackupScheduleLive.handle_info(:refresh, socket)
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
      assert stored(s).interval == :monthly
    end

    test "pause, resume and delete flash and persist; delete asks first", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=toggle]", "Pause") |> render_click()
      assert render(lv) =~ "Schedule paused."
      refute stored(s).enabled
      assert has_element?(lv, "#backup-schedule-#{s.id} [data-role=paused]", "Paused")

      lv |> element("#backup-schedule-#{s.id} [data-role=toggle]", "Resume") |> render_click()
      assert render(lv) =~ "Schedule resumed."
      assert stored(s).enabled

      assert has_element?(
               lv,
               ~s|#backup-schedule-#{s.id} [data-role=delete][data-confirm*="age out after 14 days (BACKUP_KEEP_DAYS)"]|
             )

      lv |> element("#backup-schedule-#{s.id} [data-role=delete]") |> render_click()
      assert render(lv) =~ "Schedule deleted."
      assert all_schedules() == []
      refute has_element?(lv, "#backup-schedule-#{s.id}")
    end

    test "no keep fields are offered", %{conn: conn} do
      lv = mount(conn, platform_admin())
      lv |> element("#schedule-new") |> render_click()

      refute has_element?(lv, "#schedule-form [name*=keep]")
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
      refute has_element?(lv, "#schedule-form")
      assert all_schedules() == []
    end

    # A form opened before another admin's change would overwrite it with
    # what it still shows: the save is refused instead.
    test "an edit whose schedule another admin changed meanwhile is refused", %{conn: conn} do
      admin = platform_admin()
      s = schedule!(%{}, admin)
      lv = mount(conn, admin)

      lv |> element("#backup-schedule-#{s.id} [data-role=edit]") |> render_click()
      Backups.update_backup_schedule!(s, %{time_of_day: ~T[05:00:00]}, actor: platform_admin())

      html =
        lv
        |> form("#schedule-form", schedule: form_params(%{"time_of_day" => "03:00"}))
        |> render_submit()

      assert html =~ "This schedule changed since you opened it."
      refute has_element?(lv, "#schedule-form")
      assert stored(s).time_of_day == ~T[05:00:00]
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

      assert html =~ "Reopen it to see the current values."
      after_save = stored(s)
      refute after_save.enabled
      assert after_save.interval == :daily
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

    test "a sub-daily interval, which loads as a valid atom", %{conn: conn} do
      admin = platform_admin()
      s = force!(schedule!(%{}, admin), interval: "every_2h")
      before = stored(s)
      lv = mount(conn, admin)

      assert_locked(lv, s)

      assert has_element?(
               lv,
               "#backup-schedule-#{s.id} [data-role=locked]",
               "more often than daily"
             )

      # Pausing writes `enabled` alone.
      lv |> element("#backup-schedule-#{s.id} [data-role=toggle]") |> render_click()
      after_pause = stored(s)
      refute after_pause.enabled
      assert after_pause.interval == :every_2h
      assert after_pause.components == before.components
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
      force!(s, interval: "every_4h")
      before = stored(s)

      html = lv |> form("#schedule-form", schedule: form_params(%{})) |> render_submit()

      assert html =~ "can only be paused, resumed or deleted"
      refute has_element?(lv, "#schedule-form")
      assert stored(s) == before
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

      %{stamp: "20260102-030000", trigger: "schedule", schedule_ids: [s.id]}
      |> Backups.start_run!(actor: Backups.system())
      |> Backups.fail_run!(%{error: "boom"}, actor: Backups.system())

      lv = mount(conn, admin)

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
    test "the scheduler turned off", %{conn: conn} do
      put_cron("false")
      lv = mount(conn, platform_admin())

      assert has_element?(lv, "#schedule-scheduler-off", "KILN_BACKUP_SCHEDULER_CRON")
      refute has_element?(lv, "#schedule-stale-tick")
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

    # The threshold follows KILN_BACKUP_SCHEDULER_CRON: at */10 a tick seven
    # minutes old is on time, one 25 minutes old is not.
    test "a coarser scheduler cron stretches the threshold", %{conn: conn} do
      put_cron("*/10 * * * *")
      admin = platform_admin()

      force!(schedule!(%{}, admin),
        baseline_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      )

      tick_at!(DateTime.add(DateTime.utc_now(), -25 * 60, :second))
      assert has_element?(mount(conn, admin), "#schedule-stale-tick", "hasn't run since")

      tick_at!(DateTime.add(DateTime.utc_now(), -7 * 60, :second))
      refute has_element?(mount(conn, admin), "#schedule-stale-tick")
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
end
