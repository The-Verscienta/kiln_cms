defmodule KilnCMS.Backups.Destination.S3ResumeTest do
  @moduledoc """
  An S3 destination's resumable upload as the off-site step drives it
  (#2221, #2223): `KilnCMS.Backups.Uploads.handle/3` before the put,
  `KilnCMS.Backups.Destination.call/4` for it, `Uploads.settle/3` after. The
  first attempt is cut off part-way; the second resumes from the recorded
  checkpoint, and what the store holds is the local file, byte for byte.
  """
  use KilnCMS.DataCase, async: true

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, Uploads}
  alias KilnCMS.Test.FakeS3

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    name = "kiln-db-20261117-000000.dump"
    path = Path.join(dir, name)
    body = :crypto.strong_rand_bytes(6_000)
    File.write!(path, body)

    put = %{
      path: path,
      subdir: "db",
      name: name,
      bytes: byte_size(body),
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }

    id = Ecto.UUID.generate()

    config = %Config{
      id: id,
      key: "dest:" <> id,
      kind: "s3",
      settings: %{
        "endpoint" => "https://s3.test",
        "region" => "auto",
        "bucket" => "kiln-backups",
        "path_style" => true
      },
      secrets: %{"access_key_id" => "AKIDRESUME", "secret_access_key" => "resume-secret"}
    }

    %{put: put, body: body, config: config}
  end

  defp attempt(config, put, attempt) do
    target = %{
      key: Destination.target_key(%{"key" => config.key, "source" => "db"}, config),
      owner: %{job_id: 4_242, attempt: attempt},
      deadline: System.monotonic_time(:millisecond) + 60_000,
      stamp: "20261117-000000",
      # The step's backup directory: only its steps take the upload over.
      dir_id: "0c9a3f2e-5b7d-4e1a-8c6f-2d4b6a8e0f13"
    }

    {:ok, opts, info} = Uploads.handle(config, put, target)
    assert Keyword.has_key?(opts, :resume)
    result = Destination.call(config, :put, [put, opts], deadline: target.deadline)
    :ok = Uploads.settle(config, info, result)
    result
  end

  test "an attempt cut off part-way is resumed by the next; the store holds the file", %{
    put: put,
    body: body,
    config: config
  } do
    fake = FakeS3.start()
    # Part 4 never gets through on attempt 1.
    FakeS3.inject(fake, :upload_part, :drop, skip: 3, times: 6)

    assert {:error, _transient} = attempt(config, put, 1)

    [row] = Backups.list_backup_uploads!(actor: Backups.system())
    assert row.status == :open
    assert row.bytes_done == 3 * 1024
    refute Map.has_key?(row.checkpoint, "secret_access_key")

    assert attempt(config, put, 2) == :ok

    assert FakeS3.object(fake, "db/#{put.name}").body == body
    assert FakeS3.count(fake, :create_multipart) == 1
    assert FakeS3.uploads(fake) == %{}
    assert [%{status: :completed}] = Backups.list_backup_uploads!(actor: Backups.system())
  end

  test "a permanent failure abandons the upload, and Kiln aborts it through the adapter", %{
    put: put,
    config: config
  } do
    fake = FakeS3.start()
    FakeS3.inject(fake, :upload_part, {:error, 403, "AccessDenied"}, skip: 2)

    assert {:error, {:permanent, message}} = attempt(config, put, 1)
    assert message =~ "AccessDenied"

    assert FakeS3.uploads(fake) == %{}
    assert FakeS3.count(fake, :abort_multipart) == 1
  end
end
