defmodule KilnCMSWeb.BackupDestinationsSftpLiveTest do
  @moduledoc """
  An SFTP destination on the Destinations tab (#2222): the form (a
  multi-line, write-only private key, saved disabled), and the host key
  panel: check, trust, refusal of a key the page never found, and the
  re-check of the platform role on every event.

  `async: false`: it sets `BACKUP_SFTP_PRIVATE_HOSTS` and the backup config,
  application env (VM-global).
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  import KilnCMS.Test.BackupSchedules, only: [user: 1, platform_admin: 0]
  import Phoenix.LiveViewTest

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Destination.Sftp
  alias KilnCMS.Test.SftpServer

  @path "/editor/backups/destinations"

  setup %{tmp_dir: tmp} do
    server = SftpServer.start!()
    sftp = Application.get_env(:kiln_cms, Sftp, [])
    backups = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, Sftp, Keyword.put(sftp, :private_hosts, ["127.0.0.1"]))

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(backups,
        enabled: true,
        dir: Path.join(tmp, "backups"),
        rclone_remote: nil,
        local_destination_roots: []
      )
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, Sftp, sftp)
      Application.put_env(:kiln_cms, KilnCMS.Backups, backups)
      SftpServer.stop(server)
    end)

    %{server: server}
  end

  defp mount(conn, user \\ platform_admin()) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(user.email), "password" => "password123456"},
        []
      )

    {:ok, lv, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(signed_in)
      |> live(@path)

    lv
  end

  defp stored!(server) do
    Backups.create_backup_destination!(
      %{
        name: "NAS",
        kind: "sftp",
        enabled: false,
        settings: %{
          "host" => "127.0.0.1",
          "port" => server.port,
          "username" => "kiln",
          "path" => "/backups/kiln"
        },
        secrets: %{"password" => SftpServer.password()}
      },
      actor: platform_admin()
    )
  end

  test "the form takes a private key as text it never shows again, and saves disabled", %{
    conn: conn,
    server: server
  } do
    lv = mount(conn)
    lv |> element("#destination-new") |> render_click()
    lv |> element("#destination-kind-sftp") |> render_click()

    assert has_element?(lv, "textarea#destination-new-private_key")
    assert has_element?(lv, "#destination-sftp-hint", "stays disabled")
    refute has_element?(lv, "#destination-new-enabled[checked]")

    key = server.client_key

    html =
      lv
      |> form("#destination-form",
        destination: %{
          name: "NAS",
          enabled: "false",
          settings: %{
            host: "127.0.0.1",
            port: Integer.to_string(server.port),
            username: "kiln",
            path: "/backups/kiln"
          },
          secrets: %{private_key: key}
        }
      )
      |> render_submit()

    refute html =~ "PRIVATE KEY"
    assert [row] = Backups.list_backup_destinations!(actor: platform_admin())
    assert row.kind == "sftp"
    refute row.enabled
    assert render(lv) =~ "sftp://kiln@127.0.0.1:#{server.port}/backups/kiln"
    assert has_element?(lv, "#host-key-#{row.id} [data-role=host-key-unconfirmed]")
  end

  test "a path with a space in a NAS share name saves from the form (#3199)", %{
    conn: conn,
    server: server
  } do
    lv = mount(conn)
    lv |> element("#destination-new") |> render_click()
    lv |> element("#destination-kind-sftp") |> render_click()

    submit = fn path ->
      lv
      |> form("#destination-form",
        destination: %{
          name: "NAS",
          enabled: "false",
          settings: %{
            host: "127.0.0.1",
            port: Integer.to_string(server.port),
            username: "kiln",
            path: path
          },
          secrets: %{password: SftpServer.password()}
        }
      )
      |> render_submit()
    end

    # Climbing out is still refused, and nothing is saved.
    assert submit.("/volume1/../etc") =~ "the path must be folder names"
    assert Backups.list_backup_destinations!(actor: platform_admin()) == []

    submit.("/volume1/Backup Share/kiln")

    assert [row] = Backups.list_backup_destinations!(actor: platform_admin())
    assert row.settings["path"] == "/volume1/Backup Share/kiln"
    assert render(lv) =~ "sftp://kiln@127.0.0.1:#{server.port}/volume1/Backup Share/kiln"
  end

  test "check, compare and trust the key; the destination can then be enabled", %{
    conn: conn,
    server: server
  } do
    row = stored!(server)
    lv = mount(conn)

    lv |> element("#host-key-#{row.id} [data-role=scan-host-key]") |> render_click()
    render_async(lv, 2_000)

    assert has_element?(
             lv,
             "#host-key-#{row.id} [data-role=host-key-fingerprint]",
             server.fingerprint
           )

    lv |> element("#host-key-#{row.id} [data-role=trust-host-key]") |> render_click()

    assert Backups.get_backup_destination!(row.id, actor: platform_admin()).host_key[
             "fingerprint"
           ] == server.fingerprint

    assert has_element?(
             lv,
             "#host-key-#{row.id} [data-role=host-key-trusted]",
             server.fingerprint
           )

    lv |> element("#backup-destination-#{row.id} [data-role=toggle]") |> render_click()
    assert Backups.get_backup_destination!(row.id, actor: platform_admin()).enabled
  end

  test "a fingerprint the server doesn't have is not trusted", %{conn: conn, server: server} do
    row = stored!(server)
    lv = mount(conn)

    lv
    |> form("#host-key-match-#{row.id}", %{fingerprint: "SHA256:" <> String.duplicate("x", 43)})
    |> render_submit()

    render_async(lv, 2_000)

    assert has_element?(
             lv,
             "#host-key-#{row.id} [data-role=host-key-failed]",
             "no key with that fingerprint"
           )

    assert Backups.get_backup_destination!(row.id, actor: platform_admin()).host_key == nil
  end

  test "trust names only the row: with no check on this page nothing is trusted", %{
    conn: conn,
    server: server
  } do
    row = stored!(server)
    lv = mount(conn)

    render_hook(lv, "trust_host_key", %{
      "id" => row.id,
      "fingerprint" => server.fingerprint,
      "algorithm" => server.type
    })

    assert Backups.get_backup_destination!(row.id, actor: platform_admin()).host_key == nil
  end

  # Called directly, as the main tab's test does: a refused mount leaves no
  # socket to push events down.
  test "each host key handler refuses a socket that isn't a platform admin's", %{
    server: server
  } do
    row = stored!(server)

    scanned = %{
      algorithm: server.type,
      fingerprint: server.fingerprint,
      previous_fingerprint: nil,
      how: :scanned
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: %{role: :editor},
        host_keys: %{row.id => {:scanned, scanned}},
        destinations: [row]
      }
    }

    params = %{"id" => row.id, "destination_id" => row.id, "fingerprint" => server.fingerprint}

    for event <- ~w(scan_host_key match_host_key trust_host_key dismiss_host_key) do
      assert {:noreply, denied} =
               KilnCMSWeb.BackupDestinationsLive.handle_event(event, params, socket)

      assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = denied.redirected
    end

    assert {:noreply, denied} =
             KilnCMSWeb.BackupDestinationsLive.handle_async(
               {:host_key, row.id},
               {:ok, {nil, {:ok, scanned}}},
               socket
             )

    assert {:live, :redirect, _} = denied.redirected
    assert Backups.get_backup_destination!(row.id, actor: platform_admin()).host_key == nil
    refute_received {:sftp_auth, _method, _user}
  end

  test "an editor never gets the tab", %{conn: conn} do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)
    editor = user(:editor)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(editor.email), "password" => "password123456"},
        []
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(signed_in)

    assert {:error, {_kind, %{to: _to}}} = live(conn, @path)
  end
end
