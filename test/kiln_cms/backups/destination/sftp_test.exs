defmodule KilnCMS.Backups.Destination.SftpTest do
  @moduledoc """
  The SFTP destination against a real SFTP server (#2222,
  `KilnCMS.Test.SftpServer`): copy, list, read back and delete; the host key
  checked before any credential is sent, and a changed one recorded once;
  the address rule on every call; symbolic links refused; and a call killed
  mid-way leaving no connection behind.

  `async: false`: it sets `BACKUP_SFTP_PRIVATE_HOSTS` (application env) and
  turns security alerts on, both VM-global.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Destination
  alias KilnCMS.Backups.Destination.Sftp
  alias KilnCMS.Backups.Destination.Sftp.{Credentials, Files, Session, Target, Upload}
  alias KilnCMS.Backups.DestinationConfig
  alias KilnCMS.Security
  alias KilnCMS.Test.{BackupSchedules, SftpServer}

  @db "kiln-db-20260101-000000.dump"

  setup context do
    server = SftpServer.start!(Map.get(context, :server, []))
    previous = Application.get_env(:kiln_cms, Sftp, [])
    Application.put_env(:kiln_cms, Sftp, Keyword.put(previous, :private_hosts, ["127.0.0.1"]))

    on_exit(fn ->
      Application.put_env(:kiln_cms, Sftp, previous)
      SftpServer.stop(server)
    end)

    %{server: server}
  end

  defp config(server, overrides \\ %{}) do
    settings =
      Map.merge(
        %{
          "host" => "127.0.0.1",
          "port" => server.port,
          "username" => SftpServer.user(),
          "path" => "/backups/kiln",
          Sftp.algorithm_key() => server.type,
          Sftp.fingerprint_key() => server.fingerprint
        },
        Map.get(overrides, :settings, %{})
      )

    %Config{
      id: Map.get(overrides, :id),
      key: "dest:test",
      kind: "sftp",
      settings: settings,
      secrets: Map.get(overrides, :secrets, %{"password" => SftpServer.password()})
    }
  end

  defp local_file(dir, name, bytes) do
    path = Path.join(dir, name)
    data = :crypto.strong_rand_bytes(bytes)
    File.write!(path, data)
    sha = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    %{path: path, subdir: "db", name: name, bytes: bytes, sha256: sha}
  end

  defp remote(server, rel), do: Path.join([server.root, "backups/kiln", rel])

  defp auth_attempts do
    receive do
      {:sftp_auth, method, user} -> [{method, user} | auth_attempts()]
    after
      0 -> []
    end
  end

  defp writes do
    receive do
      {:sftp_write, bytes} -> [bytes | writes()]
    after
      0 -> []
    end
  end

  describe "files" do
    test "a file goes in under its name and comes back whole, with a password", %{
      server: server,
      tmp_dir: tmp
    } do
      file = local_file(tmp, @db, 3 * 1024 * 1024 + 17)
      config = config(server)

      assert :ok = Sftp.put(config, file, [])
      assert File.read!(remote(server, "db/" <> @db)) == File.read!(file.path)
      assert File.ls!(remote(server, "db")) == [@db]

      # OpenSSH's limits: no write over 128 KiB, and reads loop on the
      # server's short answers.
      assert Enum.max(writes()) <= Files.io_bytes()

      assert {:ok, [%{subdir: "db", name: @db, bytes: bytes, mtime: %DateTime{}}]} =
               Sftp.list(config)

      assert bytes == file.bytes

      to = Path.join(tmp, "back")
      assert :ok = Sftp.get(config, %{subdir: "db", name: @db}, to)
      assert File.read!(to) == File.read!(file.path)

      assert :ok = Sftp.delete(config, %{subdir: "db", name: @db})
      assert :ok = Sftp.delete(config, %{subdir: "db", name: @db})
      assert {:ok, []} = Sftp.list(config)
    end

    test "with a private key and no password", %{server: server, tmp_dir: tmp} do
      config = config(server, %{secrets: %{"private_key" => server.client_key}})
      file = local_file(tmp, @db, 1000)

      assert :ok = Sftp.put(config, file, [])
      assert {:publickey, "kiln"} in auth_attempts()
    end

    test "the very file already there is not sent again", %{server: server, tmp_dir: tmp} do
      file = local_file(tmp, @db, 200_000)
      config = config(server)

      assert :ok = Sftp.put(config, file, [])
      _ = writes()
      assert {:ok, :already_present} = Sftp.put(config, file, [])
      assert writes() == []

      # Same size, other bytes: replaced.
      File.write!(file.path, :crypto.strong_rand_bytes(200_000))

      changed = %{
        file
        | sha256: :crypto.hash(:sha256, File.read!(file.path)) |> Base.encode16(case: :lower)
      }

      assert :ok = Sftp.put(config, changed, [])
      assert File.read!(remote(server, "db/" <> @db)) == File.read!(file.path)
    end

    test "only whole backup files are listed", %{server: server} do
      File.mkdir_p!(remote(server, "db"))
      File.write!(remote(server, "db/" <> @db), "x")
      File.write!(remote(server, "db/" <> @db <> ".partial"), "x")
      File.write!(remote(server, "db/notes.txt"), "x")
      File.mkdir_p!(remote(server, "db/kiln-db-20260102-000000.dump"))

      assert {:ok, [%{name: @db}]} = Sftp.list(config(server))
    end

    test "a missing subdirectory is an empty listing", %{server: server} do
      assert {:ok, []} = Sftp.list(config(server))
    end

    test "Test writes, reads back and removes its probe, and creates the path", %{server: server} do
      assert :ok = Sftp.test(config(server))
      assert File.ls!(remote(server, ".kiln-test")) == []
    end

    test "a hostile reference is refused before anything is contacted", %{server: server} do
      config = config(server)

      for {subdir, name} <- [{"../db", "x.dump"}, {"db", "../../etc/passwd"}, {"db", ".."}] do
        assert {:error, _} = Sftp.delete(config, %{subdir: subdir, name: name})
        assert {:error, _} = Sftp.get(config, %{subdir: subdir, name: name}, "/dev/null")
      end

      assert auth_attempts() == []
    end
  end

  describe "the host key" do
    test "unconfirmed, every call refuses before connecting", %{server: server, tmp_dir: tmp} do
      settings = %{Sftp.algorithm_key() => nil, Sftp.fingerprint_key() => nil}
      config = config(server, %{settings: settings})

      for result <- [
            Sftp.put(config, local_file(tmp, @db, 10), []),
            Sftp.list(config),
            Sftp.test(config)
          ] do
        assert {:error, {:permanent, message}} = result
        assert message =~ "confirm the server's host key first"
      end

      assert auth_attempts() == []
    end

    test "a changed key fails permanently, sends no credential and is recorded once", %{
      server: server
    } do
      alerts = Application.get_env(:kiln_cms, KilnCMS.Security.Alerts, [])
      Application.put_env(:kiln_cms, KilnCMS.Security.Alerts, Keyword.put(alerts, :enabled, true))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Security.Alerts, alerts) end)

      row = stored_destination(server)
      trusted = "SHA256:" <> String.duplicate("Q", 43)
      config = config(server, %{id: row.id, settings: %{Sftp.fingerprint_key() => trusted}})

      assert {:error, {:permanent, message}} = Sftp.list(config)
      assert message =~ "host key changed"
      assert message =~ server.fingerprint
      assert message =~ trusted

      # Nothing reached the server's password check or its key check.
      assert auth_attempts() == []

      # A retrying caller doesn't flood the log.
      assert {:error, {:permanent, _}} = Sftp.test(config)

      assert [event] = events(:backup_destination_host_key_mismatch)
      assert event.target_id == row.id
      assert event.actor_id == nil

      assert event.metadata == %{
               "name" => row.name,
               "kind" => "sftp",
               "offered_fingerprint" => server.fingerprint,
               "trusted_fingerprint" => trusted
             }

      # One alert, in the destination's own window (#3201).
      assert %{rows: [[1, notice, scope]]} =
               KilnCMS.Repo.query!(
                 "SELECT count(*)::int, max(notice::text), max(scope) FROM security_alert_dispatches WHERE kind = 'backup_host_key_changed' AND channel = 'platform'"
               )

      assert scope == "backup_destination:" <> row.id

      # The alert names the destination, and links to the instance log,
      # where its event is.
      assert Jason.decode!(notice) == %{"destination" => row.name}

      [raw] =
        Enum.filter(
          KilnCMS.Test.SecurityAlerts.dispatches(),
          &(&1["kind"] == "backup_host_key_changed")
        )

      dispatch = %KilnCMS.Security.AlertDispatch{
        id: raw["id"],
        scope: raw["scope"],
        kind: raw["kind"],
        channel: :platform,
        org_id: raw["org_id"],
        window_index: raw["window_index"],
        window_started_at: utc(raw["window_started_at"]),
        window_ends_at: utc(raw["window_ends_at"]),
        notice: raw["notice"],
        inserted_at: utc(raw["inserted_at"])
      }

      %{data: data} = KilnCMS.Security.Changes.DeliverAlert.build_plan(dispatch, :alert)
      assert data.console_url =~ "/editor/instance-security-log"
      assert data.destination == row.name

      assert KilnCMS.Security.AlertText.headline(KilnCMS.Security.AlertText.details(data)) ==
               "A backup server's host key changed: #{row.name}"
    end

    test "a mismatch refuses even when the connection would ask a person", %{server: server} do
      # As if a wrapper dropped `user_interaction: false`: the key callback
      # answers an error, never `false`, so OTP never reaches its prompt.
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, server.port, active: false)

      options = [
        user: ~c"kiln",
        password: String.to_charlist(SftpServer.password()),
        key_cb:
          {KilnCMS.Backups.Destination.Sftp.HostKey,
           mode: {:verify, server.type, "SHA256:" <> String.duplicate("Z", 43)},
           reply_to: self(),
           tag: make_ref()},
        silently_accept_hosts: false
      ]

      assert {:error, _reason} = :ssh.connect(socket, options, 5_000)
      assert auth_attempts() == []
    end

    test "a wrong password or an unknown key is permanent and says neither", %{server: server} do
      wrong = config(server, %{secrets: %{"password" => "wrong-password-xyz"}})
      assert {:error, {:permanent, message}} = Sftp.list(wrong)
      assert message == "the server refused the username and credentials"

      stranger = SftpServer.pem(SftpServer.ed25519())
      unknown = config(server, %{secrets: %{"private_key" => stranger}})
      assert {:error, {:permanent, message}} = Sftp.list(unknown)
      refute message =~ "PRIVATE"
    end

    test "the error Destination.call/4 answers carries no secret", %{server: server} do
      config = config(server, %{secrets: %{"password" => "wrong-password-xyz"}})
      assert {:error, reason} = Destination.call(config, :list, [], timeout: 20_000)
      refute inspect(reason) =~ "wrong-password-xyz"
    end
  end

  describe "where it may connect" do
    test "an unlisted loopback host is refused on every call", %{server: server} do
      Application.put_env(:kiln_cms, Sftp, private_hosts: [])

      assert {:error, {:permanent, message}} = Sftp.list(config(server))
      assert message =~ "BACKUP_SFTP_PRIVATE_HOSTS"
      assert auth_attempts() == []
    end

    test "a name that resolves somewhere private by now is refused", %{server: server} do
      safe_url = Application.get_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, [])

      resolver = fn _name -> {:ok, {:hostent, ~c"nas.example", [], :inet, 4, [{10, 0, 0, 9}]}} end

      Application.put_env(
        :kiln_cms,
        KilnCMS.Webhooks.SafeUrl,
        Keyword.merge(safe_url, resolve_dns: true, resolver: resolver)
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, safe_url) end)

      config = config(server, %{settings: %{"host" => "nas.example"}})
      assert {:error, {:permanent, message}} = Sftp.list(config)
      assert message =~ "private or loopback"
    end
  end

  describe "symbolic links" do
    test "a linked subdirectory is refused for list, put and delete", %{
      server: server,
      tmp_dir: tmp
    } do
      elsewhere = Path.join(server.root, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.mkdir_p!(remote(server, ""))
      File.ln_s!(elsewhere, remote(server, "db"))
      config = config(server)

      assert {:error, {:permanent, message}} = Sftp.list(config)
      assert message =~ "symbolic link"
      assert {:error, {:permanent, _}} = Sftp.put(config, local_file(tmp, @db, 10), [])
      assert {:error, {:permanent, _}} = Sftp.delete(config, %{subdir: "db", name: @db})

      # Reading a file, or aborting an upload, through the link is refused too.
      File.write!(Path.join(elsewhere, @db), "not yours")
      partial = Path.join(elsewhere, @db <> ".0123456789abcdef.partial")
      File.write!(partial, "not yours")

      assert {:error, {:permanent, message}} =
               Sftp.get(config, %{subdir: "db", name: @db}, Path.join(tmp, "x"))

      assert message =~ "symbolic link"

      upload = %{subdir: "db", name: @db, checkpoint: %{"token" => "0123456789abcdef"}}
      assert {:error, {:permanent, _}} = Sftp.abort_upload(config, upload, [])
      assert File.exists?(partial)
      refute File.exists?(Path.join(tmp, "x"))
    end

    test "a linked backup file is left out of the listing, and not read or deleted", %{
      server: server,
      tmp_dir: tmp
    } do
      target = Path.join(server.root, "secret.txt")
      File.write!(target, "not yours")
      File.mkdir_p!(remote(server, "db"))
      File.ln_s!(target, remote(server, "db/" <> @db))
      config = config(server)

      assert {:ok, []} = Sftp.list(config)

      assert {:error, {:permanent, _}} =
               Sftp.get(config, %{subdir: "db", name: @db}, Path.join(tmp, "x"))

      assert {:error, {:permanent, _}} = Sftp.delete(config, %{subdir: "db", name: @db})
      assert File.read!(target) == "not yours"
    end

    test "the operator's own base path may run through a link", %{server: server, tmp_dir: tmp} do
      real = Path.join(server.root, "volume1")
      File.mkdir_p!(real)
      File.ln_s!(real, Path.join(server.root, "backups"))

      assert :ok = Sftp.put(config(server), local_file(tmp, @db, 10), [])
      assert File.exists?(Path.join([real, "kiln/db", @db]))
    end
  end

  describe "the rename into place" do
    test "the file in place is removed only when the new one is still there, whole", %{
      server: server
    } do
      dir = remote(server, "db")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, @db), "old")
      File.write!(Path.join(dir, "x.partial"), "12345")

      target = %Target{
        host: "127.0.0.1",
        port: server.port,
        username: "kiln",
        segments: ["backups", "kiln"]
      }

      {:ok, credentials} =
        Credentials.from_secrets("kiln", %{"password" => SftpServer.password()})

      {:ok, session} = Session.open(target, credentials, {server.type, server.fingerprint})

      try do
        from = "/backups/kiln/db/x.partial"
        to = "/backups/kiln/db/" <> @db

        # Not the size it was written at: the old file stays.
        assert {:error, _} = Files.rename(session, from, to, 10, "db/" <> @db)
        assert File.read!(Path.join(dir, @db)) == "old"

        # Gone: the old file stays.
        assert {:error, _} =
                 Files.rename(session, "/backups/kiln/db/missing", to, 5, "db/" <> @db)

        assert File.read!(Path.join(dir, @db)) == "old"

        # Whole: replaced, on a server without posix-rename.
        assert :ok = Files.rename(session, from, to, 5, "db/" <> @db)
        assert File.read!(Path.join(dir, @db)) == "12345"
      after
        Session.close(session)
      end
    end
  end

  describe "a connection lost after the host key checked out" do
    @tag server: [drop_on_login: true]
    test "is worth retrying, and the recorded upload is kept", %{server: server, tmp_dir: tmp} do
      file = local_file(tmp, @db, 1000)
      token = "0123456789abcdef"
      dir = remote(server, "db")
      File.mkdir_p!(dir)
      partial = Path.join(dir, @db <> "." <> token <> ".partial")
      File.write!(partial, "half")

      test = self()

      resume = %Kiln.BackupDestination.Resume{
        checkpoint: %{"token" => token, "bytes_done" => 4},
        save: fn saved ->
          send(test, {:saved, saved})
          :ok
        end
      }

      assert {:error, reason} = Sftp.put(config(server), file, resume: resume)
      refute Destination.permanent?(reason)
      assert File.read!(partial) == "half"
    end
  end

  describe "the connection's lifetime" do
    @tag server: [write_delay_ms: 20]
    test "a call killed mid-upload leaves no connection open", %{server: server, tmp_dir: tmp} do
      before = active_connections()
      file = local_file(tmp, @db, 8 * 1024 * 1024)

      assert {:error, {:timeout, _call, 300}} =
               Destination.call(config(server), :put, [file, []], timeout: 300)

      assert eventually(fn -> active_connections() == before end)
    end

    test "a call killed during a stalled handshake leaves nothing open", %{server: server} do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      before = active_connections()
      config = config(server, %{settings: %{"port" => port}})

      caller = Task.async(fn -> Destination.call(config, :list, [], timeout: 300) end)
      {:ok, accepted} = :gen_tcp.accept(listen, 5_000)

      assert {:error, {:timeout, _call, 300}} = Task.await(caller, 5_000)

      # The guard closed the client's socket: the server side sees it go.
      assert eventually(fn -> match?({:error, :closed}, :gen_tcp.recv(accepted, 0, 100)) end)
      assert eventually(fn -> active_connections() == before end)
      :gen_tcp.close(listen)
    end

    test "neither the session nor the connection's state shows the private key", %{
      server: server
    } do
      pem = server.client_key
      target = %Target{host: "127.0.0.1", port: server.port, username: "kiln", segments: ["b"]}
      {:ok, credentials} = Credentials.from_secrets("kiln", %{"private_key" => pem})
      {:ok, key, _algorithms} = Credentials.private_key(pem)
      private_bytes = elem(key, 2)

      {:ok, session} = Session.open(target, credentials, {server.type, server.fingerprint})

      try do
        state =
          inspect(:sys.get_status(session.conn), limit: :infinity, printable_limit: :infinity)

        refute state =~ inspect(private_bytes, limit: :infinity)
        refute state =~ "PRIVATE KEY"
        refute inspect(session) =~ "PRIVATE"
        refute inspect(credentials) =~ "PRIVATE"
      after
        Session.close(session)
      end
    end
  end

  describe "a NAS share name with a space in the path (#3199)" do
    test "saves, then copies, lists, reads back, deletes and resumes there", %{
      server: server,
      tmp_dir: tmp
    } do
      admin = BackupSchedules.platform_admin()
      row = stored_destination(server, "/volume1/Backup Share/kiln")
      assert row.settings["path"] == "/volume1/Backup Share/kiln"

      {:ok, row} =
        Backups.trust_backup_destination_host_key(
          row,
          server.type,
          server.fingerprint,
          :scanned,
          %{previous_fingerprint: nil, scanned_for: Target.server(row.settings)},
          actor: admin
        )

      {:ok, config} = DestinationConfig.to_config(row)
      config = %{config | secrets: %{"password" => SftpServer.password()}}
      dir = Path.join([server.root, "volume1", "Backup Share", "kiln", "db"])

      file = local_file(tmp, @db, 300_000)
      assert :ok = Sftp.put(config, file, [])
      assert File.dir?(Path.join(server.root, "volume1/Backup Share"))
      assert File.read!(Path.join(dir, @db)) == File.read!(file.path)

      assert {:ok, [%{subdir: "db", name: @db, bytes: 300_000}]} = Sftp.list(config)

      to = Path.join(tmp, "back")
      assert :ok = Sftp.get(config, %{subdir: "db", name: @db}, to)
      assert File.read!(to) == File.read!(file.path)

      assert :ok = Sftp.delete(config, %{subdir: "db", name: @db})
      assert {:ok, []} = Sftp.list(config)

      # A resumed upload finds its partial under the spaced path and sends
      # only the rest.
      big = local_file(tmp, @db, 3 * 1024 * 1024 + 99)
      token = "0123456789abcdef"
      partial = Path.join(dir, Upload.token_partial(@db, token))
      File.write!(partial, binary_part(File.read!(big.path), 0, 2 * 1024 * 1024 + 7))
      _ = writes()

      resume = %Kiln.BackupDestination.Resume{
        checkpoint: %{"token" => token, "bytes_done" => 2 * 1024 * 1024 + 7},
        attempt: 2,
        save: fn _saved -> :ok end
      }

      assert :ok = Sftp.put(config, big, resume: resume)
      assert File.read!(Path.join(dir, @db)) == File.read!(big.path)
      refute File.exists?(partial)
      assert Enum.sum(writes()) == big.bytes - 2 * 1024 * 1024
    end

    test "a path saved with a trailing space is located without it", %{server: server} do
      row = stored_destination(server, "/a/kiln ")

      assert row.settings["path"] == "/a/kiln"
      assert {:sftp, "127.0.0.1", _port, "kiln", ["a", "kiln"]} = Target.location(row.settings)
    end

    test "climbing out of the path is still refused on save", %{server: server} do
      for path <- [
            "/backups/../etc",
            "/backups/./kiln",
            "/~/kiln",
            "/~root/kiln",
            "/backups\\..\\etc",
            "/backups/a\0b",
            "/backups/a\nb",
            "/backups/ lead",
            "/backups//kiln"
          ] do
        assert {:error, error} =
                 Backups.create_backup_destination(destination_attrs(server, path),
                   actor: BackupSchedules.platform_admin()
                 ),
               inspect(path)

        assert Exception.message(error) =~ "the path", inspect(path)
      end
    end
  end

  # A raw row's timestamps are naive UTC.
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp active_connections, do: Supervisor.count_children(:sshc_sup).active

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  defp stored_destination(server, path \\ nil) do
    Backups.create_backup_destination!(
      destination_attrs(server, path || "/backups/#{System.unique_integer([:positive])}"),
      actor: BackupSchedules.platform_admin()
    )
  end

  defp destination_attrs(server, path) do
    %{
      name: "NAS #{System.unique_integer([:positive])}",
      kind: "sftp",
      enabled: false,
      settings: %{
        "host" => "127.0.0.1",
        "port" => server.port,
        "username" => "kiln",
        "path" => path
      },
      secrets: %{"password" => SftpServer.password()}
    }
  end

  defp events(type) do
    Security.list_instance_events!(actor: BackupSchedules.platform_admin(), page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end
end
