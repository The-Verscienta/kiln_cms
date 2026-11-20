defmodule KilnCMS.Backups.Destination.SftpResumeTest do
  @moduledoc """
  Resumable uploads to an SFTP destination (#2222, ADR 0068): the token
  saved before the temporary file exists, a resumed upload that sends only
  the rest once the server's copy checks out, starting over when it
  doesn't, a checkpoint that can't point anywhere, aborts, and which stale
  temporary files a later put may remove.

  `async: false`: it sets `BACKUP_SFTP_PRIVATE_HOSTS` (application env).
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Kiln.BackupDestination.{Config, Resume}
  alias KilnCMS.Backups.Destination.Sftp
  alias KilnCMS.Backups.Destination.Sftp.Upload
  alias KilnCMS.Test.SftpServer

  @name "kiln-db-20260101-000000.dump"
  @mib 1024 * 1024

  setup do
    server = SftpServer.start!()
    previous = Application.get_env(:kiln_cms, Sftp, [])
    Application.put_env(:kiln_cms, Sftp, Keyword.put(previous, :private_hosts, ["127.0.0.1"]))

    on_exit(fn ->
      Application.put_env(:kiln_cms, Sftp, previous)
      SftpServer.stop(server)
    end)

    %{server: server}
  end

  defp config(server) do
    %Config{
      id: nil,
      key: "dest:test",
      kind: "sftp",
      settings: %{
        "host" => "127.0.0.1",
        "port" => server.port,
        "username" => SftpServer.user(),
        "path" => "/backups",
        Sftp.algorithm_key() => server.type,
        Sftp.fingerprint_key() => server.fingerprint
      },
      secrets: %{"password" => SftpServer.password()}
    }
  end

  defp local_file(dir, bytes) do
    path = Path.join(dir, @name)
    data = :crypto.strong_rand_bytes(bytes)
    File.write!(path, data)

    %{
      path: path,
      subdir: "db",
      name: @name,
      bytes: bytes,
      sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    }
  end

  # A `Resume` whose saves are sent here, and which answers `answer`.
  defp resume(checkpoint, answer \\ :ok) do
    test = self()

    %Resume{
      checkpoint: checkpoint,
      attempt: 2,
      save: fn saved ->
        # The remote file must not exist yet at the first save.
        send(test, {:saved, saved})
        answer
      end
    }
  end

  defp saves do
    receive do
      {:saved, saved} -> [saved | saves()]
    after
      0 -> []
    end
  end

  defp written do
    receive do
      {:sftp_write, bytes} -> bytes + written()
    after
      0 -> 0
    end
  end

  defp dir(server), do: Path.join(server.root, "backups/db")

  test "a first attempt saves its token before the file exists, then lands whole", %{
    server: server,
    tmp_dir: tmp
  } do
    file = local_file(tmp, 3 * @mib)

    assert :ok = Sftp.put(config(server), file, resume: resume(nil))
    assert [%{"token" => token, "bytes_done" => 0} | _] = saves()
    assert Upload.token?(token)
    assert File.read!(Path.join(dir(server), @name)) == File.read!(file.path)
    assert File.ls!(dir(server)) == [@name]
  end

  test "a resumed upload sends only what the server doesn't hold", %{
    server: server,
    tmp_dir: tmp
  } do
    file = local_file(tmp, 5 * @mib + 123)
    token = "0123456789abcdef"
    File.mkdir_p!(dir(server))
    partial = Path.join(dir(server), Upload.token_partial(@name, token))
    File.write!(partial, binary_part(File.read!(file.path), 0, 3 * @mib + 500))
    _ = written()

    checkpoint = %{"token" => token, "bytes_done" => 3 * @mib + 500}
    assert :ok = Sftp.put(config(server), file, resume: resume(checkpoint))

    assert File.read!(Path.join(dir(server), @name)) == File.read!(file.path)
    refute File.exists?(partial)
    # From 3 MiB (rounded down), not from the start.
    assert written() == file.bytes - 3 * @mib
  end

  test "a copy whose last MiB differs starts over under a new token", %{
    server: server,
    tmp_dir: tmp
  } do
    file = local_file(tmp, 4 * @mib)
    token = "fedcba9876543210"
    File.mkdir_p!(dir(server))
    partial = Path.join(dir(server), Upload.token_partial(@name, token))
    File.write!(partial, :crypto.strong_rand_bytes(2 * @mib))

    checkpoint = %{"token" => token, "bytes_done" => 2 * @mib}
    assert :ok = Sftp.put(config(server), file, resume: resume(checkpoint))

    assert [%{"token" => fresh, "bytes_done" => 0} | _] = saves()
    assert fresh != token
    refute File.exists?(partial)
    assert File.read!(Path.join(dir(server), @name)) == File.read!(file.path)
  end

  test "a checkpoint naming a path is not followed: the upload starts over", %{
    server: server,
    tmp_dir: tmp
  } do
    file = local_file(tmp, 1000)
    outside = Path.join(server.root, "x")
    File.write!(outside, "keep")

    assert :ok =
             Sftp.put(config(server), file,
               resume: resume(%{"token" => "../../x", "bytes_done" => 10})
             )

    assert [%{"token" => token} | _] = saves()
    assert Upload.token?(token)
    assert File.read!(outside) == "keep"
  end

  test "a linked temporary file refuses the resume", %{server: server, tmp_dir: tmp} do
    file = local_file(tmp, 1000)
    token = "0123456789abcdef"
    File.mkdir_p!(dir(server))
    target = Path.join(server.root, "elsewhere")
    File.write!(target, "keep")
    File.ln_s!(target, Path.join(dir(server), Upload.token_partial(@name, token)))

    assert {:error, {:permanent, message}} =
             Sftp.put(config(server), file,
               resume: resume(%{"token" => token, "bytes_done" => 0})
             )

    assert message =~ "symbolic link"
    assert File.read!(target) == "keep"
  end

  test "superseded before the first byte: nothing is created", %{server: server, tmp_dir: tmp} do
    file = local_file(tmp, 1000)

    assert {:error, :superseded} =
             Sftp.put(config(server), file, resume: resume(nil, {:error, :superseded}))

    assert File.ls!(dir(server)) == []
  end

  test "stopping near the deadline saves the progress and says :deadline", %{
    server: server,
    tmp_dir: tmp
  } do
    file = local_file(tmp, 2 * @mib)
    deadline = System.monotonic_time(:millisecond) + 30_000

    assert {:error, :deadline} =
             Sftp.put(config(server), file, resume: resume(nil), deadline: deadline)

    assert [%{"token" => token} | _] = saves()
    assert File.exists?(Path.join(dir(server), Upload.token_partial(@name, token)))
  end

  test "abort removes the recorded temporary file; gone or tokenless is fine", %{
    server: server
  } do
    token = "0123456789abcdef"
    File.mkdir_p!(dir(server))
    partial = Path.join(dir(server), Upload.token_partial(@name, token))
    File.write!(partial, "half")
    config = config(server)

    upload = %{subdir: "db", name: @name, checkpoint: %{"token" => token}}
    assert :ok = Sftp.abort_upload(config, upload, [])
    refute File.exists?(partial)
    assert :ok = Sftp.abort_upload(config, upload, [])
    assert :ok = Sftp.abort_upload(config, %{upload | checkpoint: %{"token" => "../x"}}, [])
    assert :ok = Sftp.abort_upload(config, %{upload | checkpoint: nil}, [])
  end

  test "a later put removes a step's old temporary files, never a token's", %{
    server: server,
    tmp_dir: tmp
  } do
    File.mkdir_p!(dir(server))
    old = System.os_time(:second) - 2 * 3600

    step = Path.join(dir(server), "kiln-db-20250101-000000.dump.12-1.partial")
    token = Path.join(dir(server), "kiln-db-20250101-000000.dump.0123456789abcdef.partial")
    fresh = Path.join(dir(server), "kiln-db-20250102-000000.dump.partial")

    for path <- [step, token, fresh], do: File.write!(path, "x")
    File.touch!(step, old)
    File.touch!(token, old)

    assert :ok = Sftp.put(config(server), local_file(tmp, 100), [])

    refute File.exists?(step)
    assert File.exists?(token)
    assert File.exists?(fresh)
  end
end
