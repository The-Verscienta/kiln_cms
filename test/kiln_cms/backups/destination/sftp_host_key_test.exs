defmodule KilnCMS.Backups.Destination.SftpHostKeyTest do
  @moduledoc """
  Trusting an SFTP server's host key (#2222, ADR 0079), end to end on the
  resource: saved disabled, the key read without logging in, trusted by a
  platform admin only and audited with the key it replaced, a race between
  two admins refused, and the key reaching the adapter in a way no form can
  forge.

  `async: false`: it sets `BACKUP_SFTP_PRIVATE_HOSTS` (application env).
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Destination.Sftp
  alias KilnCMS.Backups.DestinationConfig
  alias KilnCMS.Security
  alias KilnCMS.Test.{BackupSchedules, SftpServer}

  setup do
    server = SftpServer.start!()
    previous = Application.get_env(:kiln_cms, Sftp, [])
    Application.put_env(:kiln_cms, Sftp, Keyword.put(previous, :private_hosts, ["127.0.0.1"]))

    on_exit(fn ->
      Application.put_env(:kiln_cms, Sftp, previous)
      SftpServer.stop(server)
    end)

    %{server: server, admin: BackupSchedules.platform_admin()}
  end

  defp attrs(server, overrides \\ %{}) do
    Map.merge(
      %{
        name: "NAS #{System.unique_integer([:positive])}",
        kind: "sftp",
        enabled: false,
        settings: %{
          "host" => "127.0.0.1",
          "port" => Integer.to_string(server.port),
          "username" => "kiln",
          "path" => "/backups/#{System.unique_integer([:positive])}"
        },
        secrets: %{"password" => SftpServer.password()}
      },
      overrides
    )
  end

  defp create!(server, admin), do: Backups.create_backup_destination!(attrs(server), actor: admin)

  defp auth_attempts do
    receive do
      {:sftp_auth, method, user} -> [{method, user} | auth_attempts()]
    after
      0 -> []
    end
  end

  defp trust(row, scanned, actor, previous \\ nil) do
    Backups.trust_backup_destination_host_key(
      row,
      scanned.algorithm,
      scanned.fingerprint,
      :scanned,
      %{previous_fingerprint: previous},
      actor: actor
    )
  end

  defp events(type, admin) do
    Security.list_instance_events!(actor: admin, page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  describe "saving" do
    test "an SFTP destination is saved disabled, and can't be saved enabled", %{
      server: server,
      admin: admin
    } do
      assert {:error, error} =
               Backups.create_backup_destination(attrs(server, %{enabled: true}), actor: admin)

      assert Exception.message(error) =~ "host key is confirmed"

      row = create!(server, admin)
      assert row.enabled == false
      assert row.host_key == nil
      assert row.settings["port"] == server.port

      assert {:error, _} = Backups.update_backup_destination(row, %{enabled: true}, actor: admin)
    end

    test "an unlisted loopback host is refused on save", %{server: server, admin: admin} do
      Application.put_env(:kiln_cms, Sftp, private_hosts: [])

      assert {:error, error} = Backups.create_backup_destination(attrs(server), actor: admin)
      assert Exception.message(error) =~ "BACKUP_SFTP_PRIVATE_HOSTS"
    end

    test "no form can put a host key into the settings", %{server: server, admin: admin} do
      row = create!(server, admin)
      forged = Map.put(row.settings, Sftp.fingerprint_key(), server.fingerprint)

      assert {:error, error} =
               Backups.update_backup_destination(row, %{settings: forged}, actor: admin)

      assert Exception.message(error) =~ "is not a setting of this kind"
    end

    test "two destinations on one server, one path inside the other, are refused", %{
      server: server,
      admin: admin
    } do
      row = create!(server, admin)
      inner = put_in(attrs(server).settings["path"], row.settings["path"] <> "/inner")

      assert {:error, error} = Backups.create_backup_destination(inner, actor: admin)
      assert Exception.message(error) =~ "another destination"
    end
  end

  describe "checking and trusting the key" do
    test "a scan reads the key and sends no credential", %{server: server, admin: admin} do
      row = create!(server, admin)
      _ = auth_attempts()

      assert {:ok, %{algorithm: type, fingerprint: fingerprint, previous_fingerprint: nil}} =
               Backups.scan_destination_host_key(row.id, actor: admin)

      assert type == server.type
      assert fingerprint == server.fingerprint
      assert auth_attempts() == []
    end

    test "a pasted fingerprint is looked for; one the server lacks is no match", %{
      server: server,
      admin: admin
    } do
      row = create!(server, admin)

      assert {:ok, %{fingerprint: fingerprint}} =
               Backups.scan_destination_host_key(row.id,
                 actor: admin,
                 fingerprint:
                   String.downcase("sha256") <>
                     ":" <> String.trim_leading(server.fingerprint, "SHA256:")
               )

      assert fingerprint == server.fingerprint

      assert {:error, :no_match} =
               Backups.scan_destination_host_key(row.id,
                 actor: admin,
                 fingerprint: "SHA256:" <> String.duplicate("x", 43)
               )
    end

    test "trusting records the key, audits it, and lets the destination be enabled", %{
      server: server,
      admin: admin
    } do
      row = create!(server, admin)
      {:ok, scanned} = Backups.scan_destination_host_key(row.id, actor: admin)

      assert {:ok, trusted} = trust(row, scanned, admin)
      assert trusted.host_key["fingerprint"] == server.fingerprint
      assert trusted.host_key["how"] == "scanned"
      assert trusted.updated_at == row.updated_at

      assert [event] = events(:backup_destination_host_key_trusted, admin)
      assert event.actor_id == admin.id
      assert event.metadata["previous_fingerprint"] == "none"
      assert event.metadata["fingerprint"] == server.fingerprint

      assert {:ok, %{enabled: true}} =
               Backups.update_backup_destination(trusted, %{enabled: true}, actor: admin)

      # The adapter gets the key, and a call now works.
      {:ok, config} =
        DestinationConfig.to_config(Backups.get_backup_destination!(row.id, actor: admin))

      assert config.settings[Sftp.fingerprint_key()] == server.fingerprint
      assert :ok = Sftp.test(config)
    end

    test "trusting again records the key it replaced", %{server: server, admin: admin} do
      row = create!(server, admin)
      {:ok, scanned} = Backups.scan_destination_host_key(row.id, actor: admin)

      {:ok, row} =
        trust(row, %{scanned | fingerprint: "SHA256:" <> String.duplicate("o", 43)}, admin)

      {:ok, rescanned} = Backups.scan_destination_host_key(row.id, actor: admin)
      assert rescanned.previous_fingerprint == "SHA256:" <> String.duplicate("o", 43)
      assert {:ok, _} = trust(row, rescanned, admin, rescanned.previous_fingerprint)

      assert [latest | _] = events(:backup_destination_host_key_trusted, admin)
      assert latest.metadata["previous_fingerprint"] == "SHA256:" <> String.duplicate("o", 43)
    end

    test "a key trusted by someone else since the scan is refused as stale", %{
      server: server,
      admin: admin
    } do
      row = create!(server, admin)
      {:ok, scanned} = Backups.scan_destination_host_key(row.id, actor: admin)

      {:ok, _} =
        trust(row, %{scanned | fingerprint: "SHA256:" <> String.duplicate("o", 43)}, admin)

      # The first scan saw no key stored; one is now.
      assert {:error, %Ash.Error.Invalid{errors: errors}} = trust(row, scanned, admin, nil)
      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
    end

    test "only a platform admin may scan or trust; never the pipeline's actor", %{
      server: server,
      admin: admin
    } do
      row = create!(server, admin)
      editor = BackupSchedules.user(:editor)
      scanned = %{algorithm: server.type, fingerprint: server.fingerprint}

      assert {:error, _forbidden} = Backups.scan_destination_host_key(row.id, actor: editor)
      assert {:error, %Ash.Error.Forbidden{}} = trust(row, scanned, editor)
      assert {:error, %Ash.Error.Forbidden{}} = trust(row, scanned, Backups.system())
      assert Backups.get_backup_destination!(row.id, actor: admin).host_key == nil
    end

    test "a key that is not an SFTP destination's, or not well formed, is refused", %{
      server: server,
      admin: admin
    } do
      row = create!(server, admin)

      assert {:error, %Ash.Error.Invalid{}} =
               trust(row, %{algorithm: "ssh-dss", fingerprint: server.fingerprint}, admin)

      assert {:error, %Ash.Error.Invalid{}} =
               trust(row, %{algorithm: server.type, fingerprint: "MD5:00"}, admin)

      local = KilnCMS.Test.BackupDestinations.destination!()

      assert {:error, :not_sftp} = Backups.scan_destination_host_key(local.id, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               trust(local, %{algorithm: server.type, fingerprint: server.fingerprint}, admin)
    end
  end
end
