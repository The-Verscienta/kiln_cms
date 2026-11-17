defmodule KilnCMS.Backups.DestinationCallersTest do
  @moduledoc """
  An adapter's process carries its caller in `$callers` (#2223), so a
  resumable upload's `save`, which writes to the database from inside the
  adapter's process, runs on the caller's sandbox connection. `async: true`
  on purpose: a shared sandbox would let any process in, and prove nothing.
  """
  use KilnCMS.DataCase, async: true

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, Upload, Uploads}

  @moduletag :tmp_dir

  test "a save made inside the adapter's process is recorded", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "kiln-db-20260101-000000.dump")
    body = :crypto.strong_rand_bytes(150)
    File.write!(source, body)

    put = %{
      path: source,
      subdir: "db",
      name: Path.basename(source),
      bytes: byte_size(body),
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }

    id = Ecto.UUID.generate()

    config = %Config{
      id: id,
      key: "dest:" <> id,
      kind: "fake_resumable",
      settings: %{"store_dir" => Path.join(tmp_dir, "store"), "chunk_bytes" => 100},
      secrets: %{}
    }

    deadline = System.monotonic_time(:millisecond) + 60_000
    key = Destination.target_key(%{"key" => config.key, "source" => "db"}, config)
    target = %{key: key, owner: %{job_id: 1, attempt: 1}, deadline: deadline, stamp: nil}

    {:ok, opts, info} = Uploads.handle(config, put, target)
    assert :ok = Destination.call(config, :put, [put, opts], deadline: deadline)
    assert :ok = Uploads.settle(config, info, :ok)

    assert [%Upload{status: :completed, bytes_done: 150, attempts: 1}] =
             Backups.list_backup_uploads!(actor: Backups.system())
  end
end
