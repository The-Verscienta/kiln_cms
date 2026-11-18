defmodule KilnCMSWeb.BackupLiveTest.StallingDiskView do
  @moduledoc false
  # A `Backups.DiskView` that tells the test it started and waits for `:go`,
  # so a test decides when a disk read answers (#2417).
  def read(dir, runs, now) do
    test = Application.fetch_env!(:kiln_cms, __MODULE__)
    send(test, {:disk_read, self(), Enum.map(runs, & &1.id)})

    receive do
      :go -> KilnCMS.Backups.DiskView.read(dir, runs, now)
    end
  end
end

defmodule KilnCMSWeb.BackupLiveTest.CrashingDiskView do
  @moduledoc false
  # A `Backups.DiskView` whose read crashes, so the page's disk state is
  # `:failed` (#2940).
  def read(_dir, _runs, _now), do: raise("disk read crashed")
end

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

  # A former platform admin whose grant has expired (#2875): `role` is what
  # they hold without it.
  defp expired_grant_user do
    %{
      role: :editor,
      granted_role: :admin,
      granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    }
  end

  # A handler's answer to a socket that isn't a platform admin's (#2875): sent
  # to the access-denied page, as the mount would have, with no flash.
  defp assert_denied({:noreply, socket}) do
    assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = socket.redirected
    refute socket.assigns[:flash]
  end

  # The page reads `Backups.status/0`, the import and the backup directory in
  # the background (#2417), and one result can start another read (the import
  # landing asks for the disk again). `live/2` returns before any of it lands:
  # this mounts, then waits until nothing is out (`data-busy="false"`).
  defp live_ready(conn, path) do
    {:ok, lv, _html} = live(conn, path)
    {:ok, lv, await_page(lv)}
  end

  defp await_page(lv, tries \\ 20)

  defp await_page(lv, 0) do
    flunk("the Backups page was still busy: #{render(lv)}")
  end

  defp await_page(lv, tries) do
    html = render_async(lv, 2_000)

    if has_element?(lv, ~s|#backup-page[data-busy="false"]|),
      do: html,
      else: await_page(lv, tries - 1)
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
        conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

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
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")
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
      for user <- [%{role: :editor}, expired_grant_user()] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}
        assert_denied(KilnCMSWeb.BackupLive.handle_event("backup_now", %{}, socket))
      end

      # Scoped to the worker this handler would have enqueued (#1354).
      refute Enum.any?(
               KilnCMS.Repo.all(Oban.Job),
               &String.starts_with?(&1.worker, "KilnCMS.Backups.Worker")
             )
    end
  end

  describe "what it says when there is no backup" do
    test "says so outright, and in the alarming tone", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

      assert html =~ "No backup has ever been recorded"
      # Error tone, not a neutral note: an unprotected deployment is the state
      # this page exists to make impossible to miss.
      assert html =~ "border-error/30"
    end

    test "names the file it looked for, so an admin can tell 'never ran' from 'ran elsewhere'", %{
      conn: conn,
      dir: dir
    } do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

      assert html =~ Manifest.path(dir)
    end
  end

  describe "reporting a backup it did not run" do
    test "renders a manifest written by cron's shell script", %{conn: conn, dir: dir} do
      # The whole point: the canonical path is still cron, and a panel that
      # only knew about app-triggered runs would show "never" on exactly the
      # deployments that are backing up correctly.
      seed_manifest!(dir, trigger: "cron")

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

      assert html =~ "Backed up"
      assert html =~ "cron"
      assert html =~ "kiln-db-20260805-031700.dump"
      assert html =~ "2.0 KB"
      assert html =~ "Verified"
      assert html =~ "border-success/30"
    end

    test "an old backup reads as stale", %{conn: conn, dir: dir} do
      seed_manifest!(dir, finished_at: DateTime.add(DateTime.utc_now(), -5 * 86_400, :second))

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

      assert html =~ "Last backup was"
      assert html =~ "5 days"
      assert html =~ "border-error/30"
    end

    test "a FAILED run shows its own error, not the last success", %{conn: conn, dir: dir} do
      seed_manifest!(dir, ok: false, artifacts: [], error: "pg_dump exited 1: connection refused")

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

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

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

      refute html =~ "border-success/30"
      assert html =~ "border-error/30"
    end

    test "a failed run doesn't advertise '0 B · 0 file(s)' next to its error", %{
      conn: conn,
      dir: dir
    } do
      seed_manifest!(dir, ok: false, artifacts: [], error: "boom")

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

      refute html =~ "0 file(s)"
    end
  end

  describe "backing up now" do
    test "is refused, with a reason, when the deployment can't run one", %{conn: conn} do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

      # The button is disabled rather than absent, so the reason has somewhere
      # to live — an admin who can't back up needs to know why, not wonder
      # where the button went.
      assert html =~ "disabled"
      assert lv |> element(~s|button[phx-click="backup_now"][disabled]|) |> has_element?()
    end

    test "enqueues a job and says so", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

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
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      row = lv |> element("#backup-run-#{run.id}") |> render()
      assert row =~ "3.0 KB"
      assert row =~ "3 parts"
      assert has_element?(lv, "#backup-run-#{run.id} [data-presence=present]", "on disk")

      File.rm!(Path.join([dir, "media", Enum.at(names, 1)]))
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")
      assert has_element?(lv, "#backup-run-#{run.id} [data-presence=missing]", "missing")
    end

    test "a file deleted out-of-band reads missing", %{conn: conn, dir: dir} do
      run = seed_run!(dir, 1, started_at: DateTime.add(DateTime.utc_now(), -3600, :second))
      File.rm!(Path.join([dir, "db", hd(run.artifacts).name]))

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      # Imported (cron-made), long past retention, with a newer complete dump
      # on disk: cron's prune keeps the newest one, so only an older one can
      # have expired (#2416).
      write_artifact!(dir, "kiln-db-20260301-030000.dump")

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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      # No manifest of cron's says its keep days: the app's stand in, and the
      # row only says probably.
      assert has_element?(
               lv,
               "#backup-run-#{expired.id} [data-presence=probably_expired]",
               "probably expired"
             )

      assert has_element?(lv, "#backup-run-#{expired.id}", "unverified (imported)")
      assert has_element?(lv, "#presence-help-#{expired.id}", "an estimate")
      assert has_element?(lv, "#imported-help-#{expired.id}", "scripts/backup.sh verify")
      refute has_element?(lv, "#presence-help-#{pruned.id}")
      refute has_element?(lv, "#imported-help-#{pruned.id}")

      # backup.sh's manifest records its BACKUP_KEEP_DAYS: now it is known.
      seed_manifest!(dir, keep_days: 14)
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")
      assert has_element?(lv, "#backup-run-#{expired.id} [data-presence=expired]", "expired")
      assert has_element?(lv, "#presence-help-#{expired.id}", "BACKUP_KEEP_DAYS it records")

      assert has_element?(
               lv,
               ~s|#presence-help-#{expired.id} a[href$="/docs/backups.md#backup-history-2217"]|
             )
    end

    test "cron-made backups on disk are imported and shown", %{conn: conn, dir: dir} do
      path = Path.join([dir, "db"])
      File.mkdir_p!(path)
      file = Path.join(path, "kiln-db-20260102-030000.dump")
      File.write!(file, "dump")
      File.touch!(file, System.os_time(:second) - 3600)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups?page=abc")
      assert lv |> element("#backup-history") |> render() =~ "Page 1 of 2"
    end

    # #2875: the Schedule tab's "Last scheduled run" links here with `?run=`.
    defp hourly_runs!(dir, count) do
      for n <- 1..count do
        seed_run!(dir, n,
          stamp: "20260101-00#{String.pad_leading(Integer.to_string(n), 2, "0")}00",
          started_at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n * 3600, :second)
        )
      end
    end

    test "?run= opens the page that holds the run, marks its row and asks to reveal it", %{
      conn: conn,
      dir: dir
    } do
      [oldest | _] = runs = hourly_runs!(dir, 27)
      newest = List.last(runs)

      # Newest first: the oldest two are on page 2. `?run=` wins over `?page=`.
      {:ok, lv, _html} =
        conn |> admin_conn() |> live_ready(~p"/editor/backups?#{%{page: 1, run: oldest.id}}")

      assert lv |> element("#backup-history") |> render() =~ "Page 2 of 2"
      assert has_element?(lv, ~s|#backup-run-#{oldest.id}[aria-current="true"]|)
      assert_push_event(lv, "kiln:reveal", %{id: "backup-run-" <> id})
      assert id == oldest.id

      assert lv
             |> element("#backup-history")
             |> render()
             |> String.split("aria-current")
             |> length() ==
               2

      # The id as typed in another case is the same run.
      upper = String.upcase(newest.id)
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups?#{%{run: upper}}")
      assert lv |> element("#backup-history") |> render() =~ "Page 1 of 2"
      assert has_element?(lv, ~s|#backup-run-#{newest.id}[aria-current="true"]|)

      # Paging away drops the mark.
      lv
      |> element(~s|#backup-history button[phx-click="page"]:not([disabled])|)
      |> render_click()

      assert_patch(lv, ~p"/editor/backups?page=2")
      refute has_element?(lv, "#backup-history [aria-current]")
    end

    test "?run= ties on started_at are broken by id, as the history sorts them", %{dir: dir} do
      at = ~U[2026-01-01 03:00:00.000000Z]

      ids =
        for n <- 1..26 do
          stamp = "20260101-03#{String.pad_leading(Integer.to_string(n), 2, "0")}00"
          seed_run!(dir, n, stamp: stamp, started_at: at).id
        end

      admin = authed_user(:admin)

      %{results: page_two} =
        Backups.run_history!(actor: admin, page: [limit: 25, offset: 25, count: true])

      assert [%{id: last}] = page_two
      assert last == Enum.min(ids)

      for id <- ids do
        expected = if id == last, do: 2, else: 1
        assert Backups.history_page_of(id, admin, 25) == {:ok, expected}
      end
    end

    test "?run= that isn't a run says so and opens page 1", %{conn: conn, dir: dir} do
      hourly_runs!(dir, 27)

      for bad <- ["not-a-uuid", Ecto.UUID.generate(), "", "1 OR 1=1"] do
        {:ok, lv, html} = conn |> admin_conn() |> live_ready(~p"/editor/backups?#{%{run: bad}}")

        assert html =~ "That backup isn&#39;t in the history."
        assert lv |> element("#backup-history") |> render() =~ "Page 1 of 2"
        refute has_element?(lv, "#backup-history [aria-current]")
      end

      # A list where an id belongs is not a run either; it reads as no `?run=`.
      {:ok, lv, html} = conn |> admin_conn() |> live_ready("/editor/backups?run[]=x")
      refute html =~ "isn&#39;t in the history"
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

      {:ok, _lv, _html} = live_ready(conn, ~p"/editor/backups")
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

    test "handle_params and the page event refuse a non-admin on their own", %{dir: dir} do
      run = seed_run!(dir, 1)

      for user <- [%{role: :editor}, expired_grant_user()] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

        assert_denied(KilnCMSWeb.BackupLive.handle_event("page", %{"to" => "2"}, socket))
        assert_denied(KilnCMSWeb.BackupLive.handle_params(%{}, "/", socket))

        # `?run=` is never looked up for them: no flash says whether it exists.
        assert_denied(KilnCMSWeb.BackupLive.handle_params(%{"run" => run.id}, "/", socket))
      end
    end

    test "the history refreshes when a manual backup finishes", %{conn: conn, dir: dir} do
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")
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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, ~s|#backup-run-#{run.id} button[data-role="resume"]|, "Resume")
    end

    test "only resumable runs get the button", %{conn: conn, dir: dir} do
      succeeded = app_run!(dir, 2, :succeeded)
      running = app_run!(dir, 3, :running)
      no_state = app_run!(dir, 4, :failed, state?: false)
      imported = seed_run!(dir, 5)
      File.mkdir_p!(WorkState.path(dir, imported.stamp))
      :ok = WorkState.write(WorkState.path(dir, imported.stamp), WorkState.new(imported.stamp))

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert render_hook(lv, "resume_run", %{"id" => run.id}) =~ "can&#39;t be resumed"
      assert backup_jobs() == []
    end

    @tag :pg_tools
    test "the handler re-checks platform admin: editor, org admin, expired grant and anonymous are sent away",
         %{dir: dir} do
      run = app_run!(dir, 1, :failed)

      org_admin = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: org_admin.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      for user <- [
            authed_user(:editor),
            org_admin,
            authed_user(:viewer),
            expired_grant_user(),
            nil
          ] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

        assert_denied(KilnCMSWeb.BackupLive.handle_event("resume_run", %{"id" => run.id}, socket))
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

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

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
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, ~s|button[phx-click="backup_now"][phx-disable-with]|)
    end

    test "a seeded canceled run reads Canceled, and Resume is offered when its files are kept",
         %{dir: dir} do
      stamp = "20261106-101010"
      run = Ash.Seed.seed!(KilnCMS.Backups.Run, %{stamp: stamp, status: :canceled})
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, ~s|#{row} [data-role="status"]|, "Canceled")
      assert has_element?(lv, ~s|#{row} button[data-role="resume"]|)
      refute has_element?(lv, ~s|#{row} [data-role="cancel"]|)
    end

    @tag :pg_tools
    test "the strip names the step; a platform admin cancels; the row reads Canceled and " <>
           "offers Resume" do
      %{stamp: stamp, run: run} = started!()

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")
      components = ~s|#backup-in-flight [data-role="queued-components"]|
      assert has_element?(lv, components, "Database")
      refute has_element?(lv, components, "Media")

      {:ok, %{status: :folded}} = Backups.request([components: [:media]], Backups.system())

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")
      assert has_element?(lv, components, "Database + Media")
    end

    @tag :pg_tools
    test "Back up now while one runs queues it and says so" do
      started!()
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      html = lv |> element(~s|button[phx-click="backup_now"]|) |> render_click()

      assert html =~ "that queued backup covers this request"
      assert %{waiting: %{folds: 1}} = Backups.in_flight()
    end

    @tag :pg_tools
    test "Resume folds into a queued resume of the same backup and says so", %{dir: dir} do
      run = resumable_run!(dir, "20261101-101010")
      started!()
      {:ok, %{status: :queued}} = Backups.request([resume: run.stamp], Backups.system())
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               ~s|#backup-in-flight [data-role="step"]|,
               "Archiving media: part 2 of 3"
             )
    end

    @tag :pg_tools
    test "the off-site step names destination k of n, only when there are several (#2220)", %{
      dir: dir
    } do
      %{stamp: stamp} = started!()
      row = lock_row()
      {:ok, dir_id} = DirId.local(dir)

      Backups.move_backup_lock!(
        row,
        %{step: :offsite, part: 2, step_job_id: row.step_job_id, dir_id: dir_id},
        actor: Backups.system()
      )

      work = WorkState.path(dir, stamp)
      {:ok, state} = WorkState.read(work)
      env = %{"key" => "rclone:r2:kiln", "source" => "env", "label" => "r2:kiln"}
      bucket = %{"key" => "dest:b", "source" => "db", "label" => "Bucket <B>"}
      :ok = WorkState.write(work, Map.put(state, "destinations", [env, bucket]))

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               ~s|#backup-in-flight [data-role="step"]|,
               "Copying off-site (2 of 2: Bucket <B>)"
             )

      # One destination: the label it always had.
      :ok = WorkState.write(work, Map.put(state, "destinations", [env]))

      Backups.move_backup_lock!(
        lock_row(),
        %{step: :offsite, part: 1, step_job_id: row.step_job_id, dir_id: dir_id},
        actor: Backups.system()
      )

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      assert lv
             |> element(~s|#backup-in-flight [data-role="step"]|)
             |> render() =~ ~r/>\s*Copying off-site\s*</
    end

    @tag :pg_tools
    test "a backup that is finishing has no Cancel on the strip, and a forced cancel is refused" do
      %{run: run} = started!()
      Backups.mark_backup_lock_finishing!(lock_row(), %{}, actor: Backups.system())

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      refute has_element?(lv, ~s|#backup-in-flight [data-role="cancel"]|)

      assert render_hook(lv, "cancel_run", %{"id" => run.id}) =~
               "Too late to cancel: the backup is finishing."

      assert %{status: :running} = Backups.get_run!(run.id, actor: Backups.system())
    end

    @tag :pg_tools
    test "the History row drops Cancel once the backup is finishing (#2542)" do
      %{run: run} = started!()

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      assert render_hook(lv, "cancel_run", %{"id" => run.id}) =~ "That backup already finished."

      assert render_hook(lv, "cancel_run", %{"id" => Ecto.UUID.generate()}) =~
               "can&#39;t be canceled"

      render_hook(lv, "cancel_run", %{"id" => 7})

      assert %{status: :succeeded} = Backups.get_run!(run.id, actor: Backups.system())
    end

    @tag :pg_tools
    test "the handler re-checks platform admin: editor, org admin, viewer, expired grant and anonymous are sent away" do
      %{run: run} = started!()

      org_admin = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: org_admin.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      for user <- [
            authed_user(:editor),
            org_admin,
            authed_user(:viewer),
            expired_grant_user(),
            nil
          ] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

        assert_denied(KilnCMSWeb.BackupLive.handle_event("cancel_run", %{"id" => run.id}, socket))
      end

      assert %{status: :running} = Backups.get_run!(run.id, actor: Backups.system())
      assert Backups.in_flight() != nil
    end

    # A failed run with a resume of it holding the lock at its start, not
    # re-opened yet (#2816). Its files are recorded in another backup
    # directory, so with `snooze?: true` the start, run once, snoozes waiting
    # for the server that has them; else it hasn't run. `fields` change the
    # run first.
    defp waiting_resume!(dir, stamp, opts \\ []) do
      run =
        Backups.start_run!(
          %{
            stamp: stamp,
            trigger: "manual",
            chain_id: Ash.UUID.generate(),
            dir_id: Ash.UUID.generate()
          },
          actor: Backups.system()
        )

      run = Backups.fail_run!(run, %{error: "tar exited 2"}, actor: Backups.system())
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))

      case Keyword.get(opts, :fields, []) do
        [] -> :ok
        fields -> set_run!(stamp, fields)
      end

      {:ok, %{status: :started, chain: chain}} =
        Backups.request([resume: stamp], Backups.system())

      if Keyword.get(opts, :snooze?, true) do
        File.rename!(work, Path.join(dir, "aside-#{stamp}"))
        %{snoozed: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      end

      %{run: Backups.get_run!(run.id, actor: Backups.system()), chain: chain}
    end

    defp set_run!(stamp, fields) do
      {1, _} =
        KilnCMS.Repo.update_all(
          Ecto.Query.from(r in "backup_runs", where: r.stamp == ^stamp),
          set: fields
        )
    end

    @strip_cancel_resume ~s|#backup-in-flight button[data-role="cancel-resume"]|

    # #3030: beside each waiting-resume label, a link to the guide's section.
    @strip_why ~s|#backup-in-flight a[data-role="resume-why"]| <>
                 ~s|[href$="backups.md#cancel-a-resume-that-is-waiting-to-start"]| <>
                 ~s|[target="_blank"]|

    @tag :pg_tools
    test "a resume waiting for the server with its files says so; its Cancel frees the lock, " <>
           "and the row keeps its status (#2816)",
         %{dir: dir} do
      %{run: run} = waiting_resume!(dir, "20261103-101010")
      {:ok, %{status: :queued}} = Backups.request([trigger: "schedule"], Backups.system())

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               ~s|#backup-in-flight [data-role="step"]|,
               "Waiting for the server that has this backup"
             )

      assert has_element?(lv, @strip_why, "Why?")

      assert has_element?(
               lv,
               @strip_cancel_resume <>
                 ~s|[data-confirm*="Cancel this resume? The backup stays as it was"]| <>
                 ~s|[data-confirm*="A queued backup will start next"]|
             )

      refute has_element?(lv, ~s|#backup-in-flight [data-role="cancel"]|)
      row = "#backup-run-#{run.id}"
      refute has_element?(lv, ~s|#{row} [data-role="cancel"]|)

      html = lv |> element(@strip_cancel_resume) |> render_click()

      assert html =~ "Resume canceled. The backup stays as it was, so it can be resumed later."
      assert %{trigger: "schedule", resume: nil} = Backups.in_flight()
      assert has_element?(lv, ~s|#backup-in-flight [data-role="step"]|, "Starting a backup")
      refute has_element?(lv, @strip_cancel_resume)
      refute has_element?(lv, @strip_why)
      assert has_element?(lv, ~s|#{row} [data-role="status"]|, "Failed")

      assert %{error: "Resume canceled by a platform admin before it started\ntar exited 2"} =
               Backups.get_run!(run.id, actor: Backups.system())
    end

    @tag :pg_tools
    test "the strip says what a waiting resume waits for (#2816)", %{dir: dir} do
      %{run: run, chain: chain} = waiting_resume!(dir, "20261103-111111", snooze?: false)

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      # Its start hasn't run yet.
      assert has_element?(lv, ~s|#backup-in-flight [data-role="step"]|, "Starting a resume")
      assert has_element?(lv, @strip_why, "Why?")

      assert has_element?(
               lv,
               @strip_cancel_resume <>
                 ~s|[data-confirm="Cancel this resume? The backup stays as it was, so it can be resumed later."]|
             )

      # Its start runs, inside the settle window of the run's Cancel.
      set_run!(run.stamp, status: "canceled", finished_at: DateTime.utc_now())

      {1, _} =
        KilnCMS.Repo.update_all(
          Ecto.Query.from(j in Oban.Job, where: j.id == ^lock_row().step_job_id),
          set: [state: "executing"]
        )

      send(lv.pid, :refresh)

      assert has_element?(
               lv,
               ~s|#backup-in-flight [data-role="step"]|,
               "Waiting for the canceled backup"
             )

      assert has_element?(lv, @strip_why, "Why?")
      assert has_element?(lv, @strip_cancel_resume)
      assert %{chain: ^chain} = Backups.in_flight()
    end

    # Critic change 1: a stale `running` run that a resume is about to re-open
    # gets only the resume's Cancel; the plain one would leave the resume
    # holding the lock.
    @tag :pg_tools
    test "a stale running run being resumed offers only the resume's Cancel (#2816)", %{
      dir: dir
    } do
      quiet = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)

      %{run: run} =
        waiting_resume!(dir, "20261103-121212",
          fields: [
            status: "running",
            finished_at: nil,
            error: nil,
            started_at: quiet,
            updated_at: quiet
          ]
        )

      assert run.status == :running

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, ~s|#{row} [data-role="status"]|, "Running")
      refute has_element?(lv, ~s|#{row} [data-role="cancel"]|)
      refute has_element?(lv, ~s|#backup-in-flight [data-role="cancel"]|)

      html = lv |> element(@strip_cancel_resume) |> render_click()

      assert html =~ "Resume canceled."
      assert Backups.in_flight() == nil
      assert %{status: :failed} = Backups.get_run!(run.id, actor: Backups.system())
      assert has_element?(lv, ~s|#{row} [data-role="status"]|, "Failed")
    end

    # #3028: a page loaded before the resume took the lock still sends the
    # plain Cancel; it is refused, and the resume keeps the lock.
    @tag :pg_tools
    test "the plain Cancel of a stale running run whose resume waits is refused and says so",
         %{dir: dir} do
      quiet = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)

      %{run: run, chain: chain} =
        waiting_resume!(dir, "20261103-121213",
          fields: [
            status: "running",
            finished_at: nil,
            error: nil,
            started_at: quiet,
            updated_at: quiet
          ]
        )

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      html = render_hook(lv, "cancel_run", %{"id" => run.id})

      assert html =~ "A resume of this backup is waiting to start. Cancel the resume instead."
      assert %{chain: ^chain, step: :start} = Backups.in_flight()
      assert %{status: :running} = Backups.get_run!(run.id, actor: Backups.system())
      assert has_element?(lv, @strip_cancel_resume)
    end

    @tag :pg_tools
    test "a resume that started meanwhile: the click says so, and the plain Cancel is offered",
         %{dir: dir} do
      %{run: run, chain: chain} = waiting_resume!(dir, "20261103-131313")
      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")
      assert has_element?(lv, @strip_cancel_resume)

      # The start re-opens the run before the click lands.
      Backups.resume_run!(Backups.get_run!(run.id, actor: Backups.system()), %{chain_id: chain},
        actor: Backups.system()
      )

      html = lv |> element(@strip_cancel_resume) |> render_click()

      assert html =~ "The resume started meanwhile. Cancel it again to stop the backup."
      assert %{chain: ^chain} = Backups.in_flight()
      assert %{status: :running} = Backups.get_run!(run.id, actor: Backups.system())
      refute has_element?(lv, @strip_cancel_resume)
      assert has_element?(lv, ~s|#backup-in-flight button[data-role="cancel"]|)
    end

    # A stale record that isn't the resume starting: the run is `running`
    # but not stale, under its own chain, so the Cancel's pinned UPDATE
    # matches nothing while the lock still holds the waiting resume.
    @tag :pg_tools
    test "a Cancel that finds the backup changed otherwise says so, neutrally (#2816)",
         %{dir: dir} do
      %{run: run, chain: chain} = waiting_resume!(dir, "20261103-131314")
      set_run!(run.stamp, status: "running", finished_at: nil)

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")

      html = render_hook(lv, "cancel_resume", %{"id" => run.id})

      assert html =~ "The backup changed meanwhile. Try again."
      refute html =~ "The resume started meanwhile"
      assert %{chain: ^chain, step: :start} = Backups.in_flight()
      assert %{status: :running} = Backups.get_run!(run.id, actor: Backups.system())
    end

    # The race a LiveView test can't time: the Cancel read the run, then the
    # start re-opened it before the Cancel's UPDATE (a stale record). The run
    # and the lock as they are now decide the message.
    @tag :pg_tools
    test "a stale-record Cancel says the resume started only when it did (#2816)", %{dir: dir} do
      admin = authed_user(:admin)
      stale = %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}

      %{run: run, chain: chain} = waiting_resume!(dir, "20261103-131315")

      assert KilnCMSWeb.BackupLive.cancel_resume_message(stale, run.id, admin) ==
               "The backup changed meanwhile. Try again."

      Backups.resume_run!(run, %{chain_id: chain}, actor: Backups.system())

      assert KilnCMSWeb.BackupLive.cancel_resume_message(stale, run.id, admin) ==
               "The resume started meanwhile. Cancel it again to stop the backup."
    end

    @tag :pg_tools
    test "a forged resume cancel of a running or finished backup is refused", %{dir: dir} do
      done = app_run!(dir, 2, :succeeded)
      %{run: running} = started!()

      {:ok, lv, _html} = build_conn() |> admin_conn() |> live_ready(~p"/editor/backups")
      refute has_element?(lv, @strip_cancel_resume)

      for id <- [done.id, running.id, Ecto.UUID.generate()] do
        assert render_hook(lv, "cancel_resume", %{"id" => id}) =~
                 "That resume can&#39;t be canceled."
      end

      render_hook(lv, "cancel_resume", %{"id" => 7})

      assert %{status: :succeeded} = Backups.get_run!(done.id, actor: Backups.system())
      assert %{status: :running} = Backups.get_run!(running.id, actor: Backups.system())
      assert %{step: :dump} = Backups.in_flight()
    end

    @tag :pg_tools
    test "the resume cancel handler re-checks platform admin (#2816)", %{dir: dir} do
      %{run: run, chain: chain} = waiting_resume!(dir, "20261103-141414")

      org_admin = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: org_admin.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      for user <- [
            authed_user(:editor),
            org_admin,
            authed_user(:viewer),
            expired_grant_user(),
            nil
          ] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

        assert_denied(
          KilnCMSWeb.BackupLive.handle_event("cancel_resume", %{"id" => run.id}, socket)
        )
      end

      assert Backups.get_run!(run.id, actor: Backups.system()) == run
      assert %{chain: ^chain, step: :start} = Backups.in_flight()
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

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

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

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

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

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

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
      # #3005: a component never backed up keeps the line about the schedule.
      assert has_element?(lv, "#overview-backup-warning [data-role=backup-schedule]")
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

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")

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

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live_ready(~p"/editor/backups")
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

      # #3005: a backup that didn't happen keeps the line about the schedule.
      assert has_element?(
               lv,
               "#overview-backup-warning [data-role=backup-schedule]",
               "ask whoever runs this server to check it"
             )
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
      assert has_element?(lv, "#overview-backup-warning [data-role=backup-schedule]")
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
      {:ok, lv, _html} = live_ready(conn, ~p"/editor/backups")
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
            "media-backups-in-parts-2218",
            "the-app-path-and-the-shell-path-share-one-format",
            "backup-history-2217"
          ] do
        assert fragment in slugs, "docs/backups.md has no heading whose anchor is ##{fragment}"
      end
    end

    # Shown whatever the off-site row says: the built-in copy already ships
    # the .sha256 files, so the hint is for operators who copy backups
    # themselves (#2890).
    test "Where backups go says to copy the .sha256 files, with or without an off-site copy",
         %{conn: conn, dir: dir} do
      lv = mount_admin(conn)
      assert has_element?(lv, "#offsite-sidecars-help", "in parts won't restore")

      assert has_element?(
               lv,
               ~s|#offsite-sidecars-help a[href$="/docs/backups.md#the-app-path-and-the-shell-path-share-one-format"]|
             )

      seed_manifest!(dir, offsite: "r2:kiln-backups")
      lv = mount_admin(conn)
      assert render(lv) =~ "r2:kiln-backups"
      assert has_element?(lv, "#offsite-sidecars-help", "in parts won't restore")
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

    test "a schedule's hold markers badge each held component of their rows (#2933)", %{
      conn: conn,
      dir: dir
    } do
      both = seed_run!(dir, 1, stamp: "20260101-010000")
      db_only = seed_run!(dir, 2, stamp: "20260102-020000")
      plain = seed_run!(dir, 3, stamp: "20260103-030000")

      touch_marker!(dir, "db", "kiln-20260101-010000.hold")
      touch_marker!(dir, "media", "kiln-20260101-010000.hold")
      touch_marker!(dir, "db", "kiln-20260102-020000.hold")

      lv = mount_admin(conn)

      assert has_element?(
               lv,
               ~s|#backup-run-#{both.id} [data-role="held"][data-component="db"]|,
               "Kept by a schedule: Database"
             )

      assert has_element?(
               lv,
               ~s|#backup-run-#{both.id} [data-role="held"][data-component="media"]|,
               "Kept by a schedule: Media"
             )

      assert has_element?(
               lv,
               ~s|#backup-run-#{both.id} [data-role="held"][title*="kiln-<stamp>.hold"]|
             )

      assert has_element?(
               lv,
               ~s|#backup-run-#{db_only.id} [data-role="held"][data-component="db"]|,
               "Kept by a schedule: Database"
             )

      refute has_element?(
               lv,
               ~s|#backup-run-#{db_only.id} [data-role="held"][data-component="media"]|
             )

      # A hold is not a last-good marker or a recovery point.
      refute has_element?(lv, ~s|#backup-run-#{both.id} [data-role="last-good"]|)
      refute has_element?(lv, ~s|#backup-run-#{both.id} [data-role="recovery-point"]|)

      refute has_element?(lv, ~s|#backup-run-#{plain.id} [data-role="held"]|)
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

      # Unreadable is said, not passed off as "none yet" (#2799); media's
      # line still reads its marker.
      assert has_element?(
               lv,
               ~s|#backup-last-good [data-role="last-good"][data-component="db"][data-state="unreadable"]|,
               "couldn't read this server's backup directory"
             )

      refute has_element?(lv, ~s|#backup-last-good [data-component="db"]|, "none yet")

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="presence"][data-presence="unknown"]|,
               "couldn't check"
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
      touch_marker!(dir, "db", "kiln-20250101-010000.hold")
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, _}} = live(conn, ~p"/editor/backups")
    end
  end

  describe "what is on disk, read off the LiveView process (#2416, #2417, #2799)" do
    alias KilnCMSWeb.BackupLiveTest.StallingDiskView

    # Points the page at `StallingDiskView` (VM-global env: the module is
    # `async: false`).
    defp stall_disk!(opts \\ []) do
      Application.put_env(:kiln_cms, StallingDiskView, self())
      Application.put_env(:kiln_cms, KilnCMSWeb.BackupLive, [disk_view: StallingDiskView] ++ opts)

      on_exit(fn ->
        Application.delete_env(:kiln_cms, StallingDiskView)
        Application.delete_env(:kiln_cms, KilnCMSWeb.BackupLive)
      end)
    end

    # Lets a stalled read answer, and waits until it has (its result is then
    # in the page's mailbox ahead of the next render).
    defp release(pid) do
      ref = Process.monitor(pid)
      send(pid, :go)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    defp media_run!(dir, stamp, names, parts, destinations) do
      File.mkdir_p!(Path.join(dir, "media"))
      for name <- names, do: File.write!(Path.join([dir, "media", name]), "x")

      Backups.import_run!(
        %{
          stamp: stamp,
          trigger: "manual",
          status: :succeeded,
          components: [:db, :media],
          started_at: ~U[2026-01-05 03:00:00.000000Z],
          finished_at: ~U[2026-01-05 03:05:00.000000Z],
          artifacts: [
            %{
              kind: :db,
              name: "kiln-db-#{stamp}.dump",
              bytes: 10,
              verified: true,
              destinations: %{"local" => %{"status" => "ok"}}
            },
            %{
              kind: :media,
              name: "kiln-media-#{stamp}",
              bytes: 10,
              verified: true,
              parts: Enum.map(parts, &%{"name" => &1, "bytes" => 1, "sha256" => nil}),
              destinations: destinations
            }
          ]
        },
        actor: Backups.system()
      )
    end

    test "a run whose artifacts differ says each one's state", %{conn: conn, dir: dir} do
      stamp = "20260105-030000"
      write_artifact!(dir, "kiln-db-#{stamp}.dump")
      [single] = Backups.Artifact.set_names(stamp, 1)
      run = media_run!(dir, stamp, [], [single], %{"local" => %{"status" => "pruned"}})

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="mixed"]|)

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="artifact-presence"][data-kind="db"][data-presence="present"]|,
               "Database: on disk"
             )

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="artifact-presence"][data-kind="media"][data-presence="pruned"]|,
               "Media: pruned (retention)"
             )

      refute has_element?(lv, "#presence-help-#{run.id}")
    end

    test "a media set with a part gone names the part and explains it", %{conn: conn, dir: dir} do
      stamp = "20260105-030000"
      write_artifact!(dir, "kiln-db-#{stamp}.dump")
      names = Backups.Artifact.set_names(stamp, 3)
      on_disk = List.delete_at(names, 1)
      run = media_run!(dir, stamp, on_disk, names, %{"local" => %{"status" => "ok"}})

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="parts-missing"][data-kind="media"]|,
               "1 part missing: 02"
             )

      assert has_element?(lv, "#presence-help-#{run.id}", "nothing recorded why")
    end

    # #2942: the gone parts with an off-site copy say so; the others don't.
    test "a media set split between this disk and off-site says which parts are off-site",
         %{conn: conn, dir: dir} do
      stamp = "20260105-030000"
      write_artifact!(dir, "kiln-db-#{stamp}.dump")
      names = Backups.Artifact.set_names(stamp, 4)
      ok = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}
      failed = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "failed"}}
      run = media_run!(dir, stamp, [hd(names)], names, ok)

      # Part 04's own copy failed: it is gone with no copy anywhere.
      run =
        Ash.Seed.update!(run, %{
          artifacts:
            Enum.map(run.artifacts, fn
              %{kind: :media, parts: parts} = media ->
                %{media | parts: List.update_at(parts, 3, &Map.put(&1, "destinations", failed))}

              db ->
                db
            end)
        })

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, ~s|#{row} [data-presence="mixed"]|)

      assert has_element?(
               lv,
               ~s|#{row} [data-role="parts-off-site"][data-kind="media"]|,
               "2 parts missing here, copied off-site: 02, 03"
             )

      assert has_element?(
               lv,
               ~s|#{row} [data-role="parts-missing"][data-kind="media"]|,
               "1 part missing: 04"
             )

      refute has_element?(lv, ~s|#{row} [data-role="parts-missing"]|, "02")
    end

    test "every gone part copied off-site: no plain missing-parts chip", %{conn: conn, dir: dir} do
      stamp = "20260105-030000"
      write_artifact!(dir, "kiln-db-#{stamp}.dump")
      names = Backups.Artifact.set_names(stamp, 3)
      ok = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}
      run = media_run!(dir, stamp, Enum.take(names, 2), names, ok)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      row = "#backup-run-#{run.id}"

      assert has_element?(
               lv,
               ~s|#{row} [data-role="parts-off-site"]|,
               "1 part missing here, copied off-site: 03"
             )

      refute has_element?(lv, ~s|#{row} [data-role="parts-missing"]|)
    end

    # #2940: "couldn't check" has a tip, whichever of its three causes.
    test "a row that couldn't be checked explains why", %{conn: conn, dir: dir} do
      run = seed_run!(dir, 1, stamp: "20260101-010000", file?: false)
      # A file where the directory should be: unlistable for every user.
      File.rm_rf!(Path.join(dir, "db"))
      File.write!(Path.join(dir, "db"), "")

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="unknown"]|)

      assert has_element?(
               lv,
               "#presence-help-#{run.id}",
               "couldn't read this server's backup directory, or one of these files in it"
             )

      assert has_element?(lv, "#presence-help-#{run.id}-title", "couldn't check")

      assert has_element?(
               lv,
               ~s|#presence-help-#{run.id} a[href$="backups.md#backup-history-2217"]|
             )
    end

    test "a disk read that crashed explains couldn't check on every row", %{
      conn: conn,
      dir: dir
    } do
      # VM-global env: the module is `async: false`.
      Application.put_env(:kiln_cms, KilnCMSWeb.BackupLive,
        disk_view: KilnCMSWeb.BackupLiveTest.CrashingDiskView
      )

      on_exit(fn -> Application.delete_env(:kiln_cms, KilnCMSWeb.BackupLive) end)
      run = seed_run!(dir, 1)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, "#backup-disk-failed")
      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="unknown"]|)
      assert has_element?(lv, "#presence-help-#{run.id}", "failed outright")
    end

    test "a row that couldn't be checked in time explains why", %{conn: conn, dir: dir} do
      stall_disk!(disk_timeout_ms: 0)
      run = seed_run!(dir, 1)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      assert_receive {:disk_read, pid, _ids}

      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="timeout"]|)
      assert has_element?(lv, "#presence-help-#{run.id}-title", "couldn't check in time")

      assert has_element?(
               lv,
               "#presence-help-#{run.id}",
               "didn't answer within 1 second (a slow or hung mount)"
             )

      assert has_element?(
               lv,
               ~s|#presence-help-#{run.id} a[href$="backups.md#what-history-reads-from-disk"]|
             )

      # A refresh while the read is out waits for it, then reads once more;
      # the answer fills the row in, and the tip goes with the chip.
      send(lv.pid, :refresh)
      release(pid)
      render(lv)
      assert_receive {:disk_read, second, _ids}
      release(second)

      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="present"]|)
      refute has_element?(lv, "#presence-help-#{run.id}")
    end

    test "an app-made run has no imported-backup tip", %{conn: conn, dir: dir} do
      name = "kiln-db-20260101-010000.dump"
      write_artifact!(dir, name)

      run =
        Ash.Seed.seed!(KilnCMS.Backups.Run, %{
          stamp: "20260101-010000",
          status: :succeeded,
          artifacts: [%KilnCMS.Backups.Artifact{kind: :db, name: name, bytes: 1}]
        })

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, "#backup-run-#{run.id}", "Not verified")
      refute has_element?(lv, "#imported-help-#{run.id}")
    end

    test "the empty history says cron's backups show up here too", %{conn: conn} do
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, "#backup-history-empty", "No backups have been recorded yet.")
      assert has_element?(lv, "#backup-history-empty", "cron's scripts/backup.sh")
    end

    test "the first render doesn't read the disk or the manifest; it says it is reading",
         %{conn: conn} do
      html = conn |> admin_conn() |> get(~p"/editor/backups") |> html_response(200)

      assert html =~ "Reading this server&#39;s backup status"
      assert html =~ ~s(data-busy="true")
    end

    test "until the disk read answers, rows and markers say checking; then what is there",
         %{conn: conn, dir: dir} do
      stall_disk!()
      run = seed_run!(dir, 1)
      touch_marker!(dir, "db", "kiln-#{run.stamp}.hold")

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      assert_receive {:disk_read, pid, [id]}
      assert id == run.id

      # The page answers while the read is out: it is not blocked on it.
      assert has_element?(lv, "#backup-disk-checking")
      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="checking"]|, "checking…")

      assert has_element?(
               lv,
               ~s|#backup-last-good [data-component="db"][data-state="checking"]|
             )

      # Markers come with the read: no hold badge until it answers.
      refute has_element?(lv, ~s|#backup-run-#{run.id} [data-role="held"]|)

      release(pid)

      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="present"]|, "on disk")
      refute has_element?(lv, "#backup-disk-checking")

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="held"][data-component="db"]|
             )
    end

    test "one read at a time: refreshes while it is out start one more, not one each",
         %{conn: conn, dir: dir} do
      stall_disk!()
      seed_run!(dir, 1)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      assert_receive {:disk_read, first, _ids}

      for _ <- 1..3, do: send(lv.pid, :refresh)
      render(lv)
      refute_received {:disk_read, _pid, _ids}

      # The refreshes (and the import landing) were owed one read, and get one.
      release(first)
      render(lv)
      assert_receive {:disk_read, second, _ids}
      release(second)
      render(lv)
      refute_received {:disk_read, _pid, _ids}
    end

    test "a status read that doesn't answer in time: the page says so, starts no other, " <>
           "and shows the status when it comes",
         %{conn: conn} do
      test = self()

      reader = fn ->
        send(test, {:status_read, self()})

        receive do
          :go -> Backups.status()
        end
      end

      Application.put_env(:kiln_cms, KilnCMSWeb.BackupLive,
        disk_timeout_ms: 0,
        status_reader: reader
      )

      on_exit(fn -> Application.delete_env(:kiln_cms, KilnCMSWeb.BackupLive) end)

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      assert_receive {:status_read, first}

      assert has_element?(
               lv,
               "#backup-status-pending",
               "Couldn't read this server's backup status"
             )

      for _ <- 1..3, do: send(lv.pid, :refresh)
      render(lv)
      refute_received {:status_read, _pid}

      release(first)
      render(lv)
      refute has_element?(lv, "#backup-status-pending")
    end

    test "a read that doesn't answer in time: the page says so, starts no other, and " <>
           "takes the answer when it comes",
         %{conn: conn, dir: dir} do
      stall_disk!(disk_timeout_ms: 0)
      run = seed_run!(dir, 1)
      touch_marker!(dir, "db", "kiln-20260101-010000.good")

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      assert_receive {:disk_read, first, _ids}

      assert has_element?(lv, "#backup-disk-timeout", "didn't answer within 1 second")
      refute has_element?(lv, "#backup-disk-checking")

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-presence="timeout"]|,
               "couldn't check in time"
             )

      assert has_element?(
               lv,
               ~s|#backup-last-good [data-component="db"][data-state="timeout"]|,
               "couldn't check in time"
             )

      for _ <- 1..3, do: send(lv.pid, :refresh)
      render(lv)
      refute_received {:disk_read, _pid, _ids}

      release(first)
      render(lv)
      assert_receive {:disk_read, second, _ids}
      release(second)

      refute has_element?(lv, "#backup-disk-timeout")
      assert has_element?(lv, ~s|#backup-run-#{run.id} [data-presence="present"]|, "on disk")

      assert has_element?(
               lv,
               ~s|#backup-last-good [data-component="db"][data-state="marked"]|,
               "20260101-010000"
             )
    end

    test "a read started for one page fills nothing on another", %{conn: conn, dir: dir} do
      stall_disk!()

      runs =
        for n <- 1..27 do
          seed_run!(dir, n,
            stamp: "20260101-00#{String.pad_leading(Integer.to_string(n), 2, "0")}00",
            started_at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n * 3600, :second)
          )
        end

      # Newest first: page 2 holds the two oldest.
      page_two = runs |> Enum.take(2) |> Enum.map(& &1.id) |> Enum.sort()

      {:ok, lv, _html} = conn |> admin_conn() |> live(~p"/editor/backups")
      assert_receive {:disk_read, first, first_ids}
      assert length(first_ids) == 25

      lv
      |> element(~s|#backup-history button[phx-click="page"]:not([disabled])|)
      |> render_click()

      assert_patch(lv, ~p"/editor/backups?page=2")
      release(first)

      for id <- page_two do
        assert has_element?(lv, ~s|#backup-run-#{id} [data-presence="checking"]|)
      end

      assert_receive {:disk_read, second, second_ids}
      assert Enum.sort(second_ids) == page_two
      release(second)

      for id <- page_two do
        assert has_element?(lv, ~s|#backup-run-#{id} [data-presence="present"]|)
      end
    end

    test "every background result re-checks platform admin before it is applied" do
      view = KilnCMS.Backups.DiskView.read(System.tmp_dir!(), [])

      for user <- [%{role: :editor}, expired_grant_user()] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

        assert_denied(KilnCMSWeb.BackupLive.handle_async(:disk, {:ok, view}, socket))
        assert_denied(KilnCMSWeb.BackupLive.handle_async(:disk, {:exit, :boom}, socket))
        assert_denied(KilnCMSWeb.BackupLive.handle_async(:status, {:ok, %{}}, socket))
        assert_denied(KilnCMSWeb.BackupLive.handle_async(:status, {:exit, :boom}, socket))
        assert_denied(KilnCMSWeb.BackupLive.handle_info({:disk_timeout, make_ref()}, socket))
        assert_denied(KilnCMSWeb.BackupLive.handle_info({:status_timeout, make_ref()}, socket))
      end
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
      {:ok, lv, _html} = conn |> log_in(admin) |> live_ready(~p"/editor/backups")
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

      refute has_element?(lv, "#backup-schedules-invalid")

      refute has_element?(lv, "#backup-next-scheduled")
    end

    # #2935: an unparseable value (31 February is one on Oban 2.24) is not
    # "turned off".
    test "with a scheduler cron that isn't valid, it says so, not that it is off", %{conn: conn} do
      admin = authed_user(:admin)
      force!(schedule!(%{}, admin), baseline_at: @baseline)
      put_cron("0 0 31 2 *")

      lv = mount_backups(conn, admin)

      assert has_element?(
               lv,
               "#backup-schedules-invalid",
               "In-app schedules don't run: KILN_BACKUP_SCHEDULER_CRON isn't a valid cron expression."
             )

      refute has_element?(lv, "#backup-schedules-off")
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

  # #2220: History names each destination the run recorded, says when a
  # backup reached only some of them, and the alarm says so on both panels.
  describe "off-site destinations (#2220)" do
    @env_key "rclone:offsite:kiln"
    @nas_id "6c1f6a52-6a44-4d3e-9b39-0b1f8c1a7e11"
    @bucket_id "0b6d9f0e-2f43-4c1a-8f5e-3f6b6e0d9a22"
    @nas "dest:" <> @nas_id
    @bucket "dest:" <> @bucket_id
    @gone "dest:9a1e2c3d-4b5f-4a6b-8c7d-0e1f2a3b4c5d"

    # An in-app run finished `hours` ago: its artifact's per-destination
    # results, and the Run-level entries with its `offsite_status`.
    defp offsite_run!(artifact_destinations, run_destinations, offsite_status, hours \\ 1) do
      at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
      stamp = Backups.Artifact.stamp(at)

      run =
        Backups.start_run!(
          %{stamp: stamp, trigger: "manual", components: [:db], started_at: at},
          actor: Backups.system()
        )

      Backups.finish_run!(
        run,
        %{
          artifacts: [
            %{
              kind: :db,
              name: "kiln-db-#{stamp}.dump",
              bytes: 2048,
              verified: true,
              destinations: artifact_destinations
            }
          ],
          destinations: run_destinations,
          offsite_status: offsite_status
        },
        actor: Backups.system()
      )
    end

    # The destinations `partial_run!/0` names, configured now (#2951: a
    # failed destination that is no longer configured raises no alarm):
    # `BACKUP_RCLONE_REMOTE` and the stored NAS and Bucket.
    defp configure_destinations! do
      Application.put_env(
        :kiln_cms,
        Backups,
        Keyword.put(Application.get_env(:kiln_cms, Backups), :rclone_remote, "offsite:kiln")
      )

      for {id, name, position} <- [{@nas_id, "NAS", 1}, {@bucket_id, "Bucket", 2}], into: %{} do
        row =
          Ash.Seed.seed!(Backups.DestinationConfig, %{
            id: id,
            name: name,
            kind: "local",
            settings: %{},
            enabled: true,
            position: position
          })

        {name, row}
      end
    end

    defp unset_remote! do
      Application.put_env(
        :kiln_cms,
        Backups,
        Keyword.put(Application.get_env(:kiln_cms, Backups), :rclone_remote, nil)
      )
    end

    defp remove_destination!(row), do: Ash.Seed.update!(row, %{enabled: false})

    defp partial_run! do
      configure_destinations!()

      offsite_run!(
        %{
          "local" => %{"status" => "ok"},
          @env_key => %{"status" => "ok"},
          @nas => %{"status" => "ok"},
          @bucket => %{"status" => "failed"}
        },
        [
          %{key: @env_key, kind: "rclone", label: "offsite:kiln", status: :ok},
          %{key: @nas, kind: "local", label: "NAS", status: :ok},
          %{
            key: @bucket,
            kind: "rclone",
            label: "Bucket",
            status: :failed,
            error: "rclone exited 1: bucket not found"
          }
        ],
        :partial
      )
    end

    test "History: a chip per destination by its recorded name, its status, and a partial badge",
         %{conn: conn} do
      run = partial_run!()

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, "#{row} [data-role=destination][data-status=ok]", "Local · ok")

      assert has_element?(
               lv,
               "#{row} [data-role=destination][data-status=ok]",
               "offsite:kiln · ok"
             )

      assert has_element?(lv, "#{row} [data-role=destination][data-status=ok]", "NAS · ok")

      assert has_element?(
               lv,
               ~s|#{row} [data-role=destination][data-status=failed][title="rclone exited 1: bucket not found"]|,
               "Bucket · failed"
             )

      assert has_element?(lv, "#{row} [data-role=offsite-partial]", "Partly off-site")
      refute has_element?(lv, "#{row} [data-role=offsite-unknown]")
      refute render(lv) =~ @nas
    end

    test "History: a destination the run has no record of is a removed one", %{conn: conn} do
      run =
        offsite_run!(
          %{"local" => %{"status" => "ok"}, @gone => %{"status" => "ok"}},
          [],
          nil
        )

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-run-#{run.id} [data-role=destination]",
               "Removed destination · ok"
             )

      refute render(lv) =~ @gone
    end

    test "History: a destination that failed before any file still gets its chip", %{conn: conn} do
      run =
        offsite_run!(
          %{"local" => %{"status" => "ok"}, @env_key => %{"status" => "ok"}},
          [
            %{key: @env_key, kind: "rclone", label: "offsite:kiln", status: :ok},
            %{key: @nas, kind: "fake", label: "NAS", status: :failed, error: "not installed"}
          ],
          :partial
        )

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role=destination][data-status=failed][title="not installed"]|,
               "NAS · failed"
             )
    end

    # #3084: the tooltip of a destination failed at once says no retry would
    # have helped; a failure that ran out of attempts doesn't.
    test "History: a destination failed by a permanent error says so in its tooltip", %{
      conn: conn
    } do
      run =
        offsite_run!(
          %{"local" => %{"status" => "ok"}, @nas => %{"status" => "failed"}},
          [
            %{
              key: @nas,
              kind: "s3",
              label: "NAS",
              status: :failed,
              error: "FAILED for 1: kiln-db.dump (access denied)",
              permanent: true
            },
            %{
              key: @bucket,
              kind: "rclone",
              label: "Bucket",
              status: :failed,
              error: "rclone exited 1: timeout"
            }
          ],
          :partial
        )

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      row = "#backup-run-#{run.id}"

      assert has_element?(
               lv,
               ~s|#{row} [data-role=destination][data-status=failed]| <>
                 ~s|[title^="FAILED for 1: kiln-db.dump (access denied)"]| <>
                 ~s|[title$="Failed at once: the destination said no retry fixes this."]|,
               "NAS · failed"
             )

      assert has_element?(
               lv,
               ~s|#{row} [data-role=destination][data-status=failed][title="rclone exited 1: timeout"]|,
               "Bucket · failed"
             )
    end

    test "History: a succeeded run with destinations and no outcome reads unknown", %{
      conn: conn
    } do
      run =
        offsite_run!(
          %{"local" => %{"status" => "ok"}, @env_key => %{"status" => "pending"}},
          [%{key: @env_key, kind: "rclone", label: "offsite:kiln", status: :pending}],
          nil,
          2
        )

      complete =
        offsite_run!(
          %{"local" => %{"status" => "ok"}, @env_key => %{"status" => "ok"}},
          [%{key: @env_key, kind: "rclone", label: "offsite:kiln", status: :ok}],
          :complete
        )

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-run-#{run.id} [data-role=offsite-unknown]",
               "Off-site unknown"
             )

      refute has_element?(lv, "#backup-run-#{run.id} [data-role=offsite-partial]")
      refute has_element?(lv, "#backup-run-#{complete.id} [data-role=offsite-unknown]")
      refute has_element?(lv, "#backup-run-#{complete.id} [data-role=offsite-partial]")
    end

    test "the headline says how many destinations the last backup reached, in the alarm tone",
         %{conn: conn} do
      partial_run!()

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-headline-offsite",
               "The last backup reached 2 of 3 off-site destinations — Bucket failed"
             )

      assert has_element?(lv, "section.border-error\\/30 #backup-headline-offsite")

      assert has_element?(
               lv,
               "#backup-offsite-destinations [data-role=offsite-destination][data-status=failed]",
               "rclone exited 1: bucket not found"
             )
    end

    test "a complete one is not an alarm, and says nothing of the kind", %{conn: conn} do
      offsite_run!(
        %{"local" => %{"status" => "ok"}, @env_key => %{"status" => "ok"}},
        [%{key: @env_key, kind: "rclone", label: "offsite:kiln", status: :ok}],
        :complete
      )

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      refute has_element?(lv, "#backup-headline-offsite")
      refute has_element?(lv, "section.border-error\\/30")
      assert has_element?(lv, "#backup-offsite-destinations", "offsite:kiln")
    end

    test "the overview strip shows a platform admin the partial line", %{conn: conn} do
      partial_run!()

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               "#overview-backup-warning [data-role=backup-headline]",
               "The last backup reached 2 of 3 off-site destinations — Bucket failed"
             )

      # #3005: the backup ran on time, so no line is about the schedule.
      refute has_element?(lv, "#overview-backup-warning [data-role=backup-schedule]")
      refute has_element?(lv, "#overview-backup-warning [data-role=backup-next]")
      refute has_element?(lv, "#overview-backup-warning", "the server's cron job")
    end

    test "and is hidden from an org admin who is not a platform admin", %{conn: conn} do
      partial_run!()
      user = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: user.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      {:ok, _lv, html} = conn |> log_in(user) |> live(~p"/editor/overview")

      refute html =~ "overview-backup-warning"
      refute html =~ "off-site destinations"
    end
  end

  # #2951: the off-site alarm says what can still be fixed, on both panels.
  # A failed destination removed since raises nothing; a backup that reached
  # no destination at all (the table unreadable, no env remote) says so.
  describe "off-site status edge cases (#2951)" do
    @not_copied "The last backup was not copied off-site: couldn't read the backup " <>
                  "destinations, and BACKUP_RCLONE_REMOTE was not set"

    defp unreadable_run!(stored) do
      offsite_run!(
        %{"local" => %{"status" => "ok"}},
        [
          %{
            key: Backups.RunDestination.unreadable_key(),
            label: "Stored destinations",
            status: :failed,
            error: "couldn't read the backup destinations; this backup was not sent to them"
          }
        ],
        stored
      )
    end

    defp overview(conn),
      do: conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview") |> elem(1)

    test "the failed destination still configured keeps the alarm on both panels", %{
      conn: conn
    } do
      partial_run!()

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "section.border-error\\/30 #backup-headline-offsite",
               "Bucket failed"
             )

      refute has_element?(lv, "#backup-offsite-unconfigured")

      assert has_element?(
               overview(build_conn()),
               "#overview-backup-warning [data-role=backup-headline]",
               "Bucket failed"
             )
    end

    test "the failed destination removed while the reached ones remain: no alarm", %{
      conn: conn
    } do
      run = partial_run!()
      remove_destination!(Backups.get_backup_destination!(@bucket_id, actor: Backups.system()))

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      refute has_element?(lv, "#backup-headline-offsite")
      refute has_element?(lv, "section.border-error\\/30")
      refute has_element?(lv, "#backup-offsite-unconfigured")
      # History still tells the run as it was.
      assert has_element?(lv, "#backup-run-#{run.id} [data-role=offsite-partial]")

      refute has_element?(overview(build_conn()), "#overview-backup-warning")
    end

    test "every destination removed: no alarm, and a neutral line says so", %{conn: conn} do
      partial_run!()

      for id <- [@nas_id, @bucket_id],
          do: remove_destination!(Backups.get_backup_destination!(id, actor: Backups.system()))

      unset_remote!()

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      refute has_element?(lv, "#backup-headline-offsite")
      refute has_element?(lv, "section.border-error\\/30")

      assert has_element?(
               lv,
               "#backup-offsite-unconfigured",
               "No off-site destination is configured now: new backups stay in BACKUP_DIR only."
             )

      refute has_element?(overview(build_conn()), "#overview-backup-warning")
    end

    test "unreadable with no env remote: succeeded, not off-site, in the alarm tone", %{
      conn: conn
    } do
      configure_destinations!()
      unset_remote!()
      run = unreadable_run!(:failed)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, "section.border-error\\/30 #backup-headline-offsite", @not_copied)
      refute render(lv) =~ "reached 0 of 1"

      row = "#backup-run-#{run.id}"
      assert has_element?(lv, "#{row} [data-role=offsite-failed]", "Not off-site")
      refute has_element?(lv, "#{row} [data-role=offsite-partial]")

      assert has_element?(
               overview(build_conn()),
               "#overview-backup-warning [data-role=backup-headline]",
               @not_copied
             )
    end

    test "a failed destination removed beside one still failing is counted, not named", %{
      conn: conn
    } do
      configure_destinations!()

      offsite_run!(
        %{"local" => %{"status" => "ok"}},
        [
          %{key: @env_key, kind: "rclone", label: "offsite:kiln", status: :ok},
          %{key: @nas, kind: "local", label: "NAS", status: :failed, error: "down"},
          %{key: @bucket, kind: "local", label: "Bucket", status: :failed, error: "gone"}
        ],
        :partial
      )

      remove_destination!(Backups.get_backup_destination!(@bucket_id, actor: Backups.system()))

      line =
        "The last backup reached 1 of 3 off-site destinations — NAS failed " <>
          "(1 more failed and was removed since)"

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, "section.border-error\\/30 #backup-headline-offsite", line)
      refute has_element?(lv, "#backup-headline-offsite", "Bucket")

      assert has_element?(
               overview(build_conn()),
               "#overview-backup-warning [data-role=backup-headline]",
               line
             )
    end

    # Fail closed: an empty `failed` drops the alarm only when every failed
    # destination was removed, not for a partial run that names none.
    test "a partial run with nothing failed and nothing removed keeps the alarm", %{conn: conn} do
      configure_destinations!()

      offsite_run!(
        %{"local" => %{"status" => "ok"}},
        [
          %{key: @env_key, kind: "rclone", label: "offsite:kiln", status: :ok},
          %{key: @nas, kind: "local", label: "NAS", status: :pending}
        ],
        :partial
      )

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "section.border-error\\/30 #backup-headline-offsite",
               "The last backup reached 1 of 2 off-site destinations"
             )

      assert has_element?(overview(build_conn()), "#overview-backup-warning")
    end

    test "offsite_headline/1 is nil only once every failed destination was removed" do
      base = %{state: :partial, succeeded?: true, ok: 1, total: 2}
      gone = [%{key: @nas, label: "NAS", error: "down"}]

      assert KilnCMSWeb.BackupComponents.offsite_headline(
               Map.merge(base, %{failed: [], gone: gone})
             ) == nil

      assert KilnCMSWeb.BackupComponents.offsite_headline(
               Map.merge(base, %{failed: [], gone: []})
             ) =~ "reached 1 of 2"

      assert KilnCMSWeb.BackupComponents.offsite_headline(
               Map.merge(base, %{state: :failed, failed: [], gone: gone})
             ) == nil
    end

    # Critic change 11: a release before #2951 stored this run as partial.
    # It reads as failed off-site without being rewritten.
    test "an old run stored partial with only the unreadable entry reads not off-site", %{
      conn: conn
    } do
      configure_destinations!()
      unset_remote!()
      run = unreadable_run!(:partial)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, "#backup-headline-offsite", @not_copied)
      refute render(lv) =~ "reached 0 of 1"
      assert has_element?(lv, "#backup-run-#{run.id} [data-role=offsite-failed]", "Not off-site")
      refute has_element?(lv, "#backup-run-#{run.id} [data-role=offsite-partial]")

      overview = overview(build_conn())
      assert has_element?(overview, "#overview-backup-warning", @not_copied)
      refute render(overview) =~ "reached 0 of 1"
    end
  end

  # #2487: retention that was skipped or stopped is a dated alarm line on the
  # Backups page and on Home, until a clean pass clears it.
  describe "retention notices (#2487)" do
    alias KilnCMS.Backups.DestinationConfig

    @stamp "20261116-020000"

    # A good database backup an hour ago, so the only alarm is the notice's.
    defp good_backup! do
      offsite_run!(%{"local" => %{"status" => "ok"}}, [], nil)
    end

    defp notice!(attrs) do
      Backups.report_backup_notice!(
        Map.merge(
          %{
            kind: :retention,
            scope: "local",
            outcome: :skipped,
            reason: "couldn't read the backup history",
            stamp: @stamp,
            at: DateTime.utc_now()
          },
          attrs
        ),
        actor: Backups.system()
      )
    end

    test "a skip is a dated line in the alarm tone, with the guide", %{conn: conn} do
      good_backup!()
      notice!(%{})

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-headline-retention-local[data-role=retention-notice]",
               "Retention was skipped on the backup of 2026-11-16 02:00 UTC: " <>
                 "couldn't read the backup history. Nothing was deleted, so local backups " <>
                 "will build up until this is fixed."
             )

      assert has_element?(
               lv,
               ~s|#backup-retention-docs[href$="backups.md#when-retention-is-skipped-or-stops"]|
             )

      assert has_element?(lv, "section.border-error\\/30")
      assert has_element?(lv, "#backup-headline-db", "Backed up")
    end

    test "a stop says what it hadn't reached stays", %{conn: conn} do
      good_backup!()
      notice!(%{outcome: :stopped, deleted: 2, reason: "it crashed (RuntimeError)"})

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-headline-retention-local",
               "Retention stopped part-way on the backup of 2026-11-16 02:00 UTC: it crashed " <>
                 "(RuntimeError). What it hadn't reached stays until this is fixed."
             )
    end

    test "two backup directories: one line each, own ids, each naming its directory",
         %{conn: conn} do
      good_backup!()
      a = Ash.UUID.generate()
      b = Ash.UUID.generate()

      # Both directories are reported by a live node, so both lines show.
      for id <- [a, b] do
        Backups.beat_node!(
          %{
            node: "node-#{System.unique_integer([:positive])}",
            boot_id: Ash.UUID.generate(),
            dir_id: id
          },
          actor: Backups.system()
        )

        notice!(%{scope: "local:" <> id, dir_id: id})
      end

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      for id <- [a, b] do
        assert has_element?(
                 lv,
                 "#backup-headline-retention-local-#{id}",
                 "(backup directory #{String.slice(id, 0, 8)})"
               )
      end

      html = render(lv)
      assert length(Regex.scan(~r/data-role="retention-notice"/, html)) == 2
      assert length(Regex.scan(~r/id="backup-headline-retention-local/, html)) == 2

      refute has_element?(lv, "#backup-headline-retention-local")
    end

    test "a destination's line names it; one no longer pruned shows nothing", %{conn: conn} do
      good_backup!()

      pruned =
        Ash.Seed.seed!(DestinationConfig, %{
          name: "Offsite NAS",
          kind: "local",
          settings: %{},
          enabled: true,
          prune: true
        })

      off =
        Ash.Seed.seed!(DestinationConfig, %{
          name: "Archive",
          kind: "local",
          settings: %{},
          enabled: true,
          prune: false
        })

      notice!(%{
        scope: DestinationConfig.key(pruned),
        label: "NAS",
        reason: "it overlaps BACKUP_RCLONE_REMOTE"
      })

      notice!(%{scope: DestinationConfig.key(off), label: "Archive"})

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-headline-retention-dest-#{pruned.id}",
               "Retention on Offsite NAS was skipped on the backup of 2026-11-16 02:00 UTC: " <>
                 "it overlaps BACKUP_RCLONE_REMOTE. Nothing was deleted there"
             )

      refute has_element?(lv, "#backup-headline-retention-dest-#{off.id}")
      refute has_element?(lv, "#backup-headline-retention-local")
    end

    test "a clean run: no line, no alarm", %{conn: conn} do
      good_backup!()

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      refute has_element?(lv, "[data-role=retention-notice]")
      refute has_element?(lv, "#backup-retention-docs")
      refute has_element?(lv, "section.border-error\\/30")
    end

    test "Home's alarm strip shows a platform admin the line", %{conn: conn} do
      good_backup!()
      notice!(%{})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(
               lv,
               "#overview-backup-warning [data-role=backup-headline]",
               "Retention was skipped on the backup of 2026-11-16 02:00 UTC"
             )

      # #3005: nothing is overdue, so no line sends them to the schedule.
      refute has_element?(lv, "#overview-backup-warning [data-role=backup-schedule]")
      refute has_element?(lv, "#overview-backup-warning [data-role=backup-next]")
      refute has_element?(lv, "#overview-backup-warning", "ask whoever runs this server")
      assert has_element?(lv, "#overview-backup-warning a[data-role=open-backups]")
    end

    test "Home: no strip for a clean run", %{conn: conn} do
      good_backup!()

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute html =~ "overview-backup-warning"
    end

    test "Home: an org admin who is not a platform admin sees nothing", %{conn: conn} do
      good_backup!()
      notice!(%{})

      for user <- [org_admin(), authed_user(:editor)] do
        {:ok, _lv, html} = conn |> log_in(user) |> live(~p"/editor/overview")

        refute html =~ "overview-backup-warning"
        refute html =~ "Retention was skipped"
      end
    end
  end

  # #2931: backups a schedule keeps that were deleted outside the app are a
  # warning under the headline for eight days, never the alarm, and never on
  # Home.
  describe "held backups deleted outside the app (#2931)" do
    defp held_deleted!(attrs) do
      Backups.report_backup_notice!(
        Map.merge(
          %{
            kind: :held_deleted,
            scope: "local",
            units: ["db:20261110-020000"],
            total: 1,
            at: ~U[2026-11-15 09:30:00.000000Z]
          },
          attrs
        ),
        actor: Backups.system()
      )
    end

    defp good_db_backup! do
      offsite_run!(%{"local" => %{"status" => "ok"}}, [], nil)
    end

    test "one backup: a dated warning naming it, with the guide; no alarm", %{conn: conn} do
      good_db_backup!()
      held_deleted!(%{at: DateTime.utc_now()})
      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-held-deleted-0",
               "On #{today}"
             )

      assert has_element?(
               lv,
               "#backup-held-deleted-0",
               "a backup a schedule keeps was deleted outside the app: " <>
                 "Database backup of 2026-11-10 02:00 UTC."
             )

      assert has_element?(lv, "#backup-held-deleted", "Replace it with this release's copy.")

      assert has_element?(
               lv,
               ~s|#backup-held-deleted-docs[href$="backups.md#the-hold-markers"]|
             )

      assert has_element?(lv, "section.border-warning\\/30 #backup-held-deleted")
      refute has_element?(lv, "section.border-error\\/30")
    end

    test "many: counted, ten named, and the rest as \"and N more\"", %{conn: conn} do
      good_db_backup!()
      units = for n <- 10..19, do: "media:20261110-0200#{n}"
      held_deleted!(%{units: units, total: 12, at: DateTime.utc_now()})

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               "#backup-held-deleted-0",
               "12 backups a schedule keeps were deleted outside the app: " <>
                 "Media backup of 2026-11-10 02:00 UTC"
             )

      assert has_element?(
               lv,
               "#backup-held-deleted-0",
               "Media backup of 2026-11-10 02:00 UTC and 2 more."
             )
    end

    test "older than eight days, or none: nothing", %{conn: conn} do
      good_db_backup!()
      held_deleted!(%{at: DateTime.add(DateTime.utc_now(), -9 * 86_400, :second)})

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      refute has_element?(lv, "#backup-held-deleted")
    end

    test "not on Home", %{conn: conn} do
      good_db_backup!()
      held_deleted!(%{at: DateTime.utc_now()})

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute html =~ "overview-backup-warning"
      refute html =~ "deleted outside the app"
    end
  end

  describe "re-send a partly off-site backup (#2949)" do
    @bucket_id "1d2e3f40-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    @bucket_key "dest:" <> @bucket_id
    @env_remote "offsite:kiln"

    # A partly off-site in-app run `days` old that reached the env remote and
    # not the stored "Bucket", with its dump on disk (`file?:`).
    defp resend_run!(dir, opts \\ []) do
      days = Keyword.get(opts, :days, 0)
      at = DateTime.add(DateTime.utc_now(), -days * 86_400 - 3600, :second)
      stamp = Backups.Artifact.stamp(at)
      name = "kiln-db-#{stamp}.dump"

      if Keyword.get(opts, :file?, true) do
        File.mkdir_p!(Path.join(dir, "db"))
        File.write!(Path.join([dir, "db", name]), "dump")
      end

      Application.put_env(
        :kiln_cms,
        Backups,
        Keyword.put(Application.get_env(:kiln_cms, Backups), :rclone_remote, @env_remote)
      )

      unless Keyword.get(opts, :bucket?, true) == false do
        Ash.Seed.seed!(Backups.DestinationConfig, %{
          id: @bucket_id,
          name: "Bucket",
          kind: "local",
          settings: %{},
          enabled: true,
          prune: Keyword.get(opts, :prune, false),
          position: 1
        })
      end

      %{stamp: stamp, trigger: "manual", components: [:db], started_at: at}
      |> Map.put(:dir_id, Ash.UUID.generate())
      |> Backups.start_run!(actor: Backups.system())
      |> Backups.finish_run!(
        %{
          artifacts: [
            %{
              kind: :db,
              name: name,
              bytes: 4,
              sha256: String.duplicate("d", 64),
              verified: true,
              destinations: %{"local" => %{"status" => "ok"}}
            }
          ],
          destinations: [
            %{key: "rclone:" <> @env_remote, kind: "rclone", label: @env_remote, status: :ok},
            %{key: @bucket_key, kind: "local", label: "Bucket", status: :failed, error: "x"}
          ],
          offsite_status: Keyword.get(opts, :offsite_status, :partial)
        },
        actor: Backups.system()
      )
    end

    defp resend_button(run), do: ~s|#backup-run-#{run.id} button[data-role="resend"]|

    test "a partly off-site run whose files are here offers Re-send, naming where", %{
      conn: conn,
      dir: dir
    } do
      run = resend_run!(dir)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(lv, resend_button(run), "Re-send")

      assert has_element?(
               lv,
               resend_button(run) <> ~s|[data-confirm*="Re-send this backup to Bucket?"]|
             )

      refute has_element?(lv, resend_button(run) <> ~s|[data-confirm*="retention"]|)
      assert has_element?(lv, "#resend-help-#{run.id}")
    end

    test "an old run says retention there may remove it again", %{conn: conn, dir: dir} do
      run = resend_run!(dir, days: 20, prune: true)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      assert has_element?(
               lv,
               resend_button(run) <>
                 ~s|[data-confirm*="older than 14 days, so retention on Bucket may remove it"]|
             )
    end

    test "no Re-send without files here, a destination to send to, or a partial outcome", %{
      conn: conn,
      dir: dir
    } do
      no_file = resend_run!(dir, file?: false)
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")
      assert has_element?(lv, "#backup-run-#{no_file.id}")
      refute has_element?(lv, resend_button(no_file))

      Backups.DestinationConfig
      |> KilnCMS.Repo.get!(@bucket_id)
      |> Ecto.Changeset.change(enabled: false)
      |> KilnCMS.Repo.update!()

      gone = resend_run!(dir, bucket?: false, days: 1)
      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")
      refute has_element?(lv, resend_button(gone))
    end

    test "clicking it starts the re-send: a flash, the strip with its Cancel, a badge", %{
      conn: conn,
      dir: dir
    } do
      run = resend_run!(dir)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")
      html = lv |> element(resend_button(run)) |> render_click()

      assert html =~ "Re-send started"
      assert has_element?(lv, "#backup-in-flight [data-role=step]", "Re-sending off-site")

      assert has_element?(
               lv,
               ~s|#backup-in-flight button[data-role="cancel-resend"][data-confirm="Stop this re-send? What was already sent stays recorded."]|
             )

      refute has_element?(lv, ~s|#backup-in-flight button[data-role="cancel"]|)
      assert has_element?(lv, "#backup-run-#{run.id} [data-role=resending]")
      refute has_element?(lv, resend_button(run))

      # The strip's Cancel stops it.
      html =
        lv |> element(~s|#backup-in-flight button[data-role="cancel-resend"]|) |> render_click()

      assert html =~ "Re-send canceled"
      refute has_element?(lv, "#backup-in-flight")
      assert Backups.in_flight() == nil
    end

    test "a second click while it runs is told it is already being re-sent", %{
      conn: conn,
      dir: dir
    } do
      run = resend_run!(dir)

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")
      assert render_hook(lv, "resend_run", %{"id" => run.id}) =~ "Re-send started"
      assert render_hook(lv, "resend_run", %{"id" => run.id}) =~ "being re-sent right now"
    end

    test "a run that can't be re-sent, or no run, is refused with a flash", %{
      conn: conn,
      dir: dir
    } do
      complete = resend_run!(dir, offsite_status: :complete)

      complete =
        Backups.record_run_resend!(
          complete,
          %{destinations: [%{key: @bucket_key, status: :ok}], offsite_status: :complete},
          actor: Backups.system()
        )

      {:ok, lv, _html} = conn |> admin_conn() |> live_ready(~p"/editor/backups")

      for id <- [complete.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert render_hook(lv, "resend_run", %{"id" => id}) =~ "can&#39;t be re-sent"
      end

      render_hook(lv, "resend_run", %{"stamp" => "../../x"})
      assert Backups.in_flight() == nil
    end

    test "every refusal has its own words" do
      for {reason, text} <- [
            busy: "never queued",
            in_flight: "being re-sent right now",
            pruned: "gone, pruned or no longer verified",
            nothing_to_send: "nowhere to re-send it",
            canceled_recently: "canceled moments ago",
            forbidden: "Only a platform admin",
            destinations_unreadable: "Couldn't read the backup destinations",
            disabled: "BACKUP_ENABLED"
          ] do
        reason = if reason == :canceled_recently, do: {:canceled_recently, 30}, else: reason
        assert KilnCMSWeb.BackupLive.resend_message(reason) =~ text
      end
    end

    test "a started re-send says what it skipped, the unreadable entry apart" do
      assert KilnCMSWeb.BackupLive.resend_started_message(%{skipped: ["NAS"]}) =~
               "removed or disabled since: NAS."

      message =
        KilnCMSWeb.BackupLive.resend_started_message(%{skipped: [], unreadable_skipped?: true})

      assert message =~ "no stored destination it has no entry for is enabled now"
      refute message =~ "removed or disabled"
    end

    test "the late Cancel's words" do
      error = %Ash.Error.Invalid{
        errors: [
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :status,
            message: KilnCMS.Backups.Run.Changes.CancelResend.finishing()
          )
        ]
      }

      assert KilnCMSWeb.BackupLive.cancel_resend_message(error) =~ "Too late to cancel"
    end

    test "the handlers re-check platform admin: editor, org admin, expired grant and anonymous are sent away",
         %{dir: dir} do
      run = resend_run!(dir)

      org_admin = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: org_admin.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      for user <- [
            authed_user(:editor),
            org_admin,
            authed_user(:viewer),
            expired_grant_user(),
            nil
          ],
          event <- ["resend_run", "cancel_resend"] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}
        assert_denied(KilnCMSWeb.BackupLive.handle_event(event, %{"id" => run.id}, socket))
      end

      assert Backups.in_flight() == nil
    end
  end
end
