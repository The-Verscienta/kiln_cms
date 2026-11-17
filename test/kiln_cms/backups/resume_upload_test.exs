defmodule KilnCMS.Backups.ResumeUploadTest do
  @moduledoc """
  A resumable upload through the whole step chain (#2223): an off-site
  attempt that stops part-way, or whose step is killed, is continued by the
  next attempt from its last checkpoint, and a step that lost the upload to
  a newer one can't overwrite its progress.

  Driven through `KilnCMS.Test.BackupDestinations.ResumableFake`, stored as a
  destination. Its `"only_names"` keeps the chunked path to the first media
  part; every other file is copied whole.

  Runs real `pg_dump` and `tar` (`:pg_tools`). `async: false`: the
  `KilnCMS.Backups` application env is VM-global, and the steps run in
  processes of their own on the shared sandbox.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Destination, StepWorker, Upload}
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupChain
  alias KilnCMS.Test.BackupDestinations.ResumableFake

  @moduletag :capture_log
  @moduletag :pg_tools

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_resume_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(media)

    # Six 300-byte files with a 700-byte cap: three parts of two files each.
    for n <- 1..6, do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original,
        enabled: true,
        dir: dir,
        media_dir: media,
        keep_days: 14,
        media_part_bytes: 700,
        rclone_remote: nil
      )
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{base: base, dir: dir, store: Path.join(base, "store")}
  end

  # A stored ResumableFake with `settings`, prune off: the sweep must run
  # all the same.
  defp resumable!(store, settings) do
    KilnCMS.Test.BackupDestinations.destination!(%{
      name: "Resumable",
      kind: "fake_resumable",
      prune: false,
      secrets: %{},
      settings:
        Map.merge(
          %{
            "store_dir" => store,
            "chunk_bytes" => 256,
            "only_names" => "part01",
            "notify" => self() |> :erlang.pid_to_list() |> to_string()
          },
          settings
        )
    })
  end

  defp key(dest) do
    entry = %{"key" => "dest:" <> dest.id, "source" => "db", "id" => dest.id, "kind" => dest.kind}
    {:ok, config} = Destination.resolve(entry)
    Destination.target_key(entry, config)
  end

  defp run!, do: hd(Backups.list_runs!(actor: Backups.system()))
  defp lock, do: Backups.backup_lock!(actor: Backups.system())
  defp uploads, do: Backups.list_backup_uploads!(actor: Backups.system())

  defp current_job, do: Repo.get!(Oban.Job, lock().step_job_id)

  defp step_until(step, part) do
    row = lock()

    if to_string(row.step) == step and row.part == part do
      current_job()
    else
      %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      step_until(step, part)
    end
  end

  defp sha256(path), do: Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)

  defp part1(dir, stamp), do: Path.join([dir, "media", Artifact.part_name(stamp, 1)])

  defp dest_entry(run, dest), do: Enum.find(run.destinations, &(&1.key == "dest:" <> dest.id))

  test "an attempt that stops part-way is resumed by the next from its checkpoint", %{
    dir: dir,
    store: store
  } do
    dest = resumable!(store, %{"stop_after_chunks" => 2})

    # Left over from an earlier backup on the same destination: the sweep
    # aborts it once the destination is reached, prune off or not.
    stale =
      Ash.Seed.seed!(Upload, %{
        destination_key: key(dest),
        destination_id: dest.id,
        subdir: "media",
        name: "kiln-media-20250101-000000.part01.tar.gz",
        stamp: "20250101-000000",
        bytes: 10,
        sha256: String.duplicate("a", 64),
        checkpoint: %{"upload_id" => "stale", "offset" => 0},
        status: :abandoned,
        owner_job_id: 1,
        owner_attempt: 1,
        attempts: 1,
        bytes_done: 0
      })

    assert :ok = BackupChain.run()
    run = run!()

    assert run.status == :succeeded
    assert run.offsite_status == :complete
    assert %{status: :ok, files_ok: 6, files_total: 6} = dest_entry(run, dest)

    name = Artifact.part_name(run.stamp, 1)
    stored = ResumableFake.stored_path(%{"store_dir" => store}, "media", name)
    assert sha256(stored) == sha256(part1(dir, run.stamp))

    # Two chunks on attempt 1, saved after each; the rest on attempt 2.
    assert Enum.any?(
             run.log,
             &(&1.message =~ ~r/Resumed #{Regex.escape(name)} on Resumable at 512 of \d+ bytes/)
           )

    rows = Map.new(uploads(), &{&1.name, &1})
    assert %Upload{status: :completed, attempts: 2, owner_attempt: 2} = rows[name]
    assert %Upload{status: :aborted} = rows[stale.name]
    assert_received {:resumable_fake, :abort, %{upload_id: "stale"}, _pid}
  end

  test "a file already on the destination counts as sent, and the run completes", %{
    store: store
  } do
    dest = resumable!(store, %{"present" => "true"})

    assert :ok = BackupChain.run()
    run = run!()

    assert run.offsite_status == :complete
    assert %{status: :ok, files_ok: 6} = dest_entry(run, dest)

    assert Enum.any?(
             run.log,
             &(&1.message =~ "was already on Resumable with the same checksum; not sent again")
           )

    for artifact <- run.artifacts do
      assert get_in(artifact.destinations, ["dest:" <> dest.id, "status"]) == "ok"
    end
  end

  test "a step killed mid-upload leaves it open; the retry claims it and resumes", %{
    dir: dir,
    store: store
  } do
    dest = resumable!(store, %{"block_after_save" => "true"})

    {:ok, %{status: :started, chain: chain}} = Backups.request([], Backups.system())
    job = step_until("offsite", 1)
    stamp = lock().stamp
    name = Artifact.part_name(stamp, 1)

    # The step runs as Oban would run it, in a process of its own; the
    # adapter blocks right after its first chunk's save.
    step = Task.async(fn -> StepWorker.perform(job) end)
    Process.unlink(step.pid)
    assert_receive {:resumable_fake, :blocked, ^name, runner}, 30_000
    watch = Process.monitor(runner)

    # A fence kills the step's process; the adapter's call goes with it.
    Process.exit(step.pid, :kill)
    assert_receive {:DOWN, ^watch, :process, ^runner, _reason}, 5_000

    assert [%Upload{status: :open, bytes_done: 256, owner_job_id: owner}] =
             Enum.filter(uploads(), &(&1.name == name))

    assert owner == job.id

    BackupChain.listen(fn ->
      BackupChain.drain()
      assert :ok = BackupChain.settled(chain)
    end)

    run = run!()
    assert run.offsite_status == :complete
    assert %{status: :ok} = dest_entry(run, dest)

    stored = ResumableFake.stored_path(%{"store_dir" => store}, "media", name)
    assert sha256(stored) == sha256(part1(dir, stamp))
    assert [%Upload{status: :completed}] = Enum.filter(uploads(), &(&1.name == name))
    assert Enum.any?(run.log, &(&1.message =~ "Resumed #{name} on Resumable at 256"))
  end

  test "the step that took over owns the upload; the old one's late save is refused", %{
    dir: dir,
    store: store
  } do
    resumable!(store, %{"block_after_save" => "true"})

    {:ok, %{status: :started, chain: chain}} = Backups.request([], Backups.system())
    job = step_until("offsite", 1)
    stamp = lock().stamp
    name = Artifact.part_name(stamp, 1)

    old = Task.async(fn -> StepWorker.perform(job) end)
    Process.unlink(old.pid)
    assert_receive {:resumable_fake, :blocked, ^name, runner}, 30_000

    # The replacement (the next attempt of the same job) resumes and
    # finishes the upload while the old step is still inside its call.
    BackupChain.listen(fn ->
      BackupChain.drain()
      assert :ok = BackupChain.settled(chain)
    end)

    assert [%Upload{status: :completed, owner_attempt: attempt}] =
             Enum.filter(uploads(), &(&1.name == name))

    assert attempt >= 1

    # The old step's adapter carries on: its next save is refused, and it
    # stops without touching what the replacement stored.
    send(runner, :continue)
    assert_receive {:resumable_fake, :save_refused, %{name: ^name}, ^runner}, 5_000
    Task.shutdown(old, 5_000)

    assert [%Upload{status: :completed}] = Enum.filter(uploads(), &(&1.name == name))
    stored = ResumableFake.stored_path(%{"store_dir" => store}, "media", name)
    assert sha256(stored) == sha256(part1(dir, stamp))
    assert run!().offsite_status == :complete
  end
end
