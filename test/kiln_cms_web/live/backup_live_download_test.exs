defmodule KilnCMSWeb.BackupLiveDownloadTest do
  @moduledoc """
  The History rows' Download menu (part of #2225): what it offers, and what
  a click does. The click checks the name against the run as the admin,
  writes nothing, and pushes a one-minute link bound to this user, this
  session and this server's backup directory; it never renders a URL.

  `async: false`: it changes the VM-wide `KilnCMS.Backups` env (`:dir`) and
  `:console_host`.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{Token, User}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, DirId}
  alias KilnCMS.Security
  alias KilnCMSWeb.BackupDownloadToken

  @password "password123456"
  @stamp "20261118-031700"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bld_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil, keep_days: 14)
    )

    console = Application.get_env(:kiln_cms, :console_host)
    Application.delete_env(:kiln_cms, :console_host)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)

      if console,
        do: Application.put_env(:kiln_cms, :console_host, console),
        else: Application.delete_env(:kiln_cms, :console_host)
    end)

    %{dir: dir}
  end

  defp authed_user(role, attrs \\ %{}) do
    email = "bld-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )

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

  defp live_ready(conn) do
    {:ok, lv, _html} = live(conn, ~p"/editor/backups")
    await_page(lv)
    lv
  end

  defp await_page(lv, tries \\ 20)
  defp await_page(lv, 0), do: flunk("the Backups page was still busy: #{render(lv)}")

  defp await_page(lv, tries) do
    render_async(lv, 2_000)

    unless has_element?(lv, ~s|#backup-page[data-busy="false"]|),
      do: await_page(lv, tries - 1)
  end

  defp write!(dir, sub, name) do
    data = :crypto.strong_rand_bytes(2_048)
    File.write!(Path.join([dir, sub, name]), data)
    %{name: name, bytes: byte_size(data)}
  end

  # A succeeded in-app run with a dump and a media set of three parts, the
  # second part pruned here (still on disk) and the third gone.
  defp seeded_run!(dir, opts \\ []) do
    dump = write!(dir, "db", "kiln-db-#{@stamp}.dump")
    [one, two, three] = Artifact.set_names(@stamp, 3)
    one = write!(dir, "media", one)
    two = write!(dir, "media", two)
    three = %{name: three, bytes: 10}

    %{stamp: @stamp, trigger: "test", dir_id: Keyword.get(opts, :dir_id)}
    |> Backups.start_run!(actor: Backups.system())
    |> Backups.finish_run!(
      %{
        artifacts: [
          %{
            kind: :db,
            name: dump.name,
            bytes: dump.bytes,
            verified: true,
            destinations: %{"local" => %{"status" => "ok"}}
          },
          %{
            kind: :media,
            name: "kiln-media-#{@stamp}",
            bytes: one.bytes + two.bytes + three.bytes,
            verified: true,
            destinations: %{"local" => %{"status" => "ok"}},
            parts: [
              %{"name" => one.name, "bytes" => one.bytes},
              %{
                "name" => two.name,
                "bytes" => two.bytes,
                "destinations" => %{"local" => %{"status" => "pruned"}}
              },
              %{"name" => three.name, "bytes" => three.bytes}
            ]
          }
        ]
      },
      actor: Backups.system()
    )
  end

  defp file_button(run, name),
    do: ~s|#download-#{run.id} button[data-role="download-file"][data-file="#{name}"]|

  describe "the menu" do
    test "offers each file that is here and not pruned, and each checksum file", %{
      conn: conn,
      dir: dir
    } do
      run = seeded_run!(dir)
      lv = conn |> log_in(authed_user(:admin)) |> live_ready()

      [one, two, three] = Artifact.set_names(@stamp, 3)

      assert has_element?(lv, file_button(run, "kiln-db-#{@stamp}.dump"))
      assert has_element?(lv, file_button(run, Artifact.sidecar_name(:db, @stamp)))
      assert has_element?(lv, file_button(run, one))
      assert has_element?(lv, file_button(run, Artifact.sidecar_name(:media, @stamp)))

      refute has_element?(lv, file_button(run, two))
      refute has_element?(lv, file_button(run, three))

      assert has_element?(
               lv,
               ~s|#download-#{run.id} [data-kind="media"] [data-role="download-incomplete"]|,
               "Incomplete set"
             )

      refute has_element?(
               lv,
               ~s|#download-#{run.id} [data-kind="db"] [data-role="download-incomplete"]|
             )

      refute render(lv) =~ "/editor/backups/download"
    end

    test "a run pinned to another server's backup directory says so instead", %{
      conn: conn,
      dir: dir
    } do
      {:ok, _here} = DirId.local(dir)
      run = seeded_run!(dir, dir_id: Ash.UUID.generate())
      lv = conn |> log_in(authed_user(:admin)) |> live_ready()

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="download-other-server"]|,
               "another server's backup directory"
             )

      refute has_element?(lv, ~s|#backup-run-#{run.id} [data-role="download-dir-id-unreadable"]|)
      refute has_element?(lv, "#download-#{run.id}")
    end

    test "a pinned run on a server whose directory id can't be read says that, not another server",
         %{conn: conn, dir: dir} do
      # No `.kiln-dir-id` here: this server's id can't be read, which says
      # nothing about where the run's files are.
      run = seeded_run!(dir, dir_id: Ash.UUID.generate())
      lv = conn |> log_in(authed_user(:admin)) |> live_ready()

      assert has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role="download-dir-id-unreadable"]|,
               "directory id couldn"
             )

      refute has_element?(lv, ~s|#backup-run-#{run.id} [data-role="download-other-server"]|)
      refute has_element?(lv, "#download-#{run.id}")
    end

    test "a run pinned to this server's own directory offers its files", %{conn: conn, dir: dir} do
      {:ok, here} = DirId.local(dir)
      run = seeded_run!(dir, dir_id: here)
      lv = conn |> log_in(authed_user(:admin)) |> live_ready()

      assert has_element?(lv, file_button(run, "kiln-db-#{@stamp}.dump"))

      refute has_element?(
               lv,
               ~s|#backup-run-#{run.id} [data-role^="download-"][data-role$="-unreadable"]|
             )

      refute has_element?(lv, ~s|#backup-run-#{run.id} [data-role="download-other-server"]|)
    end

    test "while the console shares an origin, one note replaces every Download", %{
      conn: conn,
      dir: dir
    } do
      run = seeded_run!(dir)

      Ash.Seed.seed!(Accounts.Organization, %{
        name: "Second",
        slug: "bld-second-#{System.unique_integer([:positive])}",
        status: :active
      })

      lv = conn |> log_in(authed_user(:admin)) |> live_ready()

      assert has_element?(lv, "#backup-download-refused", "KILN_CONSOLE_HOST")
      refute has_element?(lv, "#download-#{run.id}")
      refute has_element?(lv, ~s|[data-role="download-file"]|)
    end
  end

  describe "a click" do
    test "pushes a one-minute link for this user, session, run and file, and records nothing",
         %{conn: conn, dir: dir} do
      run = seeded_run!(dir)
      admin = authed_user(:admin)
      lv = conn |> log_in(admin) |> live_ready()
      name = "kiln-db-#{@stamp}.dump"

      lv |> element(file_button(run, name)) |> render_click()

      assert_push_event(lv, "kiln:backup-download", %{
        action: "/editor/backups/download",
        token: token
      })

      assert {:ok, claims} = BackupDownloadToken.verify(token)

      assert claims == %{
               run_id: run.id,
               file: name,
               user_id: admin.id,
               session_jti: Token.peeked_jti(admin.__metadata__.token),
               dir_id: Backups.download_dir_id()
             }

      assert render(lv) =~ "Your download is starting"
      assert Security.list_instance_events!(%{type: :backup_downloaded}, actor: admin) == []
    end

    test "a forged id or name gets an error flash and no link", %{conn: conn, dir: dir} do
      run = seeded_run!(dir)
      lv = conn |> log_in(authed_user(:admin)) |> live_ready()
      [_one, pruned, _three] = Artifact.set_names(@stamp, 3)

      for {id, file, message} <- [
            {Ash.UUID.generate(), "kiln-db-#{@stamp}.dump", "one of this backup"},
            {"not-a-uuid", "kiln-db-#{@stamp}.dump", "one of this backup"},
            {run.id, "../../etc/passwd", "one of this backup"},
            {run.id, pruned, "removed from this server by retention"}
          ] do
        html = render_hook(lv, "download", %{"id" => id, "file" => file})
        assert html =~ message
        refute_push_event(lv, "kiln:backup-download", %{})
      end

      # A mangled payload is a no-op.
      render_hook(lv, "download", %{"id" => run.id})
      refute_push_event(lv, "kiln:backup-download", %{})
    end

    test "a socket that isn't a platform admin's is sent away, with no link", %{dir: dir} do
      run = seeded_run!(dir)

      expired = %{
        role: :editor,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      for user <- [%{role: :editor}, %{role: :viewer}, expired, nil] do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, current_user: user, current_session_jti: "jti"}
        }

        assert {:noreply, socket} =
                 KilnCMSWeb.BackupLive.handle_event(
                   "download",
                   %{"id" => run.id, "file" => "kiln-db-#{@stamp}.dump"},
                   socket
                 )

        assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = socket.redirected
        refute socket.private[:live_temp][:push_events]
      end
    end

    test "a page with no session to bind the link to mints none", %{dir: dir} do
      run = seeded_run!(dir)
      admin = authed_user(:admin)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: admin, current_session_jti: nil, flash: %{}}
      }

      assert {:noreply, socket} =
               KilnCMSWeb.BackupLive.handle_event(
                 "download",
                 %{"id" => run.id, "file" => "kiln-db-#{@stamp}.dump"},
                 socket
               )

      assert socket.assigns.flash["error"] =~ "Sign in again"
      refute socket.private[:live_temp][:push_events]
    end
  end
end
