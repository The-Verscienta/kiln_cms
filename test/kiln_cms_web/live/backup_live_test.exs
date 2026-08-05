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

        assert [%Oban.Job{worker: "KilnCMS.Backups.Worker", args: args, queue: "backups"}] =
                 KilnCMS.Repo.all(Oban.Job)

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
  end
end
