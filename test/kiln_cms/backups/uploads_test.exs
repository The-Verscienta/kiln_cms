defmodule KilnCMS.Backups.UploadsTest do
  @moduledoc """
  The core's side of resumable uploads (#2223, `KilnCMS.Backups.Uploads`):
  what `handle/3` hands an adapter before a put, what `settle/3` makes of
  its outcome, and what `sweep/4` aborts and purges afterwards. Driven
  through `KilnCMS.Test.BackupDestinations.ResumableFake` and the facade
  (`Destination.call/4`), as the off-site step drives them.

  `async: false`: one test registers an extra adapter through
  `Application.put_env/3`, which is VM-global.
  """
  use KilnCMS.DataCase, async: false

  alias Kiln.BackupDestination.{Config, Resume}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, Upload, Uploads}
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupDestinations.ResumableFake

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "kiln-db-20260101-000000.dump")
    body = :crypto.strong_rand_bytes(300)
    File.write!(source, body)

    put = %{
      path: source,
      subdir: "db",
      name: Path.basename(source),
      bytes: byte_size(body),
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }

    %{put: put, store: Path.join(tmp_dir, "store")}
  end

  defp config(store, settings \\ %{}) do
    id = Ecto.UUID.generate()

    %Config{
      id: id,
      key: "dest:" <> id,
      kind: "fake_resumable",
      settings:
        Map.merge(%{"store_dir" => store, "notify" => self(), "chunk_bytes" => 100}, settings),
      secrets: %{}
    }
  end

  defp key(config), do: Destination.target_key(%{"key" => config.key, "source" => "db"}, config)

  defp target(config, job_id, attempt) do
    %{
      key: key(config),
      owner: %{job_id: job_id, attempt: attempt},
      deadline: System.monotonic_time(:millisecond) + 60_000,
      stamp: "20260101-000000"
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 60_000

  # A put through the facade, settled, as the off-site step makes it.
  defp put!(config, put, target) do
    {:ok, opts, info} = Uploads.handle(config, put, target)
    result = Destination.call(config, :put, [put, opts], deadline: target.deadline)
    :ok = Uploads.settle(config, info, result)
    {result, info}
  end

  defp rows, do: Backups.list_backup_uploads!(actor: Backups.system())

  defp row(config, put) do
    Backups.get_open_backup_upload!(key(config), put.subdir, put.name, actor: Backups.system())
  end

  defp seed_row(config, put, attrs) do
    Ash.Seed.seed!(
      Upload,
      Map.merge(
        %{
          destination_key: key(config),
          destination_id: config.id,
          subdir: put.subdir,
          name: put.name,
          stamp: "20260101-000000",
          bytes: put.bytes,
          sha256: put.sha256,
          checkpoint: %{"upload_id" => "seeded", "offset" => 0},
          status: :open,
          owner_job_id: 10,
          owner_attempt: 1,
          attempts: 1,
          bytes_done: 0
        },
        attrs
      )
    )
  end

  defp touch!(row, at) do
    Repo.query!("UPDATE backup_uploads SET updated_at = $1 WHERE id = $2", [
      at,
      Ecto.UUID.dump!(row.id)
    ])
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  describe "handle/3" do
    test "the env destination, and an adapter without :resume, get only the deadline", %{
      put: put
    } do
      d = deadline()

      assert {:ok, [deadline: ^d], %{resumable?: false}} =
               Uploads.handle(config("/nowhere"), put, %{
                 key: nil,
                 owner: %{job_id: 1, attempt: 1},
                 deadline: d,
                 stamp: nil
               })

      fake = %Config{id: Ecto.UUID.generate(), key: "dest:x", kind: "fake", settings: %{}}

      assert {:ok, [deadline: ^d], %{resumable?: false}} =
               Uploads.handle(fake, put, %{target(fake, 1, 1) | deadline: d})
    end

    test "an adapter declaring :resume without abort_upload/3 is not resumed", %{put: put} do
      original = Application.get_env(:kiln_cms, Destination, [])
      on_exit(fn -> Application.put_env(:kiln_cms, Destination, original) end)

      Application.put_env(
        :kiln_cms,
        Destination,
        Keyword.update(original, :extra_adapters, [], &(&1 ++ [__MODULE__.NoAbort]))
      )

      config = %Config{id: Ecto.UUID.generate(), key: "dest:y", kind: "no_abort", settings: %{}}
      assert Destination.supports?(config, [:resume])
      refute Destination.resumable?(config)

      assert {:ok, opts, %{resumable?: false}} = Uploads.handle(config, put, target(config, 1, 1))
      refute Keyword.has_key?(opts, :resume)
    end

    test "a fresh upload is recorded on its first save, owned by the step", %{
      put: put,
      store: store
    } do
      config = config(store)

      assert {:ok, opts, info} = Uploads.handle(config, put, target(config, 5, 1))
      assert %Resume{checkpoint: nil, attempt: 1, save: save} = opts[:resume]
      assert info.resumed? == false
      assert rows() == []

      assert :ok = save.(%{upload_id: "u1", offset: 0})

      assert %Upload{owner_job_id: 5, owner_attempt: 1, checkpoint: checkpoint, bytes_done: 0} =
               row(config, put)

      # Stored as JSON: string keys, whatever the adapter saved.
      assert checkpoint == %{"upload_id" => "u1", "offset" => 0}

      assert :ok = save.(%{upload_id: "u1", offset: 100, bytes_done: 100})
      assert [%Upload{bytes_done: 100, checkpoint: %{"offset" => 100}}] = rows()
    end

    test "an open upload of the same file is claimed and its checkpoint handed back", %{
      put: put,
      store: store
    } do
      config = config(store)

      seed_row(config, put, %{
        checkpoint: %{"upload_id" => "u1", "offset" => 100},
        bytes_done: 100
      })

      assert {:ok, opts, info} = Uploads.handle(config, put, target(config, 10, 2))

      assert %Resume{checkpoint: %{"upload_id" => "u1", "offset" => 100}, attempt: 2} =
               opts[:resume]

      assert %{resumed?: true, resumed_from_bytes: 100} = info
      assert %Upload{owner_job_id: 10, owner_attempt: 2, attempts: 2} = row(config, put)
    end

    test "a later job claims too; the step it took over from is refused", %{
      put: put,
      store: store
    } do
      config = config(store)
      seed_row(config, put, %{owner_job_id: 10, owner_attempt: 4})

      assert {:ok, _opts, _info} = Uploads.handle(config, put, target(config, 11, 1))
      assert %Upload{owner_job_id: 11, owner_attempt: 1} = row(config, put)

      assert {:error, :superseded} = Uploads.handle(config, put, target(config, 10, 4))
      assert {:error, :superseded} = Uploads.handle(config, put, target(config, 9, 9))
    end

    test "a changed file abandons and aborts the old upload, then starts over", %{
      put: put,
      store: store
    } do
      config = config(store)
      old = seed_row(config, put, %{sha256: String.duplicate("b", 64)})

      assert {:ok, opts, %{resumed?: false}} = Uploads.handle(config, put, target(config, 10, 2))
      assert %Resume{checkpoint: nil, attempt: 1} = opts[:resume]
      assert_received {:resumable_fake, :abort, %{upload_id: "seeded"}, _pid}

      assert [%Upload{id: id, status: :aborted, checkpoint: nil, last_error: why}] = rows()
      assert id == old.id
      assert why =~ "changed"
    end

    test "a changed file whose abort fails is left abandoned for the sweep", %{
      put: put,
      store: store
    } do
      config = config(store, %{"abort_mode" => "fail"})
      seed_row(config, put, %{bytes: put.bytes + 1})

      assert {:ok, _opts, _info} = Uploads.handle(config, put, target(config, 10, 2))
      assert [%Upload{status: :abandoned}] = rows()
    end

    test "a changed file whose upload can't be abandoned is sent whole, recording nothing", %{
      put: put,
      store: store
    } do
      config = config(store)
      seed_row(config, put, %{sha256: String.duplicate("b", 64)})

      # The database refuses the abandon (and only it). Rolled back with the
      # test's sandbox transaction; this module is not async, so no other
      # test waits on the table meanwhile.
      Repo.query!("""
      CREATE FUNCTION pg_temp.refuse_abandon() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'abandon refused'; END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_abandon BEFORE UPDATE ON backup_uploads
      FOR EACH ROW WHEN (NEW.status = 'abandoned') EXECUTE FUNCTION pg_temp.refuse_abandon()
      """)

      assert {:ok, opts, %{resumable?: false}} =
               Uploads.handle(config, put, target(config, 10, 2))

      refute Keyword.has_key?(opts, :resume)
      assert Keyword.has_key?(opts, :deadline)
      refute_received {:resumable_fake, :abort, _, _}

      # The stale row is still the old file's, untouched by this put.
      assert [%Upload{status: :open, sha256: sha, checkpoint: %{"upload_id" => "seeded"}}] =
               rows()

      assert sha == String.duplicate("b", 64)
    end
  end

  describe "save" do
    test "a superseded owner's save is refused and leaves the checkpoint as it was", %{
      put: put,
      store: store
    } do
      config = config(store)
      seed_row(config, put, %{checkpoint: %{"upload_id" => "u1", "offset" => 100}})

      {:ok, old_opts, _} = Uploads.handle(config, put, target(config, 10, 2))
      {:ok, _new_opts, _} = Uploads.handle(config, put, target(config, 10, 3))

      assert {:error, :superseded} = old_opts[:resume].save.(%{upload_id: "u1", offset: 200})
      assert %Upload{checkpoint: %{"offset" => 100}, owner_attempt: 3} = row(config, put)
    end

    test "a lazy open that loses the race is superseded, and doesn't take the row", %{
      put: put,
      store: store
    } do
      config = config(store)

      {:ok, first, _} = Uploads.handle(config, put, target(config, 20, 1))
      {:ok, second, _} = Uploads.handle(config, put, target(config, 21, 1))

      assert :ok = second[:resume].save.(%{upload_id: "b", offset: 0})

      # In another process, so nothing cached of the first open helps it.
      assert {:error, :superseded} =
               Task.async(fn -> first[:resume].save.(%{upload_id: "a", offset: 0}) end)
               |> Task.await()

      assert [%Upload{owner_job_id: 21, checkpoint: %{"upload_id" => "b"}}] = rows()
    end

    test "a lazy open that races an older step's takes its row over and saves", %{
      put: put,
      store: store
    } do
      config = config(store)

      {:ok, older, _} = Uploads.handle(config, put, target(config, 20, 1))
      {:ok, newer, _} = Uploads.handle(config, put, target(config, 20, 2))

      assert :ok = older[:resume].save.(%{upload_id: "a", offset: 0})

      # The newer step's first save finds the older step's row: it claims it
      # and records its own progress there.
      assert :ok =
               Task.async(fn -> newer[:resume].save.(%{upload_id: "b", offset: 64}) end)
               |> Task.await()

      assert [
               %Upload{
                 owner_job_id: 20,
                 owner_attempt: 2,
                 attempts: 2,
                 checkpoint: %{"upload_id" => "b", "offset" => 64}
               }
             ] = rows()

      # And the older step is now refused.
      assert {:error, :superseded} = older[:resume].save.(%{upload_id: "a", offset: 128})
    end

    test "an oversized or non-JSON checkpoint is refused, and nothing is recorded", %{
      put: put,
      store: store
    } do
      config = config(store)
      {:ok, opts, _} = Uploads.handle(config, put, target(config, 1, 1))
      save = opts[:resume].save

      assert {:error, too_big} = save.(%{"blob" => String.duplicate("x", 9000)})
      assert too_big =~ "larger than 8192 bytes"
      assert {:error, not_json} = save.(%{"pid" => self()})
      assert not_json =~ "JSON"
      assert {:error, _not_a_map} = save.([1, 2])
      assert rows() == []
    end
  end

  describe "settle/3" do
    test "a put that arrives completes its upload", %{put: put, store: store} do
      config = config(store)

      assert {:ok, _info} = put!(config, put, target(config, 1, 1))
      assert [%Upload{status: :completed, checkpoint: nil}] = rows()

      assert File.read!(ResumableFake.stored_path(config.settings, "db", put.name)) ==
               File.read!(put.path)
    end

    test "a transient failure keeps the upload open with its error, and the next attempt " <>
           "resumes it",
         %{put: put, store: store} do
      config = config(store, %{"stop_after_chunks" => 2})

      assert {{:error, error}, _} = put!(config, put, target(config, 1, 1))
      assert error =~ "connection reset"

      assert [%Upload{status: :open, bytes_done: 200, last_error: last_error}] = rows()
      assert last_error =~ "connection reset"

      assert {:ok, %{resumed?: true, resumed_from_bytes: 200}} =
               put!(config, put, target(config, 1, 2))

      assert [%Upload{status: :completed}] = rows()
      stored = ResumableFake.stored_path(config.settings, "db", put.name)
      assert Base.encode16(:crypto.hash(:sha256, File.read!(stored)), case: :lower) == put.sha256
    end

    test "already present with no upload under way completes", %{put: put, store: store} do
      config = config(store, %{"present" => "true"})
      seed_row(config, put, %{checkpoint: nil, owner_job_id: 1})

      assert {{:ok, :already_present}, _} = put!(config, put, target(config, 1, 2))
      assert [%Upload{status: :completed}] = rows()
      refute_received {:resumable_fake, :abort, _, _}
    end

    test "already present with an upload under way aborts that upload", %{
      put: put,
      store: store
    } do
      config = config(store, %{"present" => "after_upload"})

      assert {{:ok, :already_present}, _} = put!(config, put, target(config, 1, 1))
      assert_received {:resumable_fake, :abort, %{name: name}, _pid}
      assert name == put.name
      assert [%Upload{status: :aborted, checkpoint: nil}] = rows()
    end

    test "a permanent failure abandons the upload and aborts it", %{put: put, store: store} do
      config = config(store, %{"permanent" => "true"})

      assert {{:error, {:permanent, "the bucket does not exist"}}, _} =
               put!(config, put, target(config, 1, 1))

      assert_received {:resumable_fake, :abort, _upload, _pid}
      assert [%Upload{status: :aborted, last_error: "the bucket does not exist"}] = rows()
    end

    test "a permanent failure whose abort fails stays abandoned; the next sweep aborts it", %{
      put: put,
      store: store
    } do
      failing = config(store, %{"permanent" => "true", "abort_mode" => "fail"})

      assert {{:error, {:permanent, _}}, _} = put!(failing, put, target(failing, 1, 1))
      assert [%Upload{status: :abandoned}] = rows()

      fixed = %{failing | settings: Map.delete(failing.settings, "abort_mode")}

      assert %{aborted: 1, failed: 0} = Uploads.sweep(fixed, key(failing), deadline())
      assert [%Upload{status: :aborted}] = rows()
    end

    test "a superseded put leaves the row to its new owner", %{put: put, store: store} do
      config = config(store)
      row = seed_row(config, put, %{owner_job_id: 30})

      info = %{
        resumable?: true,
        key: key(config),
        owner: %{job_id: 30, attempt: 1},
        put: put,
        deadline: deadline()
      }

      assert :ok = Uploads.settle(config, info, {:error, :superseded})
      assert [%Upload{status: :open, id: id}] = rows()
      assert id == row.id
    end
  end

  describe "sweep/4" do
    test "aborts abandoned uploads and ones idle for 4 days, not 3", %{put: put, store: store} do
      config = config(store)
      abandoned = seed_row(config, put, %{status: :abandoned, name: "kiln-db-a.dump"})
      idle = seed_row(config, put, %{name: "kiln-db-b.dump"})
      recent = seed_row(config, put, %{name: "kiln-db-c.dump"})
      touch!(idle, days_ago(4) |> DateTime.add(-60, :second))
      touch!(recent, days_ago(3))

      assert %{aborted: 2, failed: 0} = Uploads.sweep(config, key(config), deadline())

      statuses = Map.new(rows(), &{&1.id, &1.status})
      assert statuses[abandoned.id] == :aborted
      assert statuses[idle.id] == :aborted
      assert statuses[recent.id] == :open
    end

    test "touches only its own destination's uploads", %{put: put, store: store} do
      mine = config(store)
      other = config(store)
      seed_row(other, put, %{status: :abandoned})

      assert %{aborted: 0} = Uploads.sweep(mine, key(mine), deadline())
      assert [%Upload{status: :abandoned}] = rows()
      refute_received {:resumable_fake, :abort, _, _}
    end

    test "never touches the upload of the backup the lock holds", %{put: put, store: store} do
      config = config(store)
      seed_row(config, put, %{status: :abandoned, stamp: "20260101-000000"})

      Ash.Seed.seed!(KilnCMS.Backups.Lock, %{
        name: "backups",
        chain_id: Ecto.UUID.generate(),
        stamp: "20260101-000000"
      })

      assert %{aborted: 0} = Uploads.sweep(config, key(config), deadline())
      assert [%Upload{status: :abandoned}] = rows()
    end

    test "an abort that fails keeps the upload abandoned, with why", %{put: put, store: store} do
      config = config(store, %{"abort_mode" => "fail"})
      idle = seed_row(config, put, %{})
      touch!(idle, days_ago(5))

      assert %{aborted: 0, failed: 1} = Uploads.sweep(config, key(config), deadline())
      assert [%Upload{status: :abandoned, last_error: why}] = rows()
      assert why =~ "refused to abort"
    end

    test "an abort that hangs is cut at its own bound, not the step's deadline (#2950)", %{
      put: put,
      store: store
    } do
      config = config(store, %{"abort_mode" => "sleep"})
      seed_row(config, put, %{status: :abandoned})
      step_deadline = System.monotonic_time(:millisecond) + :timer.hours(1)
      started = System.monotonic_time(:millisecond)

      assert %{aborted: 0, failed: 1} =
               Uploads.sweep(config, key(config), step_deadline, abort_call_ms: 100)

      assert System.monotonic_time(:millisecond) - started < 5_000
      assert [%Upload{status: :abandoned, last_error: why}] = rows()
      assert why =~ "timed out"
    end

    test "purges closed uploads and a deleted destination's after 30 days, on any destination",
         %{put: put, store: store} do
      config = config(store)
      old_done = seed_row(config, put, %{status: :completed, name: "kiln-db-a.dump"})
      old_aborted = seed_row(config, put, %{status: :aborted, name: "kiln-db-b.dump"})
      orphan = seed_row(config, put, %{status: :abandoned, name: "kiln-db-c.dump"})
      new_done = seed_row(config, put, %{status: :completed, name: "kiln-db-d.dump"})
      for row <- [old_done, old_aborted, orphan], do: touch!(row, days_ago(31))

      # A non-resumable destination's sweep purges too.
      fake = %Config{id: Ecto.UUID.generate(), key: "dest:z", kind: "fake", settings: %{}}
      assert %{aborted: 0} = Uploads.sweep(fake, nil, deadline())
      assert [%Upload{id: id}] = rows()
      assert id == new_done.id
    end

    test "emits the swept event", %{store: store} do
      config = config(store)
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        ref,
        [:kiln_cms, :backups, :upload, :swept],
        fn _event, measurements, metadata, _ -> send(pid, {:swept, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      Uploads.sweep(config, key(config), deadline())
      dest = config.key
      assert_received {:swept, %{aborted: 0, failed: 0}, %{destination: ^dest}}
    end
  end

  describe "owner/1" do
    test "a step run by hand counts as attempt 0" do
      assert Uploads.owner(%{job_id: 3, attempt: 2}) == %{job_id: 3, attempt: 2}
      assert Uploads.owner(%{job_id: 3, attempt: nil}) == %{job_id: 3, attempt: 0}
      assert Uploads.owner(%{job_id: 3, attempt: 0}) == %{job_id: 3, attempt: 0}
    end
  end

  defmodule NoAbort do
    @moduledoc false
    use Kiln.BackupDestination

    @impl Kiln.BackupDestination
    def kind, do: "no_abort"
    @impl Kiln.BackupDestination
    def label, do: "No abort"
    @impl Kiln.BackupDestination
    def fields, do: []
    @impl Kiln.BackupDestination
    def supports, do: [:resume]
    @impl Kiln.BackupDestination
    def validate(_config), do: :ok
    @impl Kiln.BackupDestination
    def test(_config), do: :ok
    @impl Kiln.BackupDestination
    def put(_config, _file, _opts), do: :ok
    @impl Kiln.BackupDestination
    def list(_config), do: {:ok, []}
    @impl Kiln.BackupDestination
    def get(_config, _ref, _to), do: :ok
    @impl Kiln.BackupDestination
    def delete(_config, _ref), do: :ok
    @impl Kiln.BackupDestination
    def describe(_config), do: "no abort"
  end
end
