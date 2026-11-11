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
  alias KilnCMS.Test.BackupChain

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
    assert {:error, _} = BackupChain.run()
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

      assert :ok = BackupChain.resume(stamp)

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

      assert :ok = BackupChain.resume(stamp)

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

      assert :ok = BackupChain.resume(stamp)

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

      assert :ok = BackupChain.resume(stamp)

      assert dump_count(tools) == 2
      assert {_, 0} = System.cmd("pg_restore", ["--list", dump], stderr_to_stdout: true)
      assert %{status: :succeeded} = hd(runs())
    end

    test "a dump whose bytes changed since it was recorded is rebuilt", %{base: base, dir: dir} do
      tools = stub_tools(base)
      %{stamp: stamp, dump: dump} = fail_at_part_3(dir, tools)

      flip_byte!(dump)

      assert :ok = BackupChain.resume(stamp)
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
      assert {:error, _} = BackupChain.resume(stamp)
      assert [%{status: :failed, stamp: ^stamp}] = runs()
      assert WorkState.exists?(WorkState.path(dir, stamp))

      File.rm!(tools.gate)
      assert :ok = BackupChain.resume(stamp)
      assert [%{status: :succeeded}] = runs()
      assert dump_count(tools) == 1
    end

    test "a resume whose start failed after re-opening the run carries on when retried", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp, work: work} = fail_at_part_3(dir, tools)

      # The start step's state write fails once, after `Recorder.reopen/2`.
      blocker = WorkState.file(work) <> ".partial"
      File.mkdir!(blocker)

      BackupChain.listen(fn ->
        {:ok, %{status: :started, chain: chain}} =
          Backups.request([resume: stamp], Backups.system())

        assert %{failure: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
        assert [%{status: :running, chain_id: ^chain}] = runs()

        File.rmdir!(blocker)
        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      assert [%{status: :succeeded, stamp: ^stamp}] = runs()
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

      assert :ok = BackupChain.resume(stamp)
      assert [%{status: :succeeded}] = runs()
    end

    test "Backups.enqueue(resume: stamp) starts a resume chain with the stamp in its args", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp} = fail_at_part_3(dir, tools)

      assert {:ok, %{status: :started, chain: chain}} = Backups.enqueue(resume: stamp)

      assert [%Oban.Job{args: args, queue: "backup_steps"}] =
               KilnCMS.Repo.all(
                 from(j in Oban.Job, where: j.queue == "backup_steps" and j.state == "available")
               )

      assert %{"chain" => ^chain, "step" => "start", "resume" => ^stamp} = args

      # A second resume of the same stamp is the one in flight.
      assert {:error, :in_flight} = Backups.enqueue(resume: stamp)
      # A plain backup queues behind it.
      assert {:ok, %{status: :queued, chain: ^chain}} = Backups.enqueue()
    end

    test "a legacy Worker job goes through the lock and resumes from its args", %{
      base: base,
      dir: dir
    } do
      tools = stub_tools(base)
      %{stamp: stamp} = fail_at_part_3(dir, tools)

      assert :ok =
               Worker.perform(%Oban.Job{id: 7, args: %{"trigger" => "manual", "resume" => stamp}})

      assert %{stamp: ^stamp, step: :start} = Backups.in_flight()
      BackupChain.drain()
      assert [%{status: :succeeded}] = runs()
    end
  end

  # -- resuming a run that failed off-site -----------------------------------

  describe "resuming a run that failed off-site (#2218)" do
    @describetag :pg_tools

    # An rclone that logs each call, fails every call while `fail` exists,
    # appends to part 2 while it uploads part 1 when `tamper` exists, and
    # rewrites the media sidecar while it uploads part 3 when `sidecar` exists,
    # and swaps part 2 for a symlink to its own bytes when `symlink` exists.
    defp stub_rclone(base, dir) do
      bin = Path.join(base, "bin")
      File.mkdir_p!(bin)

      gates =
        Map.new([:fail, :tamper, :sidecar, :symlink], &{&1, Path.join(base, "rclone.#{&1}")})

      log = Path.join(base, "rclone.log")

      write_exe(bin, "rclone", """
      echo "$*" >> "#{log}"
      [ -f "#{gates.fail}" ] && { echo "upload refused" >&2; exit 1; }
      case "$2" in
        *part01.tar.gz)
          p2="$(printf '%s' "$2" | sed 's/part01/part02/')"
          if [ -f "#{gates.tamper}" ]; then printf tampered >> "$p2"; fi
          if [ -f "#{gates.symlink}" ]; then
            mv "$p2" "$p2.moved" && ln -s "$p2.moved" "$p2"
          fi ;;
        *part03.tar.gz)
          if [ -f "#{gates.sidecar}" ]; then
            for f in "#{dir}"/media/kiln-media-*.sha256; do
              echo "#{String.duplicate("0", 64)}  kiln-media-x.part04.tar.gz" >> "$f"
            done
          fi ;;
      esac
      exit 0
      """)

      path = System.get_env("PATH")
      unless String.starts_with?(path, bin <> ":"), do: System.put_env("PATH", bin <> ":" <> path)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, "r2:kiln")
      )

      Map.put(gates, :log, log)
    end

    defp gate!(path), do: File.write!(path, "")

    defp rclone_calls(%{log: log}) do
      case File.read(log) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        _ -> []
      end
    end

    # A whole local backup that then failed off-site; returns what a resume uses.
    defp fail_offsite(base, dir, gate) do
      tools = stub_tools(base)
      rclone = stub_rclone(base, dir)
      gate!(Map.fetch!(rclone, gate))

      assert {:error, {:offsite, _}} = BackupChain.run()
      File.rm!(Map.fetch!(rclone, gate))

      assert [%{status: :failed} = run] = runs()
      assert Backups.work_state?(run.stamp)
      assert {:ok, _} = Backups.resumable_run(run.stamp)

      parts = Enum.map(1..3, &Path.join([dir, "media", Artifact.part_name(run.stamp, &1)]))

      %{
        tools: tools,
        rclone: rclone,
        run: run,
        dump: Path.join([dir, "db", "kiln-db-#{run.stamp}.dump"]),
        parts: parts
      }
    end

    test "after a failed upload, Resume copies off-site again and rebuilds nothing", %{
      base: base,
      dir: dir
    } do
      %{tools: tools, rclone: rclone, run: failed, dump: dump, parts: parts} =
        fail_offsite(base, dir, :fail)

      assert failed.error =~ "Off-site copy FAILED"
      first_round = length(rclone_calls(rclone))
      old = Map.new([dump | parts], &{&1, aged(&1)})

      assert :ok = BackupChain.resume(failed.stamp)

      assert dump_count(tools) == 1
      for {path, mtime} <- old, do: assert(mtime(path) == mtime, "#{path} was rewritten")

      # Every file went again: dump, 3 parts, 2 sidecars.
      assert length(rclone_calls(rclone)) == first_round + 6

      assert [run] = runs()
      assert run.id == failed.id
      assert run.status == :succeeded
      assert Enum.any?(run.log, &(&1.step == "resume" and &1.message =~ "Reused 3 of 3"))
      assert Manifest.read(dir).ok
      assert Manifest.read(dir).offsite == "r2:kiln"
      refute Backups.work_state?(failed.stamp)
    end

    test "after a refusal, Resume rebuilds only the file that changed", %{base: base, dir: dir} do
      %{tools: tools, rclone: rclone, run: failed, dump: dump, parts: [p1, p2, p3]} =
        fail_offsite(base, dir, :tamper)

      assert failed.error =~ "Off-site copy REFUSED for 1 file: #{Path.basename(p2)}"
      refute Enum.any?(rclone_calls(rclone), &(&1 =~ Path.basename(p2)))
      old = Map.new([dump, p1, p3], &{&1, aged(&1)})

      assert :ok = BackupChain.resume(failed.stamp)

      assert dump_count(tools) == 1
      for {path, mtime} <- old, do: assert(mtime(path) == mtime, "#{path} was rewritten")
      assert {_, 0} = System.cmd("tar", ["-tzf", p2], stderr_to_stdout: true)

      assert [run] = runs()
      assert run.status == :succeeded
      assert Enum.any?(run.log, &(&1.step == "resume" and &1.message =~ "Reused 2 of 3"))
      assert Enum.any?(rclone_calls(rclone), &(&1 =~ Path.basename(p2)))

      # The rebuilt part is the one the sidecar vouches for.
      {:ok, entries} =
        Checksum.parse_sidecar(
          Path.join([dir, "media", Artifact.sidecar_name(:media, run.stamp)])
        )

      {hex, _} = Enum.find(entries, fn {_, file} -> file == Path.basename(p2) end)
      assert :ok = Checksum.verify(p2, hex)
    end

    test "a part swapped for a symlink to the same bytes is refused, and Resume rebuilds it", %{
      base: base,
      dir: dir
    } do
      %{tools: tools, run: failed, parts: [p1, p2, p3]} = fail_offsite(base, dir, :symlink)

      assert failed.error =~
               "Off-site copy REFUSED for 1 file: #{Path.basename(p2)} (it is no longer a regular file)"

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(p2)
      old = Map.new([p1, p3], &{&1, aged(&1)})

      # Reuse applies the off-site gate's own check, so the symlink is not reused
      # (which would be refused again on every Resume) but rebuilt in its place.
      assert :ok = BackupChain.resume(failed.stamp)

      assert {:ok, %File.Stat{type: :regular}} = File.lstat(p2)
      for {path, mtime} <- old, do: assert(mtime(path) == mtime, "#{path} was rewritten")
      assert dump_count(tools) == 1
      assert [run] = runs()
      assert run.status == :succeeded
      assert Enum.any?(run.log, &(&1.step == "resume" and &1.message =~ "Reused 2 of 3"))
    end

    test "a refusal during a resume fails again, stays resumable, and the next converges", %{
      base: base,
      dir: dir
    } do
      %{rclone: rclone, run: failed} = fail_offsite(base, dir, :tamper)

      gate!(rclone.tamper)

      assert {:error, {:offsite, %{refused: [_]}}} =
               BackupChain.resume(failed.stamp)

      assert [%{status: :failed, error: "Off-site copy REFUSED" <> _}] = runs()
      assert {:ok, _} = Backups.resumable_run(failed.stamp)

      File.rm!(rclone.tamper)
      assert :ok = BackupChain.resume(failed.stamp)
      assert [%{status: :succeeded}] = runs()
    end

    test "a sidecar changed during the upload is rewritten on Resume, nothing rebuilt", %{
      base: base,
      dir: dir
    } do
      %{tools: tools, run: failed, dump: dump, parts: parts} = fail_offsite(base, dir, :sidecar)

      assert failed.error =~ "Off-site copy REFUSED for 1 file: kiln-media-#{failed.stamp}.sha256"
      old = Map.new([dump | parts], &{&1, aged(&1)})

      assert :ok = BackupChain.resume(failed.stamp)

      assert dump_count(tools) == 1
      for {path, mtime} <- old, do: assert(mtime(path) == mtime, "#{path} was rewritten")
      assert [%{status: :succeeded}] = runs()

      sidecar = Path.join([dir, "media", Artifact.sidecar_name(:media, failed.stamp)])
      assert {:ok, entries} = Checksum.parse_sidecar(sidecar)
      assert Enum.map(entries, &elem(&1, 1)) == Enum.map(parts, &Path.basename/1)
    end

    # Since #2218 every backup has a work directory, so a database-only one
    # resumes like any other.
    test "a database-only run that failed off-site resumes, reusing its dump", %{
      base: base,
      dir: dir
    } do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :media_dir, nil)
      )

      tools = stub_tools(base)
      rclone = stub_rclone(base, dir)
      gate!(rclone.fail)

      assert {:error, {:offsite, _}} = BackupChain.run()
      assert [%{status: :failed} = run] = runs()
      assert run.error =~ "Resume retries the off-site copy"
      assert {:ok, _} = Backups.resumable_run(run.stamp)

      File.rm!(rclone.fail)
      assert :ok = BackupChain.resume(run.stamp)
      assert dump_count(tools) == 1
      assert [%{status: :succeeded}] = runs()
      assert Manifest.read(dir).offsite == "r2:kiln"
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
        assert {:error, :invalid_stamp} = BackupChain.resume(bad)

        assert {:cancel, :invalid_stamp} =
                 Worker.perform(%Oban.Job{id: 1, args: %{"resume" => bad}})
      end

      # No fall-back to a fresh run, no Run, no manifest, no directories made.
      assert runs() == []
      refute File.exists?(Manifest.path(dir))
      refute File.exists?(dir)

      refute Enum.any?(
               KilnCMS.Repo.all(Oban.Job),
               &String.starts_with?(&1.worker, "KilnCMS.Backups.")
             )
    end

    test "WorkState.path/2 raises rather than build a path from a bad stamp" do
      for bad <- @forged do
        assert_raise ArgumentError, fn -> WorkState.path("/tmp/b", bad) end
      end
    end

    test "a stamp with no Run is refused", %{dir: dir} do
      File.mkdir_p!(WorkState.path(dir, "20260101-000000"))
      assert {:error, :no_such_run} = BackupChain.resume("20260101-000000")
      assert runs() == []
    end

    test "a succeeded run is refused and left alone", %{dir: dir} do
      run = open_run!(dir, "20260101-000000")
      Backups.finish_run!(run, %{}, actor: Backups.system())

      assert {:error, {:not_resumable, :succeeded}} =
               BackupChain.resume(run.stamp)

      assert {:error, {:not_resumable, :succeeded}} = Backups.enqueue(resume: run.stamp)
      assert %{status: :succeeded} = Backups.get_run!(run.id, actor: Backups.system())
    end

    test "a running run that is not stale is refused and left alone", %{dir: dir} do
      run = open_run!(dir, "20260101-000000")

      assert {:error, {:not_resumable, :running}} = BackupChain.resume(run.stamp)
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

      assert {:error, :no_state} = BackupChain.resume(run.stamp)
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

    test "a lock row that can't be read keeps everything (when unsure, keep)", %{dir: dir} do
      stamp = "20200106-000000"
      path = work_dir!(dir, stamp, 9)

      # The lock holds this stamp, but the row doesn't load.
      KilnCMS.Repo.query!(
        "INSERT INTO backup_locks (name, chain_id, stamp, step) VALUES ('backups', $1, $2, $3)",
        [Ecto.UUID.dump!(Ash.UUID.generate()), stamp, "not_a_step_#{System.unique_integer()}"]
      )

      assert {:error, _} = KilnCMS.Backups.Chain.fetch_held_stamp()
      assert Worker.sweep_work_dirs(dir) == []
      assert File.exists?(path)
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
