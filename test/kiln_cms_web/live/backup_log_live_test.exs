defmodule KilnCMSWeb.BackupLogLiveTest do
  @moduledoc """
  The Log tab (`/editor/backups/log`, part of #2230 and #2231): one run's
  log for a platform admin, filtered by level, redacted again when shown,
  hidden while the console shares an origin, and re-read while the run is
  running.

  `async: false`: it sets `PGPASSWORD` and `:console_host`, both VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMSWeb.BackupLogLive

  @password "password123456"

  setup do
    pgpassword = System.get_env("PGPASSWORD")
    console = Application.get_env(:kiln_cms, :console_host)
    System.delete_env("PGPASSWORD")

    on_exit(fn ->
      if pgpassword,
        do: System.put_env("PGPASSWORD", pgpassword),
        else: System.delete_env("PGPASSWORD")

      if console,
        do: Application.put_env(:kiln_cms, :console_host, console),
        else: Application.delete_env(:kiln_cms, :console_host)
    end)

    :ok
  end

  defp authed_user(role) do
    email = "bll-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp admin_conn(conn), do: log_in(conn, authed_user(:admin))

  defp expired_grant_user do
    %{
      role: :editor,
      granted_role: :admin,
      granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    }
  end

  defp assert_denied({:noreply, socket}) do
    assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = socket.redirected
  end

  defp stamp(n), do: "20261127-" <> String.pad_leading(Integer.to_string(n), 6, "0")

  defp line({level, step, message}),
    do: %{at: DateTime.utc_now(), level: level, step: step, message: message}

  # A run as the worker writes one, through the code interfaces.
  defp run!(n, outcome, lines, attrs \\ %{}) do
    run =
      Backups.start_run!(
        %{stamp: stamp(n), trigger: "manual", components: [:db], started_at: started(n)},
        actor: Backups.system()
      )

    attrs = Map.merge(%{log: Enum.map(lines, &line/1)}, attrs)

    case outcome do
      :running ->
        Backups.record_run_progress!(run, attrs, actor: Backups.system())

      :failed ->
        Backups.fail_run!(run, Map.put_new(attrs, :error, "failed"), actor: Backups.system())

      :succeeded ->
        Backups.finish_run!(run, attrs, actor: Backups.system())
    end
  end

  defp started(n), do: DateTime.add(~U[2026-11-27 03:00:00.000000Z], n, :minute)

  defp lines do
    [
      {:info, "dump", "pg_dump started"},
      {:warn, "offsite", "retrying the copy"},
      {:error, "offsite", "rclone failed"}
    ]
  end

  defp second_org! do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Second",
      slug: "bll-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp poll_ref(lv), do: :sys.get_state(lv.pid).socket.assigns.poll_ref

  describe "who" do
    test "a platform admin gets the page, with the Log tab current", %{conn: conn} do
      run!(1, :succeeded, lines())
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log")

      assert has_element?(lv, "h1", "Backup log")
      assert has_element?(lv, "#backup-tab-log[aria-current=page]", "Log")
      assert :log in KilnCMSWeb.BackupComponents.tab_keys()
    end

    test "an editor, an org admin and an expired grant are sent away at mount", %{conn: conn} do
      org_admin = authed_user(:editor)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        user_id: org_admin.id,
        organization_id: Accounts.default_org_id(),
        role: :admin
      })

      expired = authed_user(:editor)

      {1, _} =
        KilnCMS.Repo.update_all(
          from(u in "users", where: u.id == type(^expired.id, :binary_id)),
          set: [
            granted_role: "admin",
            granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
          ]
        )

      # The org admin clears the route's per-org gate, so this is the mount's
      # own refusal (`push_navigate`, a `:live_redirect`).
      assert {:error, {:live_redirect, %{to: "/access-denied?needs=platform"}}} =
               build_conn() |> log_in(org_admin) |> live(~p"/editor/backups/log")

      for user <- [authed_user(:editor), expired] do
        assert {:error, {_redirect, %{to: "/access-denied" <> _}}} =
                 build_conn() |> log_in(user) |> live(~p"/editor/backups/log")
      end

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/backups/log")
    end

    test "mount, handle_params, pick_run and the poll refuse a non-admin on their own" do
      run = run!(1, :running, lines())

      for user <- [%{role: :editor}, expired_grant_user()] do
        ref = make_ref()

        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, current_user: user, poll_ref: ref, level: :all}
        }

        assert_denied(BackupLogLive.handle_params(%{}, "/", socket))
        assert_denied(BackupLogLive.handle_params(%{"run" => run.id}, "/", socket))
        assert_denied(BackupLogLive.handle_event("pick_run", %{"run" => run.id}, socket))
        assert_denied(BackupLogLive.handle_info({:log_poll, ref}, socket))

        # The mount on its own too: through the router, `handle_params/3`
        # would refuse right after it, hiding a mount that let them in.
        assert {:ok, mounted} = BackupLogLive.mount(%{}, %{}, socket)
        assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = mounted.redirected
        refute Map.has_key?(mounted.assigns, :run)
      end
    end
  end

  describe "which run" do
    test "the newest run by default, ?run= picks another, and the picker offers both", %{
      conn: conn
    } do
      old = run!(1, :failed, [{:info, "dump", "old line"}])
      new = run!(2, :succeeded, [{:info, "dump", "new line"}])
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log")

      assert has_element?(lv, "#backup-log-summary", new.stamp)
      assert has_element?(lv, "[data-role=message]", "new line")
      assert has_element?(lv, "#backup-log-run option[value='#{old.id}']")

      lv |> form("#backup-log-picker", %{run: old.id}) |> render_change()
      assert_patch(lv, ~p"/editor/backups/log?#{%{run: old.id}}")
      assert has_element?(lv, "[data-role=message]", "old line")
      refute has_element?(lv, "[data-role=message]", "new line")
    end

    test "an older run than the picker's 25 is added to it", %{conn: conn} do
      old = run!(0, :succeeded, [])
      for n <- 1..25, do: run!(n, :succeeded, [])

      {:ok, lv, _html} =
        conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: old.id}}")

      assert has_element?(lv, "#backup-log-run option[value='#{old.id}'][selected]")

      assert lv |> element("#backup-log-run") |> render() |> String.split("<option") |> length() ==
               27
    end

    test "an unknown or forged id is a flash, then the default", %{conn: conn} do
      run = run!(1, :succeeded, [{:info, "dump", "the default"}])
      conn = admin_conn(conn)

      for id <- [Ash.UUID.generate(), "not-a-uuid", ""] do
        {:ok, lv, html} = live(conn, ~p"/editor/backups/log?#{%{run: id}}")
        assert html =~ "That backup isn&#39;t in the history."
        assert has_element?(lv, "#backup-log-summary", run.stamp)
      end

      # A bracketed param is not a string: the default, no crash.
      {:ok, lv, _html} = live(conn, "/editor/backups/log?run[a]=1&level[]=x")
      assert has_element?(lv, "#backup-log-summary", run.stamp)
    end

    test "pick_run with a malformed payload is a no-op", %{conn: conn} do
      run!(1, :succeeded, lines())
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log")

      for payload <- [%{}, %{"run" => ["x"]}, %{"run" => %{"a" => "1"}}, %{"run" => 1}] do
        assert render_hook(lv, "pick_run", payload) =~ "Backup log"
      end
    end
  end

  describe "levels" do
    test "the pills filter with counts, and the truncated marker shows at every level", %{
      conn: conn
    } do
      many = for i <- 1..250, do: {:info, "archive", "part #{i}"}
      run = run!(1, :failed, many ++ [{:warn, "offsite", "slow"}, {:error, "offsite", "broke"}])
      conn = admin_conn(conn)

      {:ok, lv, _html} = live(conn, ~p"/editor/backups/log?#{%{run: run.id}}")
      assert has_element?(lv, "#backup-log-level-all[aria-current=page]", "200")

      assert has_element?(
               lv,
               "[data-role=truncated]",
               "Some lines were dropped to keep the log small"
             )

      for {level, count} <- [{"warn", "3"}, {"error", "2"}] do
        lv |> element("#backup-log-level-#{level}") |> render_click()
        assert has_element?(lv, "#backup-log-level-#{level}[aria-current=page]", count)
        refute has_element?(lv, "#backup-log-level-all[aria-current]")
        assert has_element?(lv, "[data-role=truncated]")
        refute has_element?(lv, "[data-role=message]", "part 250")
      end

      assert has_element?(lv, "[data-role=message]", "broke")
      refute has_element?(lv, "[data-role=message]", "slow")
    end
  end

  describe "states" do
    test "no runs at all", %{conn: conn} do
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log")
      assert has_element?(lv, "#backup-log-empty", "No backups yet")
      refute has_element?(lv, "#backup-log-download")
    end

    test "an empty log, an imported run, the run's error and the download link", %{conn: conn} do
      run = run!(1, :failed, [], %{error: "pg_dump: exit 1"})

      imported =
        Backups.import_run!(
          %{
            stamp: stamp(2),
            trigger: "cron",
            status: :succeeded,
            components: [:db],
            started_at: started(2),
            finished_at: started(3)
          },
          actor: Backups.system()
        )

      conn = admin_conn(conn)
      {:ok, lv, _html} = live(conn, ~p"/editor/backups/log?#{%{run: run.id}}")
      assert has_element?(lv, "#backup-log-no-lines", "This backup recorded no log lines.")
      assert has_element?(lv, "#backup-log-error", "pg_dump: exit 1")

      assert has_element?(
               lv,
               "#backup-log-download[href='/editor/backups/runs/#{run.id}/log.txt']"
             )

      refute has_element?(lv, "#backup-log-imported")

      {:ok, lv, _html} = live(conn, ~p"/editor/backups/log?#{%{run: imported.id}}")
      assert has_element?(lv, "#backup-log-imported", "scripts/backup.sh")
    end
  end

  describe "redaction" do
    test "secret-looking entries stay redacted, and a PGPASSWORD known later too", %{conn: conn} do
      run =
        run!(
          1,
          :failed,
          [
            {:error, "dump", "password=Hunter2Hunter2"},
            {:error, "dump", "postgres://u:Pw12345678@db/x"},
            {:error, "offsite",
             ":s3,access_key_id=AKIAEXAMPLE,secret_access_key=SuperSecret123:b"},
            {:error, "dump", "literal LaterKnown555 here"}
          ],
          %{error: "bad LaterKnown555"}
        )

      System.put_env("PGPASSWORD", "LaterKnown555")
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      html = render(lv)

      for secret <- ~w(Hunter2Hunter2 Pw12345678 SuperSecret123 AKIAEXAMPLE LaterKnown555) do
        refute html =~ secret
      end

      assert has_element?(lv, "[data-role=message]", "literal *** here")
      assert has_element?(lv, "#backup-log-error", "bad ***")
    end

    test "an operator's trigger is redacted again and sanitized in the summary and picker", %{
      conn: conn
    } do
      run = run!(1, :failed, lines(), %{})
      # Stored as the worker would, then shown after the secret is known.
      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "backup_runs", where: r.id == type(^run.id, :binary_id)),
          set: [trigger: "ops TrigPw8888\u202E\e[2J"]
        )

      System.put_env("PGPASSWORD", "TrigPw8888")
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")

      summary = lv |> element("#backup-log-summary [data-role=trigger]") |> render()
      option = lv |> element("#backup-log-run option[value='#{run.id}']") |> render()

      for html <- [summary, option, render(lv)] do
        refute html =~ "TrigPw8888"
        refute html =~ "\u202E"
        refute html =~ "\e"
      end

      assert summary =~ "ops ***\u{FFFD}\u{FFFD}[2J"
      assert option =~ "ops ***\u{FFFD}\u{FFFD}[2J"
    end

    test "control and bidi characters are replaced", %{conn: conn} do
      run = run!(1, :failed, [{:error, "dump", "\e[31mred\u202Etxt.exe"}])
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")

      message = lv |> element("[data-role=message]") |> render()
      refute message =~ "\e"
      refute message =~ "\u202E"
      assert message =~ "\u{FFFD}[31mred\u{FFFD}txt.exe"
    end
  end

  describe "while the run is running" do
    test "the poll re-reads it, and stops once it has finished", %{conn: conn} do
      run = run!(1, :running, [{:info, "dump", "first"}])
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")

      assert has_element?(lv, "#backup-log-live")
      ref = poll_ref(lv)
      assert is_reference(ref)

      run =
        Backups.record_run_progress!(
          run,
          %{log: Enum.map([{:info, "dump", "first"}, {:info, "plan", "second"}], &line/1)},
          actor: Backups.system()
        )

      # A tick of a replaced timer does nothing.
      send(lv.pid, {:log_poll, make_ref()})
      refute has_element?(lv, "[data-role=message]", "second")

      send(lv.pid, {:log_poll, ref})
      assert has_element?(lv, "[data-role=message]", "second")
      next = poll_ref(lv)
      assert is_reference(next) and next != ref

      Backups.finish_run!(run, %{}, actor: Backups.system())
      send(lv.pid, {:log_poll, next})
      refute has_element?(lv, "#backup-log-live")
      assert poll_ref(lv) == nil
    end

    test "the picker is read again, so a run that finished isn't still labelled Running", %{
      conn: conn
    } do
      run = run!(1, :running, lines())
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      option = "#backup-log-run option[value='#{run.id}']"
      assert has_element?(lv, option, "Running")

      Backups.finish_run!(run, %{}, actor: Backups.system())
      send(lv.pid, {:log_poll, poll_ref(lv)})

      assert has_element?(lv, option, "Succeeded")
      refute has_element?(lv, option, "Running")
    end

    test "out of polls, the page stops calling itself live and says so", %{conn: conn} do
      run = run!(1, :running, lines())
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      refute has_element?(lv, "#backup-log-stopped")

      :sys.replace_state(lv.pid, fn state ->
        put_in(state.socket.assigns.polls_left, 1)
      end)

      send(lv.pid, {:log_poll, poll_ref(lv)})

      assert has_element?(lv, "#backup-log-stopped", "Reload it")
      refute has_element?(lv, "#backup-log-live")
      assert poll_ref(lv) == nil

      # A reload follows it again.
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      assert has_element?(lv, "#backup-log-live")
      refute has_element?(lv, "#backup-log-stopped")
    end

    test "a finished run sets no timer", %{conn: conn} do
      run = run!(1, :succeeded, lines())
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")

      refute has_element?(lv, "#backup-log-live")
      assert poll_ref(lv) == nil
    end
  end

  describe "while the console shares an origin" do
    setup do
      Application.delete_env(:kiln_cms, :console_host)
      :ok
    end

    test "the page reads no run: no summary, no error, no entries, no download", %{conn: conn} do
      run = run!(1, :failed, lines(), %{error: "the error"})
      second_org!()

      for path <- [~p"/editor/backups/log", ~p"/editor/backups/log?#{%{run: run.id}}"] do
        html = conn |> admin_conn() |> get(path) |> html_response(200)
        assert html =~ "backup-log-refused"
        refute html =~ "rclone failed"
        refute html =~ run.stamp

        {:ok, lv, html} = conn |> admin_conn() |> live(path)
        assert has_element?(lv, "#backup-log-refused", "KILN_CONSOLE_HOST")

        for gone <- ~w(#backup-log-summary #backup-log-error #backup-log-entries
                       #backup-log-download #backup-log-picker #backup-log-empty) do
          refute has_element?(lv, gone)
        end

        refute html =~ "rclone failed"
        refute html =~ "the error"
      end
    end

    test "a verdict that flips mid-session hides the log at the next poll and patch", %{
      conn: conn
    } do
      run = run!(1, :running, lines())
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      assert has_element?(lv, "[data-role=message]", "rclone failed")
      ref = poll_ref(lv)

      second_org!()

      send(lv.pid, {:log_poll, ref})
      assert has_element?(lv, "#backup-log-refused")
      refute render(lv) =~ "rclone failed"
      refute has_element?(lv, "#backup-log-summary")
      assert poll_ref(lv) == nil

      # And a patch asks again rather than reading.
      render_patch(lv, ~p"/editor/backups/log?#{%{run: run.id, level: :error}}")
      assert has_element?(lv, "#backup-log-refused")
      refute render(lv) =~ "rclone failed"
    end
  end

  # #3489: a `KilnCMS.Backups.Progress` message makes the tab re-read its run
  # sooner. Every assertion is about this test's own run: the topic is
  # instance-wide.
  describe "live progress (#3489)" do
    alias KilnCMS.Backups.{Progress, Recorder}

    defp progress_ref(lv), do: :sys.get_state(lv.pid).socket.assigns.progress_ref

    defp running_with_chain!(n, message) do
      chain = Ash.UUID.generate()

      run =
        %{
          stamp: stamp(n),
          trigger: "manual",
          components: [:db],
          started_at: started(n),
          chain_id: chain
        }
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.record_run_progress!(%{log: [line({:info, "dump", message})]},
          actor: Backups.system()
        )

      {run, chain}
    end

    test "a Run write re-reads the shown run without waiting for the poll", %{conn: conn} do
      {run, chain} = running_with_chain!(1, "first")
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      poll = poll_ref(lv)
      assert is_reference(poll)

      # Through the Recorder, as a step writes it: its write announces itself.
      run.stamp
      |> Recorder.from_run(chain)
      |> Recorder.log(:info, "plan", "second, live")
      |> Recorder.progress()

      eventually(lv, "second, live", true, 2_000)
      # The poll timer is the one it had: never canceled, never a second.
      assert poll_ref(lv) == poll
      assert progress_ref(lv) == nil
    end

    test "a message about another run asks for nothing", %{conn: conn} do
      {run, _chain} = running_with_chain!(1, "first")
      {other, _other_chain} = running_with_chain!(2, "elsewhere")
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")

      Progress.broadcast(Progress.run(other))
      Progress.broadcast(%{chain: Ash.UUID.generate(), stamp: stamp(99)})

      assert progress_ref(lv) == nil
    end

    test "a burst of messages asks for one re-read, and leaves the poll timer alone", %{
      conn: conn
    } do
      {run, _chain} = running_with_chain!(1, "first")
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      poll = poll_ref(lv)

      for _ <- 1..20, do: Progress.broadcast(Progress.run(run))
      pending = progress_ref(lv)
      assert is_reference(pending)
      for _ <- 1..5, do: Progress.broadcast(Progress.run(run))
      assert progress_ref(lv) == pending
      assert poll_ref(lv) == poll

      KilnCMS.Test.Eventually.eventually(fn -> progress_ref(lv) == nil end)
      assert poll_ref(lv) == poll
    end

    test "a message for its stamp revives a tab that ran out of polls", %{conn: conn} do
      {run, chain} = running_with_chain!(1, "first")
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")

      :sys.replace_state(lv.pid, fn state -> put_in(state.socket.assigns.polls_left, 1) end)
      send(lv.pid, {:log_poll, poll_ref(lv)})
      assert has_element?(lv, "#backup-log-stopped")
      assert poll_ref(lv) == nil

      Progress.broadcast(%{chain: chain, stamp: run.stamp, step: :plan})

      KilnCMS.Test.Eventually.eventually(fn -> has_element?(lv, "#backup-log-live") end)
      refute has_element?(lv, "#backup-log-stopped")
      assert is_reference(poll_ref(lv))
      assert :sys.get_state(lv.pid).socket.assigns.polls_left > 1
    end

    test "a platform admin demoted mid-session gets nothing new" do
      run = run!(1, :running, lines())

      for user <- [%{role: :editor}, expired_grant_user()] do
        ref = make_ref()

        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            current_user: user,
            run: run,
            poll_ref: nil,
            progress_ref: ref,
            level: :all
          }
        }

        assert_denied(
          BackupLogLive.handle_info({:kiln_backup_progress, 1, Progress.run(run)}, socket)
        )

        assert_denied(BackupLogLive.handle_info({:progress_refresh, ref}, socket))
      end
    end

    test "a message the node doesn't know the version of is ignored" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: %{role: :admin}}
      }

      assert {:noreply, ^socket} =
               BackupLogLive.handle_info({:kiln_backup_progress, 2, %{}}, socket)
    end

    test "a non-admin's mount never subscribes" do
      socket = %Phoenix.LiveView.Socket{
        transport_pid: self(),
        assigns: %{__changed__: %{}, current_user: %{role: :editor}}
      }

      assert {:ok, _mounted} = BackupLogLive.mount(%{}, %{}, socket)
      refute self() in subscribers()
    end

    test "while the console shares an origin, a message hides the log", %{conn: conn} do
      Application.delete_env(:kiln_cms, :console_host)
      {run, _chain} = running_with_chain!(1, "rclone failed")
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups/log?#{%{run: run.id}}")
      assert has_element?(lv, "[data-role=message]", "rclone failed")

      second_org!()
      Progress.broadcast(Progress.run(run))

      # Asked when the throttled re-read runs, before it reads anything.
      KilnCMS.Test.Eventually.eventually(fn -> has_element?(lv, "#backup-log-refused") end)
      refute render(lv) =~ "rclone failed"
      assert progress_ref(lv) == nil
      assert poll_ref(lv) == nil
    end
  end

  defp subscribers do
    KilnCMS.PubSub |> Registry.lookup(KilnCMS.Backups.Progress.topic()) |> Enum.map(&elem(&1, 0))
  end

  describe "the History page" do
    test "each row links to its log", %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "kiln_bll_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.merge(original, enabled: true, dir: dir, media_dir: nil)
      )

      on_exit(fn ->
        File.rm_rf!(dir)
        Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      end)

      run = run!(1, :succeeded, lines())
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-run-#{run.id} a[data-role=view-log][href='/editor/backups/log?run=#{run.id}']",
               "View log"
             )
    end
  end
end
