defmodule KilnCMS.Backups.ResumeTest do
  @moduledoc """
  Resuming a failed backup (#2218): the durable state, the guards in front of it
  and the reuse rule behind it.

  The worker really runs `pg_dump` and `tar` (a stubbed dump proves nothing about
  a file `pg_restore` must read). Two stand-in executables sit ahead of the real
  ones on PATH: a `pg_dump` that counts its invocations and a `tar` that fails on
  a chosen part while a gate file exists. `async: false`: it changes the
  VM-wide PATH and `Application` env.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Manifest, Worker, WorkState}

  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkr_#{System.unique_integer([:positive])}")
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
        media_part_bytes: 700
      )
    )

    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{base: base, dir: dir, media: media}
  end

  # -- helpers ---------------------------------------------------------------

  defp runs, do: Backups.list_runs!(actor: Backups.system())

  defp backdate!(run, at) do
    {1, _} =
      KilnCMS.Repo.update_all(
        from(r in "backup_runs", where: r.id == type(^run.id, :binary_id)),
        set: [updated_at: at]
      )

    run
  end

  # A counting `pg_dump` and a `tar` that fails on part 3 while the gate exists.
  defp stub_tools(base) do
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    counter = Path.join(base, "pg_dump.count")
    gate = Path.join(base, "tar.gate")

    real_dump = System.find_executable("pg_dump")
    real_tar = System.find_executable("tar")

    write_exe(bin, "pg_dump", ~s|echo x >> "#{counter}"\nexec "#{real_dump}" "$@"\n|)

    write_exe(bin, "tar", """
    for a in "$@"; do
      case "$a" in
        *part03.tar.gz.partial*)
          if [ -f "#{gate}" ]; then echo "tar: stubbed failure" >&2; exit 2; fi ;;
      esac
    done
    exec "#{real_tar}" "$@"
    """)

    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    %{counter: counter, gate: gate}
  end

  defp write_exe(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp dump_count(%{counter: counter}) do
    case File.read(counter) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  # Same size, one byte different: a size check alone would call it intact.
  defp flip_byte!(path) do
    data = File.read!(path)
    mid = div(byte_size(data), 2)
    <<head::binary-size(^mid), byte, tail::binary>> = data
    File.write!(path, <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>)
    data
  end

  defp aged(path) do
    File.touch!(path, System.os_time(:second) - 7200)
    mtime(path)
  end

  defp mtime(path), do: File.stat!(path, time: :posix).mtime

  # Runs a backup that fails at part 3; returns what a resume builds on.
  defp fail_at_part_3(dir, tools) do
    File.write!(tools.gate, "")
    assert {:error, _} = Worker.run("manual")
    File.rm!(tools.gate)

    assert [run] = runs()
    assert run.status == :failed
    stamp = run.stamp
    work = WorkState.path(dir, stamp)
    assert WorkState.exists?(work)

    media_dir = Path.join(dir, "media")
    parts = Enum.map(1..3, &Path.join(media_dir, Artifact.part_name(stamp, &1)))

    %{
      run: run,
      stamp: stamp,
      work: work,
      dump: Path.join([dir, "db", "kiln-db-#{stamp}.dump"]),
      parts: parts
    }
  end

  # -- resume ----------------------------------------------------------------

  describe "resuming a run that failed at part 3" do
    @describetag :pg_tools

    test "reuses the dump and parts 1-2, builds part 3, and flips the manifest to ok", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)

      %{run: failed, stamp: stamp, work: work, dump: dump, parts: [p1, p2, p3]} =
        fail_at_part_3(dir, tools)

      # What the first attempt left: dump + parts 1-2 recorded, a failed manifest.
      assert dump_count(tools) == 1
      assert File.exists?(dump) and File.exists?(p1) and File.exists?(p2)
      refute File.exists?(p3)
      refute Manifest.read(dir).ok
      assert {:ok, state} = WorkState.read(work)
      assert %{"sha256" => _} = WorkState.dump(state)
      assert %{"sha256" => _} = WorkState.part(state, 1)
      assert %{"sha256" => _} = WorkState.part(state, 2)
      assert WorkState.part(state, 3) == nil

      old = Map.new([dump, p1, p2], &{&1, aged(&1)})

      assert :ok = Worker.run("ignored", nil, resume: stamp)

      # The dump was not re-run and nothing earlier was rewritten.
      assert dump_count(tools) == 1
      for {path, mtime} <- old, do: assert(mtime(path) == mtime, "#{path} was rewritten")
      assert File.exists?(p3)

      # Same Run, same stamp, original start; closed as succeeded.
      assert [run] = runs()
      assert run.id == failed.id
      assert run.status == :succeeded
      assert run.stamp == stamp
      assert run.started_at == failed.started_at
      assert run.finished_at && run.error == nil
      assert Enum.any?(run.log, &(&1.step == "resume" and &1.message =~ "Reused 2 of 3"))
      assert Enum.any?(run.log, &(&1.step == "dump" and &1.message =~ "reused"))
      assert [%{kind: :db}, %{name: name, parts: parts, verified: true}] = run.artifacts
      assert name == "kiln-media-" <> stamp
      assert length(parts) == 3

      # The manifest flips to ok:true, with the original start and trigger.
      manifest = Manifest.read(dir)
      assert manifest.ok
      assert manifest.error == nil
      assert manifest.trigger == "manual"

      assert DateTime.truncate(manifest.started_at, :second) ==
               DateTime.truncate(failed.started_at, :second)

      assert Manifest.verified?(manifest)

      # The finished set verifies against its own sidecar, and the work dir is gone.
      sidecar = Path.join([dir, "media", Artifact.sidecar_name(:media, stamp)])
      assert {:ok, entries} = Checksum.parse_sidecar(sidecar)
      assert length(entries) == 3

      for {hex, file} <- entries,
          do: assert(:ok = Checksum.verify(Path.join([dir, "media", file]), hex))

      refute File.exists?(work)
    end

    test "a part whose bytes no longer match its recorded hash is rebuilt", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp, parts: [p1, p2, _p3]} = fail_at_part_3(dir, tools)

      aged_p1 = aged(p1)
      flip_byte!(p2)

      assert :ok = Worker.run("manual", nil, resume: stamp)

      assert mtime(p1) == aged_p1
      assert {_, 0} = System.cmd("tar", ["-tzf", p2], stderr_to_stdout: true)

      # Rebuilt, and the finished set's sidecar vouches for it.
      {:ok, entries} =
        Checksum.parse_sidecar(Path.join([dir, "media", Artifact.sidecar_name(:media, stamp)]))

      {hex, _} = Enum.find(entries, fn {_, file} -> file == Path.basename(p2) end)
      assert :ok = Checksum.verify(p2, hex)
      assert %{status: :succeeded} = hd(runs())
    end

    test "a final-named part with garbage content and NO recorded hash is rebuilt", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp, parts: [_p1, _p2, p3]} = fail_at_part_3(dir, tools)

      # Exists under its final name, but the state never recorded it.
      File.write!(p3, "not a tarball, and nobody vouched for it")

      assert :ok = Worker.run("manual", nil, resume: stamp)

      assert {_, 0} = System.cmd("tar", ["-tzf", p3], stderr_to_stdout: true)
    end

    test "a dump with no recorded hash is rebuilt, not trusted for existing", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp, work: work, dump: dump} = fail_at_part_3(dir, tools)

      {:ok, state} = WorkState.read(work)
      :ok = WorkState.write(work, Map.put(state, "dump", nil))
      File.write!(dump, "garbage")

      assert :ok = Worker.run("manual", nil, resume: stamp)

      assert dump_count(tools) == 2
      assert {_, 0} = System.cmd("pg_restore", ["--list", dump], stderr_to_stdout: true)
      assert %{status: :succeeded} = hd(runs())
    end

    test "a dump whose bytes changed since it was recorded is rebuilt", %{base: base, dir: dir} do
      tools = stub_tools(base)
      %{stamp: stamp, dump: dump} = fail_at_part_3(dir, tools)

      flip_byte!(dump)

      assert :ok = Worker.run("manual", nil, resume: stamp)
      assert dump_count(tools) == 2
      assert {_, 0} = System.cmd("pg_restore", ["--list", dump], stderr_to_stdout: true)
    end

    test "a resumed run that fails again stays resumable, and the next resume converges", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp} = fail_at_part_3(dir, tools)

      File.write!(tools.gate, "")
      assert {:error, _} = Worker.run("manual", nil, resume: stamp)
      assert [%{status: :failed, stamp: ^stamp}] = runs()
      assert WorkState.exists?(WorkState.path(dir, stamp))

      File.rm!(tools.gate)
      assert :ok = Worker.run("manual", nil, resume: stamp)
      assert [%{status: :succeeded}] = runs()
      assert dump_count(tools) == 1
    end

    test "a stale-running run (its job is gone) can be resumed", %{base: base, dir: dir} do
      tools = stub_tools(base)
      %{run: failed, stamp: stamp} = fail_at_part_3(dir, tools)

      # What a killed node leaves: `running`, silent for hours.
      quiet = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)

      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "backup_runs", where: r.id == type(^failed.id, :binary_id)),
          set: [status: "running", finished_at: nil, started_at: quiet, updated_at: quiet]
        )

      assert :ok = Worker.run("manual", nil, resume: stamp)
      assert [%{status: :succeeded}] = runs()
    end

    test "Backups.enqueue(resume: stamp) queues a resume job with the stamp in its args", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp} = fail_at_part_3(dir, tools)

      assert {:ok, %Oban.Job{args: args, queue: "backups"}} = Backups.enqueue(resume: stamp)
      assert args == %{"trigger" => "manual", "resume" => stamp}

      # A plain backup is a different job (different args), so this one does not
      # block it and it does not resume anything.
      assert {:ok, %Oban.Job{args: plain}} = Backups.enqueue()
      refute Map.has_key?(plain, "resume")
    end

    test "the worker's perform/1 resumes from the job args", %{base: base, dir: dir} do
      tools = stub_tools(base)
      %{stamp: stamp} = fail_at_part_3(dir, tools)

      assert :ok =
               Worker.perform(%Oban.Job{id: 7, args: %{"trigger" => "manual", "resume" => stamp}})

      assert [%{status: :succeeded}] = runs()
    end
  end

  # -- refusals --------------------------------------------------------------

  describe "refusals" do
    @forged [
      "../../x",
      "../../20260101-000000",
      "20260101-000000/../../x",
      "20260101-000000\n",
      "2026010100000",
      "20261340-996199",
      "+0260101-000000",
      "",
      "/etc/passwd"
    ]

    test "a malformed or forged stamp is refused before any path is built or row read", %{
      dir: dir
    } do
      for bad <- @forged ++ [nil, 20_260_101, %{}, :stamp] do
        assert {:error, :invalid_stamp} = Backups.resumable_run(bad)
        assert {:error, :invalid_stamp} = Backups.enqueue(resume: bad)
        assert {:error, :invalid_stamp} = Worker.run("manual", nil, resume: bad)

        assert {:error, :invalid_stamp} =
                 Worker.perform(%Oban.Job{id: 1, args: %{"resume" => bad}})
      end

      # No fall-back to a fresh run, no Run, no manifest, no directories made.
      assert runs() == []
      refute File.exists?(Manifest.path(dir))
      refute File.exists?(dir)

      refute Enum.any?(
               KilnCMS.Repo.all(Oban.Job),
               &String.starts_with?(&1.worker, "KilnCMS.Backups.Worker")
             )
    end

    test "WorkState.path/2 raises rather than build a path from a bad stamp" do
      for bad <- @forged do
        assert_raise ArgumentError, fn -> WorkState.path("/tmp/b", bad) end
      end
    end

    test "a stamp with no Run is refused", %{dir: dir} do
      File.mkdir_p!(WorkState.path(dir, "20260101-000000"))
      assert {:error, :no_such_run} = Worker.run("manual", nil, resume: "20260101-000000")
      assert runs() == []
    end

    test "a succeeded run is refused and left alone", %{dir: dir} do
      run = open_run!(dir, "20260101-000000")
      Backups.finish_run!(run, %{}, actor: Backups.system())

      assert {:error, {:not_resumable, :succeeded}} =
               Worker.run("manual", nil, resume: run.stamp)

      assert {:error, {:not_resumable, :succeeded}} = Backups.enqueue(resume: run.stamp)
      assert %{status: :succeeded} = Backups.get_run!(run.id, actor: Backups.system())
    end

    test "a running run that is not stale is refused and left alone", %{dir: dir} do
      run = open_run!(dir, "20260101-000000")

      assert {:error, {:not_resumable, :running}} = Worker.run("manual", nil, resume: run.stamp)
      assert {:error, {:not_resumable, :running}} = Backups.enqueue(resume: run.stamp)

      untouched = Backups.get_run!(run.id, actor: Backups.system())
      assert untouched.status == :running
      assert untouched.log == run.log
    end

    test "a run that only LOOKS old (started long ago, written to just now) is not stale", %{
      dir: dir
    } do
      long_ago = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      run = open_run!(dir, "20260101-000000", started_at: long_ago)

      assert {:error, {:not_resumable, :running}} = Backups.resumable_run(run.stamp)
    end

    test "a failed run whose state file is gone is refused and NOT re-opened", %{dir: dir} do
      run = open_run!(dir, "20260101-000000")
      File.rm!(WorkState.file(WorkState.path(dir, run.stamp)))
      Backups.fail_run!(run, %{error: "boom"}, actor: Backups.system())

      assert {:error, :no_state} = Worker.run("manual", nil, resume: run.stamp)
      assert {:error, :no_state} = Backups.enqueue(resume: run.stamp)
      assert %{status: :failed} = Backups.get_run!(run.id, actor: Backups.system())
    end

    test "an imported (cron-made) run is never resumed", %{dir: dir} do
      stamp = "20260101-000000"
      File.mkdir_p!(WorkState.path(dir, stamp))
      :ok = WorkState.write(WorkState.path(dir, stamp), WorkState.new(stamp))

      Backups.import_run!(%{stamp: stamp, trigger: "cron", status: :failed, error: "x"},
        actor: Backups.system()
      )

      assert {:error, {:not_resumable, :failed}} = Backups.resumable_run(stamp)
    end

    test "a revoked grant refuses the resume" do
      assert {:error, _} =
               Backups.with_actor(nil, fn -> Backups.resumable_run("20260101-000000") end)
    end

    # A failed run with a state file, ready to be resumed.
    defp open_run!(dir, stamp, opts \\ []) do
      run =
        Backups.start_run!(
          %{
            stamp: stamp,
            trigger: "manual",
            started_at: Keyword.get(opts, :started_at, DateTime.utc_now())
          },
          actor: Backups.system()
        )

      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))
      run
    end
  end

  # -- resumability, as the UI asks ------------------------------------------

  describe "run_resumable?/2 and work_state?/1" do
    test "failed in-app runs, and stale running ones, are resumable; the rest are not", %{
      dir: dir
    } do
      failed = dir |> open_run!("20260101-000001") |> fail!()
      running = open_run!(dir, "20260101-000002")
      done = dir |> open_run!("20260101-000003") |> finish!()

      quiet_at = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)
      stale = dir |> open_run!("20260101-000004", started_at: quiet_at) |> backdate!(quiet_at)

      assert Backups.run_resumable?(failed)
      refute Backups.run_resumable?(running)
      refute Backups.run_resumable?(done)
      assert Backups.run_resumable?(Backups.get_run!(stale.id, actor: Backups.system()))

      assert Backups.work_state?("20260101-000001")
      refute Backups.work_state?("20260101-009999")
      refute Backups.work_state?("../../x")
    end

    defp fail!(run), do: Backups.fail_run!(run, %{error: "boom"}, actor: Backups.system())
    defp finish!(run), do: Backups.finish_run!(run, %{}, actor: Backups.system())
  end

  # -- the work-directory sweep ----------------------------------------------

  describe "Worker.sweep_work_dirs/2" do
    test "removes stamp-named work dirs older than three days, and only those", %{dir: dir} do
      old = work_dir!(dir, "20200101-000000", 4)
      recent = work_dir!(dir, "20200102-000000", 2)
      running_run = work_dir!(dir, "20200103-000000", 5)
      not_a_stamp = work_dir!(dir, "notes", 9)

      Backups.start_run!(%{stamp: "20200103-000000", trigger: "manual"}, actor: Backups.system())

      assert Worker.sweep_work_dirs(dir) == ["20200101-000000"]

      refute File.exists?(old)
      assert File.exists?(recent)
      assert File.exists?(running_run), "a running run's work dir is never swept"
      assert File.exists?(not_a_stamp), "only directories named like a stamp are touched"
    end

    test "an old work dir whose Run FAILED is swept (nothing is resuming it)", %{dir: dir} do
      path = work_dir!(dir, "20200104-000000", 4)

      run =
        Backups.start_run!(%{stamp: "20200104-000000", trigger: "manual"},
          actor: Backups.system()
        )

      Backups.fail_run!(run, %{error: "x"}, actor: Backups.system())

      assert Worker.sweep_work_dirs(dir) == ["20200104-000000"]
      refute File.exists?(path)
    end

    test "a revoked grant keeps everything (when unsure, keep)", %{dir: dir} do
      path = work_dir!(dir, "20200105-000000", 9)

      assert Backups.with_actor(nil, fn -> Worker.sweep_work_dirs(dir) end) == []
      assert File.exists?(path)
    end

    # Files first, then the directory's own mtime last: creating state.json
    # bumps it.
    defp work_dir!(dir, name, days_old) do
      path = Path.join([dir, ".work", name])
      File.mkdir_p!(path)
      state = Path.join(path, "state.json")
      File.write!(state, "{}")
      old = System.os_time(:second) - days_old * 86_400
      File.touch!(state, old)
      File.touch!(path, old)
      path
    end
  end
end
