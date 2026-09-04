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

  alias KilnCMS.Accounts.User
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
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

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
      assert {:error, {:live_redirect, %{to: "/"}}} =
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
        assert [%Oban.Job{worker: "KilnCMS.Backups.Worker", args: args, queue: "backups"}] =
                 Enum.filter(
                   KilnCMS.Repo.all(Oban.Job),
                   &String.starts_with?(&1.worker, "KilnCMS.Backups.")
                 )

        assert args["trigger"] == "manual"
      end
    end
  end

  describe "the overview warning" do
    test "an admin with no backup sees the strip", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert html =~ "overview-backup-warning"
      assert html =~ "No backup has ever been recorded"
    end

    test "it disappears once a backup is fresh", %{conn: conn, dir: dir} do
      # Absent rather than green: a permanent banner is one nobody reads, and
      # its absence is what makes the red one land.
      seed_manifest!(dir, [])

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute html =~ "overview-backup-warning"
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
end
