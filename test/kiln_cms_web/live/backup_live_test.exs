defmodule KilnCMSWeb.BackupLiveTest do
  @moduledoc """
  The backup panel (#484).

  What matters here is what it says when things are WRONG — "no backup has
  ever run", "the last one failed", "this image can't take one" — because a
  panel that only renders the happy path is worse than no panel: it makes an
  unprotected deployment look fine.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  require Ecto.Query

  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Manifest

  @password "password123456"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bkl_#{System.unique_integer([:positive])}")
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

  defp authed_user(role) do
    email = "backup-#{System.unique_integer([:positive])}@example.com"

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
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp seed_manifest!(dir, overrides) do
    :ok =
      Manifest.write(
        dir,
        struct(
          %Manifest{
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            trigger: "cron",
            ok: true,
            artifacts: [
              %{kind: "db", path: "db/kiln-db-20260805-031700.dump", bytes: 2048, verified: true}
            ]
          },
          overrides
        )
      )
  end

  describe "off-site remote" do
    test "a connection-string remote's credentials never reach the page", %{conn: conn, dir: dir} do
      seed_manifest!(dir, %{
        offsite: ":s3,access_key_id=AKIAEXAMPLE,secret_access_key=hunter2hunter2:bucket/path"
      })

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert html =~ "Off-site"
      refute html =~ "hunter2hunter2"
      assert html =~ "secret_access_key=***"
    end
  end

  describe "authorization" do
    test "anonymous users are redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/backups")
    end

    test "editors are turned away — backups are infrastructure", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))
      assert {:error, {:redirect, _}} = live(conn, ~p"/editor/backups")
    end

    test "admins get the panel", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")
      assert html =~ "Backups"
    end

    # #1160. The route carries `:live_admin_required`, which is an EFFECTIVE
    # PER-ORG tier (#419) — so a user granted admin on one site passes it while
    # being an ordinary editor globally. A backup is a `pg_dump` of the whole
    # instance, covering every tenant, which is not theirs to take.
    #
    # This is the only case that distinguishes the route guard from the mount
    # guard: for everyone else the two agree, which is why the tests above pass
    # either way.
    test "an org admin who is not a platform admin is turned away", %{conn: conn} do
      user = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: user.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      # The premise: they really do clear the route's per-org gate.
      assert KilnCMS.Accounts.Scoping.effective_tier(user, KilnCMS.Accounts.default_org_id()) ==
               :admin

      # `:live_redirect`, not `:redirect` — and the distinction is the assertion.
      # The route guard refuses with `Phoenix.LiveView.redirect/2`; `mount/3`
      # refuses with `push_navigate/2`. Matching the loose `{:redirect, _}` here
      # would pass even if the mount guard were deleted and the route had
      # somehow turned them away instead.
      assert {:error, {:live_redirect, %{to: "/access-denied?needs=platform"}}} =
               conn |> log_in(user) |> live(~p"/editor/backups")
    end

    # `Backups.enqueue/1` takes no actor and authorizes nothing, so the mount
    # guard is the only thing in front of it — and a mount guard is evaluated
    # once. Called directly because a refused mount leaves no socket to push an
    # event down: the question here is what the handler does on its own.
    test "the handler refuses on its own, without the mount guard in front of it" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: %{role: :editor}}
      }

      assert {:noreply, ^socket} =
               KilnCMSWeb.BackupLive.handle_event("backup_now", %{}, socket)

      # Scoped to the worker this handler would have enqueued (#1354).
      refute Enum.any?(
               KilnCMS.Repo.all(Oban.Job),
               &String.starts_with?(&1.worker, "KilnCMS.Backups.Worker")
             )
    end
  end

  describe "what it says when there is no backup" do
    test "says so outright, and in the alarming tone", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert html =~ "No backup has ever been recorded"
      # Error tone, not a neutral note: an unprotected deployment is the state
      # this page exists to make impossible to miss.
      assert html =~ "border-error/30"
    end

    test "names the file it looked for, so an admin can tell 'never ran' from 'ran elsewhere'", %{
      conn: conn,
      dir: dir
    } do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert html =~ Manifest.path(dir)
    end
  end

  describe "reporting a backup it did not run" do
    test "renders a manifest written by cron's shell script", %{conn: conn, dir: dir} do
      # The whole point: the canonical path is still cron, and a panel that
      # only knew about app-triggered runs would show "never" on exactly the
      # deployments that are backing up correctly.
      seed_manifest!(dir, trigger: "cron")

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert html =~ "Backed up"
      assert html =~ "cron"
      assert html =~ "kiln-db-20260805-031700.dump"
      assert html =~ "2.0 KB"
      assert html =~ "Verified"
      assert html =~ "border-success/30"
    end

    test "an old backup reads as stale", %{conn: conn, dir: dir} do
      seed_manifest!(dir, finished_at: DateTime.add(DateTime.utc_now(), -5 * 86_400, :second))

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert html =~ "Last backup was"
      assert html =~ "5 days"
      assert html =~ "border-error/30"
    end

    test "a FAILED run shows its own error, not the last success", %{conn: conn, dir: dir} do
      seed_manifest!(dir, ok: false, artifacts: [], error: "pg_dump exited 1: connection refused")

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert html =~ "The last backup failed"
      assert html =~ "connection refused"
    end

    test "a run that failed a minute ago still reads as alarming, not green" do
      # Tone driven by age alone rendered "The last backup failed" with a
      # green tick and a success border: the run was recent, so `stale?` was
      # false. Recent and worthless is not success.
      conn = Phoenix.ConnTest.build_conn()
      dir = Application.get_env(:kiln_cms, KilnCMS.Backups)[:dir]

      seed_manifest!(dir,
        ok: false,
        artifacts: [],
        error: "boom",
        finished_at: DateTime.utc_now()
      )

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      refute html =~ "border-success/30"
      assert html =~ "border-error/30"
    end

    test "a failed run doesn't advertise '0 B · 0 file(s)' next to its error", %{
      conn: conn,
      dir: dir
    } do
      seed_manifest!(dir, ok: false, artifacts: [], error: "boom")

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      refute html =~ "0 file(s)"
    end
  end

  describe "backing up now" do
    test "is refused, with a reason, when the deployment can't run one", %{conn: conn} do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      # The button is disabled rather than absent, so the reason has somewhere
      # to live — an admin who can't back up needs to know why, not wonder
      # where the button went.
      assert html =~ "disabled"
      assert lv |> element(~s|button[phx-click="backup_now"][disabled]|) |> has_element?()
    end

    test "enqueues a job and says so", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      if KilnCMS.Backups.availability() == :ok do
        html = lv |> element(~s|button[phx-click="backup_now"]|) |> render_click()

        assert html =~ "Backup started"

        # Scoped to the backups queue (#1354): the single-element claim is
        # about THIS button's enqueue, not the whole shared table.
        # The chain's start step (#2218), through the lock.
        assert [
                 %Oban.Job{
                   worker: "KilnCMS.Backups.StepWorker",
                   args: args,
                   queue: "backup_steps"
                 }
               ] =
                 Enum.filter(
                   KilnCMS.Repo.all(Oban.Job),
                   &String.starts_with?(&1.worker, "KilnCMS.Backups.")
                 )

        assert args["trigger"] == "manual"
      end
    end
  end

  describe "history" do
    defp admin_conn(conn), do: log_in(conn, authed_user(:admin))

    # A run row with one artifact whose file is (optionally) on disk.
    defp seed_run!(dir, n, opts \\ []) do
      stamp = Keyword.get(opts, :stamp, "2026010#{rem(n, 10)}-0#{n}0000")
      name = "kiln-db-#{stamp}.dump"
      if Keyword.get(opts, :file?, true), do: write_artifact!(dir, name)

      artifact = %{
        kind: :db,
        name: name,
        bytes: Keyword.get(opts, :bytes, 2048),
        verified: Keyword.get(opts, :verified, true),
        destinations: Keyword.get(opts, :destinations, %{"local" => %{"status" => "ok"}})
      }

      Backups.import_run!(
        %{
          stamp: stamp,
          trigger: Keyword.get(opts, :trigger, "manual"),
          status: :succeeded,
          components: [:db],
          started_at: Keyword.get(opts, :started_at, ~U[2026-01-01 03:00:00.000000Z]),
          finished_at: ~U[2026-01-01 03:05:00.000000Z],
          artifacts: [artifact]
        },
        actor: Backups.system()
      )
    end

    defp write_artifact!(dir, name) do
      File.mkdir_p!(Path.join(dir, "db"))
      File.write!(Path.join([dir, "db", name]), "x")
    end

    test "shows an empty state when nothing was ever recorded", %{conn: conn} do
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert has_element?(lv, "#backup-history-empty", "No backups have been recorded yet.")
    end

    test "lists a row with its trigger, size, verified badge and destinations", %{
      conn: conn,
      dir: dir
    } do
      seed_run!(dir, 1,
        trigger: "manual",
        destinations: %{
          "local" => %{"status" => "ok"},
          "rclone:offsite" => %{"status" => "ok"}
        }
      )

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      row = lv |> element("#backup-history li") |> render()
      assert row =~ "2026-01-01 03:00 UTC"
      assert row =~ "Manual"
      assert row =~ "Succeeded"
      assert row =~ "Database"
      assert row =~ "2.0 KB"
      assert row =~ "Verified"
      assert row =~ "Local"
      assert row =~ "offsite"
      assert row =~ "on disk"
    end

    test "a media part set is one row: summed size, an 'N parts' note, per-part presence",
         %{conn: conn, dir: dir} do
      stamp = "20260105-030000"
      names = Backups.Artifact.set_names(stamp, 3)
      File.mkdir_p!(Path.join(dir, "media"))
      for name <- names, do: File.write!(Path.join([dir, "media", name]), "x")

      run =
        Backups.import_run!(
          %{
            stamp: stamp,
            trigger: "manual",
            status: :succeeded,
            components: [:media],
            started_at: ~U[2026-01-05 03:00:00.000000Z],
            finished_at: ~U[2026-01-05 03:05:00.000000Z],
            artifacts: [
              %{
                kind: :media,
                name: "kiln-media-#{stamp}",
                bytes: 3 * 1024,
                verified: true,
                parts: Enum.map(names, &%{"name" => &1, "bytes" => 1024, "sha256" => nil}),
                destinations: %{"local" => %{"status" => "ok"}}
              }
            ]
          },
          actor: Backups.system()
        )

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      row = lv |> element("#backup-run-#{run.id}") |> render()
      assert row =~ "3.0 KB"
      assert row =~ "3 parts"
      assert has_element?(lv, "#backup-run-#{run.id} [data-presence=present]", "on disk")

      File.rm!(Path.join([dir, "media", Enum.at(names, 1)]))
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)
      assert has_element?(lv, "#backup-run-#{run.id} [data-presence=missing]", "missing")
    end

    test "a file deleted out-of-band reads missing", %{conn: conn, dir: dir} do
      run = seed_run!(dir, 1, started_at: DateTime.add(DateTime.utc_now(), -3600, :second))
      File.rm!(Path.join([dir, "db", hd(run.artifacts).name]))

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert has_element?(lv, "#backup-run-#{run.id} [data-presence=missing]", "missing")
    end

    test "pruned, expired and off-site-only are told apart", %{conn: conn, dir: dir} do
      pruned =
        seed_run!(dir, 1,
          file?: false,
          destinations: %{"local" => %{"status" => "pruned"}}
        )

      off_site =
        seed_run!(dir, 2,
          file?: false,
          destinations: %{
            "local" => %{"status" => "ok"},
            "rclone:offsite" => %{"status" => "ok"}
          }
        )

      # Imported (cron-made), long past retention.
      expired =
        Backups.import_run!(
          %{
            stamp: "20250101-030000",
            trigger: "cron",
            status: :succeeded,
            components: [:db],
            started_at: ~U[2025-01-01 03:00:00.000000Z],
            artifacts: [%{kind: :db, name: "kiln-db-20250101-030000.dump", bytes: 5}]
          },
          actor: Backups.system()
        )

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert has_element?(
               lv,
               "#backup-run-#{pruned.id} [data-presence=pruned]",
               "pruned (retention)"
             )

      assert has_element?(
               lv,
               "#backup-run-#{off_site.id} [data-presence=off_site_only]",
               "off-site only"
             )

      assert has_element?(lv, "#backup-run-#{expired.id} [data-presence=expired]", "expired")
      assert has_element?(lv, "#backup-run-#{expired.id}", "unverified (imported)")
    end

    test "cron-made backups on disk are imported and shown", %{conn: conn, dir: dir} do
      path = Path.join([dir, "db"])
      File.mkdir_p!(path)
      file = Path.join(path, "kiln-db-20260102-030000.dump")
      File.write!(file, "dump")
      File.touch!(file, System.os_time(:second) - 3600)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert has_element?(lv, "#backup-history li", "2026-01-02 03:00 UTC")
      assert has_element?(lv, ~s|#backup-history li [data-role="trigger"]|, "Cron")
      assert has_element?(lv, "#backup-history li", "unverified (imported)")
    end

    test "pages 25 at a time, and an out-of-range page lands on the last one", %{
      conn: conn,
      dir: dir
    } do
      for n <- 1..27 do
        stamp = "20260101-00#{String.pad_leading(Integer.to_string(n), 2, "0")}00"

        seed_run!(dir, n,
          stamp: stamp,
          started_at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n * 3600, :second)
        )
      end

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert lv |> element("#backup-history") |> render() =~ "Page 1 of 2"
      assert lv |> render() |> String.split("backup-run-") |> length() == 26

      lv
      |> element(~s|#backup-history button[phx-click="page"]:not([disabled])|)
      |> render_click()

      assert_patch(lv, ~p"/editor/backups?page=2")
      assert lv |> element("#backup-history") |> render() =~ "Page 2 of 2"
      assert lv |> render() |> String.split("backup-run-") |> length() == 3

      assert {:error, {:live_redirect, %{to: "/editor/backups?page=2"}}} =
               conn |> admin_conn() |> live(~p"/editor/backups?page=99")

      # Garbage reads as page 1.
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups?page=abc")
      assert lv |> element("#backup-history") |> render() =~ "Page 1 of 2"
    end

    test "the import runs on the connected mount, not the disconnected render", %{
      conn: conn,
      dir: dir
    } do
      file = Path.join([dir, "db", "kiln-db-20260102-030000.dump"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "dump")
      File.touch!(file, System.os_time(:second) - 3600)

      conn = admin_conn(conn)
      assert conn |> get(~p"/editor/backups") |> html_response(200) =~ "Backups"
      assert Backups.list_runs!(actor: Backups.system()) == []

      {:ok, lv, _html} = live(conn, ~p"/editor/backups")
      render_async(lv, 2_000)
      assert [%{origin: :imported}] = Backups.list_runs!(actor: Backups.system())
    end

    test "a refused user starts no import", %{conn: conn, dir: dir} do
      file = Path.join([dir, "db", "kiln-db-20260102-030000.dump"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "dump")
      File.touch!(file, System.os_time(:second) - 3600)

      for user <- [authed_user(:editor), org_admin()] do
        assert {:error, {_kind, _}} = conn |> log_in(user) |> live(~p"/editor/backups")
      end

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/backups")
      assert Backups.list_runs!(actor: Backups.system()) == []
    end

    defp org_admin do
      user = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: user.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      user
    end

    test "handle_params and the page event refuse a non-admin on their own" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: %{role: :editor}}
      }

      assert {:noreply, ^socket} =
               KilnCMSWeb.BackupLive.handle_event("page", %{"to" => "2"}, socket)

      assert {:noreply, refused} = KilnCMSWeb.BackupLive.handle_params(%{}, "/", socket)
      assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = refused.redirected
    end

    test "the history refreshes when a manual backup finishes", %{conn: conn, dir: dir} do
      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)
      assert has_element?(lv, "#backup-history-empty")

      seed_run!(dir, 1)
      send(lv.pid, :refresh)

      assert render(lv) =~ "2026-01-01 03:00 UTC"
    end
  end

  describe "resume (#2218)" do
    alias KilnCMS.Backups.WorkState

    # An in-app run in `status`, with (or without) the state file a resume needs.
    defp app_run!(dir, n, status, opts \\ []) do
      stamp = "2026110#{n}-101010"

      run =
        Backups.start_run!(%{stamp: stamp, trigger: "manual", components: [:db, :media]},
          actor: Backups.system()
        )

      run =
        case status do
          :failed -> Backups.fail_run!(run, %{error: "tar exited 2"}, actor: Backups.system())
          :succeeded -> Backups.finish_run!(run, %{}, actor: Backups.system())
          :running -> run
        end

      if Keyword.get(opts, :state?, true) do
        work = WorkState.path(dir, stamp)
        File.mkdir_p!(work)
        :ok = WorkState.write(work, WorkState.new(stamp))
      end

      run
    end

    defp backup_jobs do
      Enum.filter(KilnCMS.Repo.all(Oban.Job), &String.starts_with?(&1.worker, "KilnCMS.Backups."))
    end

    test "a platform admin sees Resume on a failed run that kept its state", %{
      conn: conn,
      dir: dir
    } do
      run = app_run!(dir, 1, :failed)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert has_element?(lv, ~s|#backup-run-#{run.id} button[data-role="resume"]|, "Resume")
    end

    test "only resumable runs get the button", %{conn: conn, dir: dir} do
      succeeded = app_run!(dir, 2, :succeeded)
      running = app_run!(dir, 3, :running)
      no_state = app_run!(dir, 4, :failed, state?: false)
      imported = seed_run!(dir, 5)
      File.mkdir_p!(WorkState.path(dir, imported.stamp))
      :ok = WorkState.write(WorkState.path(dir, imported.stamp), WorkState.new(imported.stamp))

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      for run <- [succeeded, running, no_state, imported] do
        assert has_element?(lv, "#backup-run-#{run.id}")
        refute has_element?(lv, ~s|#backup-run-#{run.id} [data-role="resume"]|)
      end
    end

    @tag :pg_tools
    test "clicking it enqueues a resume job for THAT run's stamp and says so", %{
      conn: conn,
      dir: dir
    } do
      run = app_run!(dir, 1, :failed)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      html = lv |> element(~s|#backup-run-#{run.id} [data-role="resume"]|) |> render_click()

      assert html =~ "Backup resumed"
      assert [%Oban.Job{args: args, queue: "backup_steps"}] = backup_jobs()
      assert args["step"] == "start"
      assert args["resume"] == run.stamp
      # The strip and the poll now follow it; "Back up now" stays enabled (a
      # request while one runs queues).
      assert has_element?(lv, "#backup-in-flight")
      refute has_element?(lv, ~s|button[phx-click="backup_now"][disabled]|)
    end

    @tag :pg_tools
    test "a forged event naming a succeeded or running run, or no run, is refused", %{
      conn: conn,
      dir: dir
    } do
      succeeded = app_run!(dir, 2, :succeeded)
      running = app_run!(dir, 3, :running)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      for id <- [succeeded.id, running.id, Ecto.UUID.generate(), "not-a-uuid"] do
        html = render_hook(lv, "resume_run", %{"id" => id})
        assert html =~ "can&#39;t be resumed"
      end

      # A forged STAMP is not even a parameter the handler reads.
      render_hook(lv, "resume_run", %{"id" => succeeded.id, "stamp" => "../../x"})
      render_hook(lv, "resume_run", %{"stamp" => "../../x"})
      render_hook(lv, "resume_run", %{"id" => 7})

      assert backup_jobs() == []
    end

    @tag :pg_tools
    test "a failed run whose state is gone is refused", %{conn: conn, dir: dir} do
      run = app_run!(dir, 4, :failed, state?: false)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert render_hook(lv, "resume_run", %{"id" => run.id}) =~ "can&#39;t be resumed"
      assert backup_jobs() == []
    end

    @tag :pg_tools
    test "the handler re-checks platform admin: editor, org admin and anonymous get nothing", %{
      dir: dir
    } do
      run = app_run!(dir, 1, :failed)

      org_admin = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: org_admin.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      for user <- [authed_user(:editor), org_admin, authed_user(:viewer), nil] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

        assert {:noreply, ^socket} =
                 KilnCMSWeb.BackupLive.handle_event("resume_run", %{"id" => run.id}, socket)
      end

      assert backup_jobs() == []
    end

    test "a failed run whose resume was refused says so in its row and still offers Resume", %{
      conn: conn,
      dir: dir
    } do
      run = app_run!(dir, 2, :failed)

      Backups.note_run_resume_refused!(
        run,
        "its work files (.work/#{run.stamp}/state.json) are not on the server that picked it up",
        actor: Backups.system()
      )

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, row, "Resume refused: its work files")
      assert has_element?(lv, row, "tar exited 2")
      assert has_element?(lv, ~s|#{row} button[data-role="resume"]|, "Resume")
    end

    test "a run refused off-site shows the refusal, Not verified, and Resume", %{
      conn: conn,
      dir: dir
    } do
      stamp = "20261105-101010"
      archive = "kiln-media-#{stamp}.tar.gz"

      error =
        "Off-site copy REFUSED for 1 file: #{archive} (changed on disk after this backup " <>
          "verified it (sha256 expected 3b1f00000000…, found 8c0200000000…)). Something other " <>
          "than this backup wrote to the backup directory: check the disk and anything with " <>
          "access to BACKUP_DIR before trusting this backup. The local files are kept; Resume " <>
          "retries the off-site copy and rebuilds any file that changed."

      run =
        Backups.start_run!(%{stamp: stamp, trigger: "manual", components: [:db, :media]},
          actor: Backups.system()
        )

      artifacts = [
        %{kind: :db, name: "kiln-db-#{stamp}.dump", bytes: 10, verified: true},
        %{
          kind: :media,
          name: archive,
          bytes: 10,
          verified: false,
          destinations: %{
            "local" => %{"status" => "ok"},
            "rclone:r2:kiln" => %{"status" => "failed", "error" => "Refused: changed on disk"}
          }
        }
      ]

      run =
        Backups.fail_run!(run, %{error: error, artifacts: artifacts}, actor: Backups.system())

      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))

      :ok =
        Manifest.write(dir, %Manifest{
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          trigger: "manual",
          ok: false,
          artifacts: [
            %{kind: "db", path: "db/kiln-db-#{stamp}.dump", bytes: 10, verified: true},
            %{kind: "media", path: "media/#{archive}", bytes: 10, verified: false}
          ],
          error: error
        })

      {:ok, lv, html} = conn |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      # The "Last run failed" box quotes the manifest's error.
      assert html =~ "Last run failed"
      assert html =~ "Off-site copy REFUSED for 1 file: #{archive}"

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, row, "Off-site copy REFUSED")
      assert has_element?(lv, ~s|#{row} [data-role="verified"]|, "Not verified")
      assert has_element?(lv, ~s|#{row} [data-role="destination"]|, "failed")
      assert has_element?(lv, ~s|#{row} button[data-role="resume"]|, "Resume")
    end
  end

  describe "in flight and cancel (#2218)" do
    alias KilnCMS.Backups.{DirId, WorkState}
    alias KilnCMS.Test.BackupChain

    defp lock_row, do: Backups.backup_lock!(actor: Backups.system())

    # A backup requested and its start step run: the lock holds a stamp, its
    # Run is `running`, and the dump step waits.
    defp started! do
      {:ok, %{status: :started}} = Backups.request([], Backups.system())
      %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      row = lock_row()
      %{stamp: row.stamp, run: Backups.get_run_by_stamp!(row.stamp, actor: Backups.system())}
    end

    test "Back up now is guarded against a double click" do
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")

      assert has_element?(lv, ~s|button[phx-click="backup_now"][phx-disable-with]|)
    end

    test "a seeded canceled run reads Canceled, and Resume is offered when its files are kept",
         %{dir: dir} do
      stamp = "20261106-101010"
      run = Ash.Seed.seed!(KilnCMS.Backups.Run, %{stamp: stamp, status: :canceled})
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, ~s|#{row} [data-role="status"]|, "Canceled")
      assert has_element?(lv, ~s|#{row} button[data-role="resume"]|)
      refute has_element?(lv, ~s|#{row} [data-role="cancel"]|)
    end

    @tag :pg_tools
    test "the strip names the step; a platform admin cancels; the row reads Canceled and " <>
           "offers Resume" do
      %{stamp: stamp, run: run} = started!()

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert has_element?(lv, ~s|#backup-in-flight [data-role="step"]|, "Dumping the database")
      assert has_element?(lv, "#backup-in-flight", stamp)
      refute has_element?(lv, ~s|#backup-in-flight [data-role="queued"]|)

      strip = ~s|#backup-in-flight button[data-role="cancel"][data-confirm]|
      assert has_element?(lv, strip)
      refute render(lv) =~ "A queued backup will start next"
      assert has_element?(lv, ~s|#backup-run-#{run.id} button[data-role="cancel"]|)

      html = lv |> element(strip) |> render_click()

      assert html =~ "Backup canceled"
      assert Backups.in_flight() == nil
      refute has_element?(lv, "#backup-in-flight")

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, ~s|#{row} [data-role="status"]|, "Canceled")
      refute has_element?(lv, ~s|#{row} [data-role="cancel"]|)
      assert has_element?(lv, ~s|#{row} button[data-role="resume"]|)

      # Right after the Cancel, Resume says how long to wait (#2538)...
      html = lv |> element(~s|#{row} button[data-role="resume"]|) |> render_click()
      assert html =~ "canceled moments ago"
      assert html =~ ~r/Resume it again in \d+ seconds?/
      assert Backups.in_flight() == nil

      # ...and once the Cancel has settled, it requests it again.
      settled =
        DateTime.add(
          DateTime.utc_now(),
          -(Backups.Heartbeat.settled_after_ms() + 1_000),
          :millisecond
        )

      {1, _} =
        KilnCMS.Repo.update_all(
          Ecto.Query.from(r in "backup_runs", where: r.stamp == ^stamp),
          set: [finished_at: settled]
        )

      html = lv |> element(~s|#{row} button[data-role="resume"]|) |> render_click()
      assert html =~ "Backup resumed"
      assert %{stamp: ^stamp} = Backups.in_flight()
    end

    @tag :pg_tools
    test "a queued request shows on the strip, with its folds, and the confirm says it starts next" do
      started!()
      {:ok, %{status: :queued}} = Backups.request([trigger: "schedule"], Backups.system())
      {:ok, %{status: :folded}} = Backups.request([], Backups.system())
      {:ok, %{status: :folded}} = Backups.request([], Backups.system())

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")

      queued = ~s|#backup-in-flight [data-role="queued"]|
      assert has_element?(lv, queued, "1 queued (requested ")
      assert has_element?(lv, queued, "2 later requests folded into it")

      assert has_element?(
               lv,
               ~s|#backup-in-flight button[data-role="cancel"][data-confirm*="A queued backup will start next"]|
             )
    end

    # #2219: what the queued backup covers.
    @tag :pg_tools
    test "the queued request says which components it covers", %{dir: dir} do
      media = Path.join(dir, "uploads")
      File.mkdir_p!(media)
      config = Application.get_env(:kiln_cms, KilnCMS.Backups)
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(config, :media_dir, media))

      started!()
      {:ok, %{status: :queued}} = Backups.request([components: [:db]], Backups.system())

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      components = ~s|#backup-in-flight [data-role="queued-components"]|
      assert has_element?(lv, components, "Database")
      refute has_element?(lv, components, "Media")

      {:ok, %{status: :folded}} = Backups.request([components: [:media]], Backups.system())

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      assert has_element?(lv, components, "Database + Media")
    end

    @tag :pg_tools
    test "Back up now while one runs queues it and says so" do
      started!()
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")

      html = lv |> element(~s|button[phx-click="backup_now"]|) |> render_click()

      assert html =~ "this one starts when it finishes"
      assert has_element?(lv, ~s|#backup-in-flight [data-role="queued"]|)
    end

    # A failed in-app run that kept its state, so it offers Resume (#2540).
    defp resumable_run!(dir, stamp) do
      run =
        Backups.start_run!(%{stamp: stamp, trigger: "manual", components: [:db, :media]},
          actor: Backups.system()
        )

      run = Backups.fail_run!(run, %{error: "tar exited 2"}, actor: Backups.system())
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))
      run
    end

    defp queue_state do
      row = lock_row()

      {row.waiting_resume_stamp, row.waiting_requested_at, row.waiting_folds,
       length(Backups.list_runs!(actor: Backups.system()))}
    end

    @tag :pg_tools
    test "Back up now folds into a queued fresh backup and says the queued one covers it" do
      started!()
      {:ok, %{status: :queued}} = Backups.request([trigger: "schedule"], Backups.system())
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")

      html = lv |> element(~s|button[phx-click="backup_now"]|) |> render_click()

      assert html =~ "that queued backup covers this request"
      assert %{waiting: %{folds: 1}} = Backups.in_flight()
    end

    @tag :pg_tools
    test "Resume folds into a queued resume of the same backup and says so", %{dir: dir} do
      run = resumable_run!(dir, "20261101-101010")
      started!()
      {:ok, %{status: :queued}} = Backups.request([resume: run.stamp], Backups.system())
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      html =
        lv |> element(~s|#backup-run-#{run.id} button[data-role="resume"]|) |> render_click()

      assert html =~ "a resume of this backup is already queued; that queued resume covers"
      assert %{waiting: %{folds: 1}} = Backups.in_flight()
    end

    @tag :pg_tools
    test "Back up now while a resume is queued is refused and leaves the queue alone",
         %{dir: dir} do
      run = resumable_run!(dir, "20261101-101010")
      started!()
      {:ok, %{status: :queued}} = Backups.request([resume: run.stamp], Backups.system())
      before = queue_state()
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")

      html = lv |> element(~s|button[phx-click="backup_now"]|) |> render_click()

      assert html =~
               "A backup is running and a resume of 20261101-101010 is queued after it, so " <>
                 "this backup was not queued. Try again once the queue clears."

      assert queue_state() == before
    end

    @tag :pg_tools
    test "Resume while a fresh backup is queued is refused and leaves the queue alone",
         %{dir: dir} do
      run = resumable_run!(dir, "20261101-101010")
      started!()
      {:ok, %{status: :queued}} = Backups.request([trigger: "schedule"], Backups.system())
      before = queue_state()
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      html =
        lv |> element(~s|#backup-run-#{run.id} button[data-role="resume"]|) |> render_click()

      assert html =~
               "A backup is running and a new backup is queued after it, so this resume was " <>
                 "not queued. Try again once the queue clears."

      assert queue_state() == before
    end

    @tag :pg_tools
    test "Resume while another backup's resume is queued is refused", %{dir: dir} do
      queued = resumable_run!(dir, "20261101-101010")
      run = resumable_run!(dir, "20261102-101010")
      started!()
      {:ok, %{status: :queued}} = Backups.request([resume: queued.stamp], Backups.system())
      before = queue_state()
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      html =
        lv |> element(~s|#backup-run-#{run.id} button[data-role="resume"]|) |> render_click()

      # The whole flash (#2671): it names the queued run, not the refused one.
      assert html =~
               "A backup is running and a resume of 20261101-101010 is queued after it, so " <>
                 "this resume was not queued. Try again once the queue clears."

      refute html =~ "a resume of 20261102-101010 is queued"
      assert queue_state() == before
    end

    @tag :pg_tools
    test "the archive step reads part i of N", %{dir: dir} do
      %{stamp: stamp} = started!()
      row = lock_row()
      {:ok, dir_id} = DirId.local(dir)

      Backups.move_backup_lock!(
        row,
        %{step: :archive, part: 2, step_job_id: row.step_job_id, dir_id: dir_id},
        actor: Backups.system()
      )

      work = WorkState.path(dir, stamp)
      {:ok, state} = WorkState.read(work)
      :ok = WorkState.write(work, Map.put(state, "parts_total", 3))

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")

      assert has_element?(
               lv,
               ~s|#backup-in-flight [data-role="step"]|,
               "Archiving media: part 2 of 3"
             )
    end

    @tag :pg_tools
    test "a backup that is finishing has no Cancel on the strip, and a forced cancel is refused" do
      %{run: run} = started!()
      Backups.mark_backup_lock_finishing!(lock_row(), %{}, actor: Backups.system())

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      refute has_element?(lv, ~s|#backup-in-flight [data-role="cancel"]|)

      assert render_hook(lv, "cancel_run", %{"id" => run.id}) =~
               "Too late to cancel: the backup is finishing."

      assert %{status: :running} = Backups.get_run!(run.id, actor: Backups.system())
    end

    @tag :pg_tools
    test "the History row drops Cancel once the backup is finishing (#2542)" do
      %{run: run} = started!()

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      row_cancel = ~s|#backup-run-#{run.id} [data-role="cancel"]|
      assert has_element?(lv, row_cancel)

      Backups.mark_backup_lock_finishing!(lock_row(), %{}, actor: Backups.system())
      send(lv.pid, :refresh)

      refute has_element?(lv, row_cancel)
      refute has_element?(lv, ~s|#backup-in-flight [data-role="cancel"]|)
      # The run is still running: only the button went, not the row's state.
      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-role="status"]|, "Running")
    end

    test "a forged cancel of a finished run says it already finished", %{dir: dir} do
      run = app_run!(dir, 2, :succeeded)

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live(~p"/editor/backups")
      render_async(lv, 2_000)

      assert render_hook(lv, "cancel_run", %{"id" => run.id}) =~ "That backup already finished."

      assert render_hook(lv, "cancel_run", %{"id" => Ecto.UUID.generate()}) =~
               "can&#39;t be canceled"

      render_hook(lv, "cancel_run", %{"id" => 7})

      assert %{status: :succeeded} = Backups.get_run!(run.id, actor: Backups.system())
    end

    @tag :pg_tools
    test "the handler re-checks platform admin: editor, org admin, viewer and anonymous get nothing" do
      %{run: run} = started!()

      org_admin = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: org_admin.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      for user <- [authed_user(:editor), org_admin, authed_user(:viewer), nil] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

        assert {:noreply, ^socket} =
                 KilnCMSWeb.BackupLive.handle_event("cancel_run", %{"id" => run.id}, socket)
      end

      assert %{status: :running} = Backups.get_run!(run.id, actor: Backups.system())
      assert Backups.in_flight() != nil
    end
  end

  describe "one headline line per component (#2219)" do
    setup %{dir: dir} do
      media = Path.join(dir, "uploads")
      File.mkdir_p!(media)
      config = Application.get_env(:kiln_cms, KilnCMS.Backups)
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(config, :media_dir, media))
      :ok
    end

    # A finished run covering `components`, `hours` ago.
    defp component_run!(components, hours, status \\ :succeeded) do
      at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
      stamp = KilnCMS.Backups.Artifact.stamp(at)

      artifacts =
        for component <- components do
          %{kind: component, name: "kiln-#{component}-#{stamp}", bytes: 10, verified: true}
        end

      Backups.import_run!(
        %{
          stamp: stamp,
          trigger: "cron",
          status: status,
          components: components,
          started_at: at,
          finished_at: at,
          artifacts: if(status == :succeeded, do: artifacts, else: []),
          error: if(status == :failed, do: "boom")
        },
        actor: Backups.system()
      )
    end

    test "a fresh database and stale media: each says its own, and the tone is the alarm", %{
      conn: conn
    } do
      component_run!([:db, :media], 5 * 24)
      component_run!([:db], 1)

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert has_element?(lv, "#backup-headline-db", "Database")
      assert has_element?(lv, "#backup-headline-db", "Backed up")
      assert has_element?(lv, "#backup-headline-media", "Media")
      assert has_element?(lv, "#backup-headline-media", "Last backup was")
      assert has_element?(lv, "#backup-headline-media", "5 days")
      assert html =~ "border-error/30"
    end

    test "a database-only backup after a full one leaves media's line on the full one", %{
      conn: conn,
      dir: dir
    } do
      component_run!([:db, :media], 3)
      component_run!([:db], 1)

      :ok =
        Manifest.write(dir, %Manifest{
          finished_at: DateTime.utc_now(),
          trigger: "manual",
          ok: true,
          components: ["db"],
          artifacts: [%{kind: "db", path: "db/kiln-db-x.dump", bytes: 1, verified: true}]
        })

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert has_element?(lv, "#backup-headline-db", "Backed up")
      assert has_element?(lv, "#backup-headline-media", "Backed up 3 hours ago")
      assert html =~ "border-success/30"
    end

    # An in-app run, which says what it covered (an imported failed run counts
    # against every component).
    test "a failed media backup fails media's line only", %{conn: conn} do
      component_run!([:db, :media], 3)
      at = DateTime.add(DateTime.utc_now(), -3600, :second)

      run =
        Backups.start_run!(
          %{
            stamp: KilnCMS.Backups.Artifact.stamp(at),
            trigger: "manual",
            components: [:media],
            started_at: at
          },
          actor: Backups.system()
        )

      Backups.fail_run!(run, %{error: "boom"}, actor: Backups.system())

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert has_element?(lv, "#backup-headline-db", "Backed up")
      assert has_element?(lv, "#backup-headline-media", "The last backup failed")
      assert html =~ "border-error/30"
    end

    test "the overview names the component that needs attention", %{conn: conn} do
      component_run!([:db, :media], 3 * 24)
      component_run!([:db], 1)

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               ~s|#overview-backup-warning [data-role="backup-headline"]|,
               "The last media backup was 3 days ago."
             )

      refute has_element?(lv, "#overview-backup-warning", "database")
      refute has_element?(lv, "#overview-backup-setup")
    end

    test "media never backed up while the database is: the alarm, not the set-up notice", %{
      conn: conn
    } do
      component_run!([:db], 1)

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(lv, "#overview-backup-warning", "No media backup has been recorded.")
      refute has_element?(lv, "#overview-backup-setup")
    end

    test "nothing ever backed up is still the set-up notice", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(lv, "#overview-backup-setup")
      refute has_element?(lv, "#overview-backup-warning")
    end
  end

  describe "an off-site remote with no rclone in the image (#2218, #2482)" do
    setup do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(original, :rclone_remote, ":s3,secret_access_key=hunter2hunter2:bucket")
      )

      bin = Path.join(System.tmp_dir!(), "kiln_bklbin_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)
      path = System.get_env("PATH")

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(bin)
      end)

      %{bin: bin}
    end

    test "the panel says backups from this page fail at the off-site copy (#2482)", %{
      conn: conn,
      bin: bin
    } do
      # Only an empty directory on PATH: no rclone anywhere.
      System.put_env("PATH", bin)
      assert Backups.status().rclone_missing?

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-rclone-missing",
               "rclone is not installed in this image, so backups taken from this page fail " <>
                 "at the off-site copy. Install rclone in the image or unset BACKUP_RCLONE_REMOTE."
             )

      refute render(lv) =~ "hunter2hunter2"
    end

    test "with rclone installed it says nothing of the kind", %{conn: conn, bin: bin} do
      File.write!(Path.join(bin, "rclone"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, "rclone"), 0o755)
      System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
      refute Backups.status().rclone_missing?

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/backups")
      refute has_element?(lv, "#backup-rclone-missing")
    end
  end

  describe "the overview warning" do
    # Day one of every install: nothing has run because nothing could have yet.
    # Still said — backups are not optional before launch — but as a neutral
    # next step, not the red alarm (usability pass, M2). `Backups.stale?(nil)`
    # itself stays true; the branch is in the view.
    test "an admin with no backup ever recorded gets the calm set-up notice, not the alarm",
         %{conn: conn} do
      assert KilnCMS.Backups.stale?(nil)

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               "#overview-backup-setup",
               "Backups aren't set up yet — turn them on before you go live."
             )

      assert has_element?(
               lv,
               "#overview-backup-setup a[data-role=open-backups][href='/editor/backups']"
             )

      refute has_element?(lv, "#overview-backup-warning")
      refute render(lv) =~ "No backup has ever been recorded"
    end

    # #1772: without an in-app schedule (part of #2219), the schedule is the
    # operator's cron job. The strip must not promise a schedule that doesn't
    # exist, nor link to the Schedule tab as though one did, and must point at
    # the guide that explains cron. With one, see "the overview strips with
    # in-app schedules" below.
    test "without an in-app schedule, neither strip promises one or links to the Schedule tab",
         %{conn: conn, dir: dir} do
      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute html =~ "set a schedule"
      assert has_element?(lv, "#overview-backup-setup", "set up by whoever runs this server")
      refute has_element?(lv, "#overview-backup-setup a[data-role=open-schedule]")
      refute has_element?(lv, "#overview-backup-setup [data-role=backup-next]")

      assert has_element?(
               lv,
               ~s(#overview-backup-setup a[data-role=backup-guide][href$="docs/backups.md"][target=_blank])
             )

      seed_manifest!(dir, ok: false)
      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute html =~ "check the schedule"
      assert has_element?(lv, "#overview-backup-warning", "the server's cron job")
      refute has_element?(lv, "#overview-backup-warning a[data-role=open-schedule]")
      assert has_element?(lv, "#overview-backup-warning a[data-role=backup-guide]")
      assert has_element?(lv, "#overview-backup-warning a[data-role=open-backups]")
    end

    test "a failed backup is the red alarm", %{conn: conn, dir: dir} do
      seed_manifest!(dir, ok: false)

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(lv, "#overview-backup-warning", "The last database backup failed.")
      refute has_element?(lv, "#overview-backup-setup")
    end

    test "a backup that went stale is the red alarm", %{conn: conn, dir: dir} do
      long_ago = DateTime.add(DateTime.utc_now(), -30, :day)
      seed_manifest!(dir, started_at: long_ago, finished_at: long_ago)

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               "#overview-backup-warning",
               "The last database backup was 30 days ago."
             )

      refute has_element?(lv, "#overview-backup-setup")
    end

    test "it disappears once a backup is fresh", %{conn: conn, dir: dir} do
      # Absent rather than green: a permanent banner is one nobody reads, and
      # its absence is what makes the red one land.
      seed_manifest!(dir, [])

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute html =~ "overview-backup-warning"
      refute has_element?(lv, "#overview-backup-setup")
    end

    test "an editor never sees it — they can't act on it", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

      refute html =~ "overview-backup-warning"
    end

    # #1160. The strip links to `/editor/backups`, which now takes a PLATFORM
    # admin — so gating the strip on the per-org tier would report on the whole
    # instance's infrastructure to an admin of one site, and send them to a page
    # that turns them away.
    test "nor does an org admin who is not a platform admin", %{conn: conn} do
      user = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: user.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      {:ok, _lv, html} = conn |> log_in(user) |> live(~p"/editor/overview")

      # The premise: they are an admin as far as the per-org tier is concerned,
      # so this is not just the editor case again.
      assert KilnCMS.Accounts.Scoping.effective_tier(user, KilnCMS.Accounts.default_org_id()) ==
               :admin

      refute html =~ "overview-backup-warning"
    end
  end

  describe "page help, trigger labels and retention markers (#2542)" do
    alias KilnCMS.Backups.WorkState

    defp touch_marker!(dir, sub, name) do
      File.mkdir_p!(Path.join(dir, sub))
      File.write!(Path.join([dir, sub, name]), "")
    end

    defp mount_admin(conn, locale \\ nil) do
      conn = admin_conn(conn)
      conn = if locale, do: Plug.Conn.put_session(conn, "locale", locale), else: conn
      {:ok, lv, _html} = live(conn, ~p"/editor/backups")
      render_async(lv, 2_000)
      lv
    end

    # An in-app run in `status` whose state file is kept, so it is resumable.
    defp resumable_run!(dir, stamp, status) do
      run = Ash.Seed.seed!(KilnCMS.Backups.Run, %{stamp: stamp, status: status})
      put_state!(dir, stamp)
      run
    end

    defp put_state!(dir, stamp) do
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))
    end

    test "Back up now explains queuing, in the words of the refusal", %{conn: conn} do
      lv = mount_admin(conn)

      assert has_element?(
               lv,
               ~s|button[phx-click="backup_now"][aria-describedby="backup-now-help"]|
             )

      assert has_element?(lv, "#backup-now-help", "only one waits")
      assert has_element?(lv, "#backup-now-help", "refused until the queue clears")
    end

    test "Resume's tooltip says what kind of backup it continues", %{conn: conn, dir: dir} do
      canceled = resumable_run!(dir, "20261106-101010", :canceled)
      failed = resumable_run!(dir, "20261107-101010", :failed)

      lv = mount_admin(conn)

      assert has_element?(
               lv,
               ~s|#backup-run-#{canceled.id} button[data-role="resume"][title="Continue this canceled backup from the files it already wrote. Right after a Cancel, wait about two and a half minutes."]|
             )

      assert has_element?(
               lv,
               ~s|#backup-run-#{failed.id} button[data-role="resume"][title="Continue this failed backup from the files it already wrote."]|
             )
    end

    test "a resumable row explains Resume in a ? tip; other rows have none (#2425)", %{
      conn: conn,
      dir: dir
    } do
      failed = resumable_run!(dir, "20261107-101010", :failed)
      canceled = resumable_run!(dir, "20261106-101010", :canceled)

      # Quiet for a day: the stale `running` run the page reads as Interrupted.
      day_ago = DateTime.add(DateTime.utc_now(), -1, :day)

      interrupted =
        Ash.Seed.seed!(KilnCMS.Backups.Run, %{
          stamp: "20261105-101010",
          status: :running,
          started_at: day_ago,
          updated_at: day_ago
        })

      put_state!(dir, interrupted.stamp)

      # Kept state files, so only the status keeps these from being resumable.
      succeeded = resumable_run!(dir, "20261104-101010", :succeeded)
      imported = seed_run!(dir, 3)
      put_state!(dir, imported.stamp)

      lv = mount_admin(conn)

      for run <- [failed, canceled, interrupted] do
        assert has_element?(lv, ~s|#backup-run-#{run.id} button[data-role="resume"]|)

        assert has_element?(
                 lv,
                 ~s|#backup-run-#{run.id} #resume-help-#{run.id}|,
                 "each is reused only if its checksum still matches"
               )

        assert has_element?(
                 lv,
                 ~s|#resume-help-#{run.id}|,
                 "so its files can be from different times"
               )

        assert has_element?(
                 lv,
                 ~s|#resume-help-#{run.id} a[href$="/docs/backups.md#media-backups-in-parts-2218"]|
               )
      end

      for run <- [succeeded, imported] do
        assert has_element?(lv, "#backup-run-#{run.id}")
        refute has_element?(lv, "#resume-help-#{run.id}")
      end
    end

    test "a media set in parts links to the multi-part restore; a single archive does not (#2425)",
         %{conn: conn} do
      media = fn stamp, parts ->
        Backups.import_run!(
          %{
            stamp: stamp,
            trigger: "cron",
            status: :succeeded,
            components: [:media],
            started_at: ~U[2026-01-05 03:00:00.000000Z],
            finished_at: ~U[2026-01-05 03:05:00.000000Z],
            artifacts: [
              %{
                kind: :media,
                name: "kiln-media-#{stamp}",
                bytes: 1024 * max(length(parts), 1),
                verified: true,
                parts: parts,
                destinations: %{"local" => %{"status" => "ok"}}
              }
            ]
          },
          actor: Backups.system()
        )
      end

      part = &%{"name" => "kiln-media-20260105-030000.part0#{&1}.tar.gz", "bytes" => 1024}
      split = media.("20260105-030000", Enum.map(1..2, part))
      single = media.("20260106-030000", [])

      lv = mount_admin(conn)

      assert has_element?(
               lv,
               ~s|#backup-run-#{split.id} a[data-role="parts"][target="_blank"][href$="/docs/backups.md#restore-a-media-set-that-has-several-parts"]|,
               "2 parts"
             )

      assert has_element?(lv, "#backup-run-#{single.id}")
      refute has_element?(lv, ~s|#backup-run-#{single.id} [data-role="parts"]|)
    end

    test "the docs anchors the page links to are headings of docs/backups.md (#2425)" do
      doc = File.read!(Path.expand("../../../docs/backups.md", __DIR__))

      # GitHub's heading slug: lowercased, punctuation other than `-` dropped,
      # spaces to `-`.
      slugs =
        for [heading] <- Regex.scan(~r/^\#{1,6} +(.+?) *$/m, doc, capture: :all_but_first),
            into: MapSet.new() do
          heading
          |> String.downcase()
          |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
          |> String.replace(" ", "-")
        end

      for fragment <- [
            "restore-a-media-set-that-has-several-parts",
            "media-backups-in-parts-2218"
          ] do
        assert fragment in slugs, "docs/backups.md has no heading whose anchor is ##{fragment}"
      end
    end

    test "manual, cron, console and schedule read as labels; anything else as recorded", %{
      conn: conn,
      dir: dir
    } do
      runs =
        for {trigger, n} <-
              Enum.with_index(["manual", "cron", "console", "schedule", "nightly-ops"], 1),
            do: {trigger, seed_run!(dir, n, trigger: trigger)}

      lv = mount_admin(conn)

      for {trigger, run} <- runs do
        label =
          %{
            "manual" => "Manual",
            "cron" => "Cron",
            "console" => "Console",
            "schedule" => "Scheduled"
          }[trigger]

        assert has_element?(
                 lv,
                 ~s|#backup-run-#{run.id} [data-role="trigger"]|,
                 label || trigger
               )
      end
    end

    test "a recovery point and the last-good markers badge their rows", %{conn: conn, dir: dir} do
      kept = seed_run!(dir, 1, stamp: "20260101-010000")
      good = seed_run!(dir, 2, stamp: "20260102-020000")
      plain = seed_run!(dir, 3, stamp: "20260103-030000")

      touch_marker!(dir, "media", "kiln-20260101-010000.keep")
      touch_marker!(dir, "db", "kiln-20260102-020000.good")
      touch_marker!(dir, "media", "kiln-20260102-020000.good")

      lv = mount_admin(conn)

      assert has_element?(
               lv,
               ~s|#backup-run-#{kept.id} [data-role="recovery-point"]|,
               "Recovery point"
             )

      refute has_element?(lv, ~s|#backup-run-#{kept.id} [data-role="last-good"]|)

      assert has_element?(
               lv,
               ~s|#backup-run-#{good.id} [data-role="last-good"][data-component="db"]|,
               "Last good: Database"
             )

      assert has_element?(
               lv,
               ~s|#backup-run-#{good.id} [data-role="last-good"][data-component="media"]|,
               "Last good: Media"
             )

      refute has_element?(lv, ~s|#backup-run-#{good.id} [data-role="recovery-point"]|)

      refute has_element?(lv, ~s|#backup-run-#{plain.id} [data-role="recovery-point"]|)
      refute has_element?(lv, ~s|#backup-run-#{plain.id} [data-role="last-good"]|)
    end

    test "the summary names each component's last-good stamp, even off this page", %{
      conn: conn,
      dir: dir
    } do
      # No run row for this stamp at all: the line still says it.
      touch_marker!(dir, "db", "kiln-20250101-010000.good")

      lv = mount_admin(conn)

      assert has_element?(
               lv,
               ~s|#backup-last-good [data-role="last-good"][data-component="db"]|,
               "20250101-010000"
             )

      assert has_element?(lv, "#backup-markers-help", "kiln-<stamp>.keep")
      assert has_element?(lv, "#backup-markers-help", "every 15 minutes")
      assert has_element?(lv, "#backup-markers-help", "this server's backup directory")
    end

    test "the summary says none yet for each component without a marker", %{conn: conn} do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :media_dir, "/srv/media")
      )

      lv = mount_admin(conn)

      for component <- ["db", "media"] do
        assert has_element?(
                 lv,
                 ~s|#backup-last-good [data-role="last-good"][data-component="#{component}"]|,
                 "none yet"
               )
      end
    end

    test "a db/ that can't be listed shows no badges and doesn't crash the page", %{
      conn: conn,
      dir: dir
    } do
      run = seed_run!(dir, 1, stamp: "20260101-010000", file?: false)
      # A file where the directory should be: unlistable for every user.
      File.rm_rf!(Path.join(dir, "db"))
      File.write!(Path.join(dir, "db"), "")
      touch_marker!(dir, "media", "kiln-20260101-010000.good")

      lv = mount_admin(conn)

      assert has_element?(lv, "#backup-run-#{run.id}")

      refute has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="last-good"][data-component="db"]|
             )

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="last-good"][data-component="media"]|
             )

      assert has_element?(
               lv,
               ~s|#backup-last-good [data-role="last-good"][data-component="db"]|,
               "none yet"
             )
    end

    for {locale, help, canceled, failed, keep} <- [
          {"es", "solo una espera",
           "Continúa esta copia de seguridad cancelada a partir de los archivos que ya escribió. Justo después de cancelarla, espera unos dos minutos y medio.",
           "Continúa esta copia de seguridad fallida a partir de los archivos que ya escribió.",
           "Punto de recuperación"},
          {"fr", "une seule attend",
           "Reprendre cette sauvegarde annulée à partir des fichiers déjà écrits. Juste après une annulation, attendez environ deux minutes et demie.",
           "Reprendre cette sauvegarde échouée à partir des fichiers déjà écrits.",
           "Point de restauration"}
        ] do
      test "help text, tooltips and badges are translated (#{locale})", %{conn: conn, dir: dir} do
        canceled = resumable_run!(dir, "20261106-101010", :canceled)
        failed = resumable_run!(dir, "20261107-101010", :failed)
        touch_marker!(dir, "db", "kiln-20261106-101010.keep")

        lv = mount_admin(conn, unquote(locale))

        assert has_element?(lv, "#backup-now-help", unquote(help))
        refute has_element?(lv, "#backup-now-help", "only one waits")

        assert has_element?(
                 lv,
                 ~s|#backup-run-#{canceled.id} button[data-role="resume"][title="#{unquote(canceled)}"]|
               )

        assert has_element?(
                 lv,
                 ~s|#backup-run-#{failed.id} button[data-role="resume"][title="#{unquote(failed)}"]|
               )

        assert has_element?(
                 lv,
                 ~s|#backup-run-#{canceled.id} [data-role="recovery-point"]|,
                 unquote(keep)
               )

        refute has_element?(lv, "#backup-markers-help", "every 15 minutes")
      end
    end

    test "a non-platform-admin still can't reach the page, markers or not", %{
      conn: conn,
      dir: dir
    } do
      touch_marker!(dir, "db", "kiln-20250101-010000.good")
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, _}} = live(conn, ~p"/editor/backups")
    end
  end

  # Part of #2219: the schedules themselves are on the Schedule tab
  # (`BackupScheduleLiveTest`); this page keeps the next scheduled backup, the
  # warnings that say they can't run, and each component's alarm threshold,
  # all from `Backups.status/0`.
  describe "schedules on the Backups tab" do
    import KilnCMS.Test.BackupSchedules, only: [schedule!: 2, force!: 2]

    @baseline ~U[2026-01-01 00:00:00.000000Z]

    defp mount_backups(conn, admin) do
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/backups")
      lv
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

    test "the tabs mark Backups current and link to Schedule", %{conn: conn} do
      lv = mount_backups(conn, authed_user(:admin))

      assert has_element?(lv, "#backup-tab-history[aria-current=page]", "Backups")

      assert has_element?(
               lv,
               "#backup-tab-schedule[href='/editor/backups/schedules']",
               "Schedule"
             )

      refute has_element?(lv, "#backup-tab-schedule[aria-current]")
    end

    test "no schedules: the environment's threshold, and no next scheduled backup", %{conn: conn} do
      lv = mount_backups(conn, authed_user(:admin))

      refute has_element?(lv, "#backup-next-scheduled")
      refute has_element?(lv, "#backup-schedules-off")

      assert has_element?(
               lv,
               "#backup-threshold-db",
               "Alarm after 36 hours without a good backup (BACKUP_STALE_AFTER_HOURS)"
             )
    end

    @tag :pg_tools
    test "a schedule that runs here: the next scheduled backup and the threshold it sets",
         %{conn: conn} do
      admin = authed_user(:admin)
      force!(schedule!(%{interval: :weekly}, admin), baseline_at: @baseline)

      lv = mount_backups(conn, admin)

      # Its latest window (since the 2026 baseline) is due and unclaimed.
      assert has_element?(
               lv,
               "#backup-next-scheduled a[href='/editor/backups/schedules']",
               "Next scheduled backup: due now"
             )

      assert has_element?(
               lv,
               "#backup-threshold-db",
               "Alarm after 252 hours without a good backup (its schedule)"
             )

      # The list itself is the Schedule tab's.
      refute has_element?(lv, "[data-role=cadence]")
    end

    test "a paused schedule shows no next scheduled backup", %{conn: conn} do
      admin = authed_user(:admin)
      schedule!(%{enabled: false}, admin)

      refute has_element?(mount_backups(conn, admin), "#backup-next-scheduled")
    end

    test "with the scheduler off, it says so and shows no next scheduled backup", %{conn: conn} do
      admin = authed_user(:admin)
      force!(schedule!(%{}, admin), baseline_at: @baseline)
      put_cron("false")

      lv = mount_backups(conn, admin)

      assert has_element?(
               lv,
               "#backup-schedules-off",
               "In-app schedules are turned off (KILN_BACKUP_SCHEDULER_CRON)."
             )

      refute has_element?(lv, "#backup-next-scheduled")
    end

    test "when backups can't run here, it says why and shows no next scheduled backup",
         %{conn: conn} do
      admin = authed_user(:admin)
      force!(schedule!(%{}, admin), baseline_at: @baseline)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :enabled, false)
      )

      lv = mount_backups(conn, admin)

      assert has_element?(
               lv,
               "#backup-schedules-unavailable",
               "Scheduled backups can't run here:"
             )

      refute has_element?(lv, "#backup-next-scheduled")
    end
  end

  # Step 9 of #2219 part 2: the home strips with in-app schedules. Here, not
  # in `OverviewLiveTest`, because they change the VM-wide backup config.
  describe "the overview strips with in-app schedules" do
    import KilnCMS.Test.BackupSchedules, only: [schedule!: 2, force!: 2]

    defp headlines(html),
      do: Regex.scan(~r/data-role="backup-headline"/, html)

    defp put_backups_enabled(value) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :enabled, value)
      )
    end

    @tag :pg_tools
    test "never backed up, with a schedule that runs here: when the first one is", %{conn: conn} do
      admin = authed_user(:admin)
      schedule!(%{}, admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               "#overview-backup-setup [data-role=backup-next]",
               "First scheduled backup: in "
             )

      assert has_element?(
               lv,
               "#overview-backup-setup a[data-role=open-schedule][href='/editor/backups/schedules']",
               "Open the schedule"
             )

      refute has_element?(lv, "#overview-backup-setup", "are a cron job set up by")
    end

    @tag :pg_tools
    test "a failed backup, with a schedule that runs here: when the next one is",
         %{conn: conn, dir: dir} do
      admin = authed_user(:admin)
      schedule!(%{}, admin)
      seed_manifest!(dir, ok: false)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               "#overview-backup-warning [data-role=backup-next]",
               "Next scheduled backup: in "
             )

      refute has_element?(lv, "#overview-backup-warning [data-role=backup-next]", "in in")
      assert has_element?(lv, "#overview-backup-warning a[data-role=open-schedule]")
      refute has_element?(lv, "#overview-backup-warning", "ask whoever runs this server")
    end

    # A window that is due and waiting reads "due now", not "in 0 minutes".
    @tag :pg_tools
    test "a window that is due reads due now", %{conn: conn} do
      admin = authed_user(:admin)
      force!(schedule!(%{}, admin), baseline_at: ~U[2026-01-01 00:00:00.000000Z])

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               "#overview-backup-setup [data-role=backup-next]",
               "First scheduled backup: due now."
             )
    end

    # E2: a schedule of the healthy component says nothing about the one in
    # alarm.
    @tag :pg_tools
    test "the next window of a component in alarm, not of a healthy one", %{conn: conn, dir: dir} do
      admin = authed_user(:admin)
      media = Path.join(dir, "media-src")
      File.mkdir_p!(media)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :media_dir, media)
      )

      # The media schedule only; the database backed up just now, media never.
      schedule!(%{components: [:media]}, admin)

      now = DateTime.utc_now()
      write_artifact!(dir, "kiln-db-20260101-030000.dump")

      Backups.import_run!(
        %{
          stamp: "20260101-030000",
          trigger: "cron",
          status: :succeeded,
          components: [:db],
          started_at: now,
          finished_at: now,
          artifacts: [
            %{kind: :db, name: "kiln-db-20260101-030000.dump", bytes: 2048, verified: true}
          ]
        },
        actor: Backups.system()
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")
      assert [_media_only] = lv |> element("#overview-backup-warning") |> render() |> headlines()
      assert has_element?(lv, "#overview-backup-warning [data-role=backup-headline]", "media")
      assert has_element?(lv, "#overview-backup-warning [data-role=backup-next]")

      # Now the schedule covers the healthy database only: no next for media.
      [s] = Backups.list_backup_schedules!(actor: admin)
      Backups.update_backup_schedule!(s, %{components: [:db]}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")
      refute has_element?(lv, "#overview-backup-warning [data-role=backup-next]")

      assert has_element?(
               lv,
               "#overview-backup-warning",
               "in-app schedules on the Schedule tab of Backups"
             )
    end

    # Two components in alarm, a schedule for one of them: no time for "the
    # next scheduled backup", which would leave the other in alarm after it.
    @tag :pg_tools
    test "a schedule for only some of the components in alarm shows no next time",
         %{conn: conn, dir: dir} do
      admin = authed_user(:admin)
      media = Path.join(dir, "media-src")
      File.mkdir_p!(media)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :media_dir, media)
      )

      at = DateTime.add(DateTime.utc_now(), -5 * 24 * 3600, :second)
      stamp = KilnCMS.Backups.Artifact.stamp(at)

      Backups.import_run!(
        %{
          stamp: stamp,
          trigger: "cron",
          status: :succeeded,
          components: [:db, :media],
          started_at: at,
          finished_at: at,
          artifacts: [
            %{kind: :db, name: "kiln-db-#{stamp}", bytes: 10, verified: true},
            %{kind: :media, name: "kiln-media-#{stamp}", bytes: 10, verified: true}
          ]
        },
        actor: Backups.system()
      )

      s = schedule!(%{components: [:db]}, admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")
      assert [_, _] = lv |> element("#overview-backup-warning") |> render() |> headlines()
      refute has_element?(lv, "#overview-backup-warning [data-role=backup-next]")

      assert has_element?(
               lv,
               "#overview-backup-warning",
               "in-app schedules on the Schedule tab of Backups"
             )

      # Both scheduled: the next time is shown.
      Backups.update_backup_schedule!(s, %{components: [:db, :media]}, actor: admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")
      assert has_element?(lv, "#overview-backup-warning [data-role=backup-next]")
    end

    # D9: schedules that exist but can't run here keep the sentence that
    # names both the tab and cron, and still link to the tab.
    test "with a schedule that can't run here, the strip names the tab and cron", %{conn: conn} do
      admin = authed_user(:admin)
      schedule!(%{}, admin)
      put_backups_enabled(false)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      strip =
        if has_element?(lv, "#overview-backup-setup"),
          do: "#overview-backup-setup",
          else: "#overview-backup-warning"

      assert has_element?(lv, strip, "in-app schedules on the Schedule tab of Backups")
      refute has_element?(lv, "#{strip} [data-role=backup-next]")
      assert has_element?(lv, "#{strip} a[data-role=open-schedule]")
    end

    @tag :pg_tools
    test "healthy with a schedule: no strip", %{conn: conn, dir: dir} do
      admin = authed_user(:admin)
      schedule!(%{}, admin)
      seed_manifest!(dir, %{})

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      refute has_element?(lv, "#overview-backup-setup")
      refute has_element?(lv, "#overview-backup-warning")
    end
  end
end
