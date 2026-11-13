defmodule KilnCMS.Scripts.BackupScriptImportTest do
  @moduledoc """
  A media part set written by `scripts/backup.sh` (#2218) is read by the app as
  its own: `Importer` records it as one run with one media artifact whose parts
  match the sidecar and the manifest, a set with a missing part imports as
  failed, and a run killed outright (no EXIT trap) leaves an in-progress marker
  that keeps its stamp from importing as a succeeded, smaller set.

  A killed run recovers with no one stepping in (#2478): its stamp is recorded
  as an interrupted, failed run once it has been quiet for 3 hours, and
  `prune` removes the marker once every file of the stamp is 12 hours old.
  While the run lives, a background heartbeat keeps its partials fresh, so a
  slow run is never taken for a dead one. "Aging" a stamp here means setting
  its files' mtimes back; the heartbeat's `sleep` is stubbed to 50 ms.

  `pg_dump` / `pg_restore` are stubbed on `PATH`; tar and the rest are real.
  Sparse files keep the 16 MB parts cheap. The script is started through a
  wrapper that exports its real PID (`KILN_TEST_SCRIPT_PID`), so a stub kills
  the script itself whichever subshell it runs in. `async: false`: it spawns
  the script and shares the tmp namespace with the other backup tests.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, Checksum, Importer, Manifest}

  @moduletag :capture_log

  @mb 1_048_576
  @script Path.expand("../../scripts/backup.sh", __DIR__)
  @restore Path.expand("../../scripts/restore.sh", __DIR__)
  @interrupted "Interrupted: the backup stopped before it finished and left .partial files behind"
  @real_sleep System.find_executable("sleep")

  tools = ["bash", "tar", "gzip", "find", "stat", "xargs", "mktemp", "head"]
  missing = Enum.reject(tools, &System.find_executable/1)
  sha_tool? = System.find_executable("sha256sum") || System.find_executable("shasum")

  cond do
    missing != [] -> @moduletag skip: "needs #{Enum.join(missing, ", ")} on PATH"
    !sha_tool? -> @moduletag skip: "needs sha256sum or shasum on PATH"
    true -> :ok
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "kiln_backup_import_#{System.unique_integer([:positive])}")
    media = Path.join(tmp, "uploads")
    backups = Path.join(tmp, "backups")
    bin = Path.join(tmp, "bin")
    scratch = Path.join(tmp, "scratch")
    for dir <- [media, backups, bin, scratch], do: File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    for n <- 1..3, do: sparse!(Path.join(media, "f#{n}.bin"), 9 * @mb)

    stub!(bin, "pg_dump", """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in --file=*) printf 'PGDMP pretend dump' > "${a#--file=}" ;; esac
    done
    """)

    stub!(bin, "pg_restore", "#!/bin/sh\nexit 0\n")
    # A fast heartbeat: every 50 ms instead of every 5 minutes.
    stub!(bin, "sleep", "#!/bin/sh\nexec #{@real_sleep} 0.05\n")

    %{tmp: tmp, media: media, backups: backups, bin: bin, scratch: scratch}
  end

  test "a cron part set imports as one succeeded run; a set missing a part as failed", ctx do
    assert {_, 0} = backup(ctx)
    stamp = only_stamp(ctx)

    manifest = Manifest.read(ctx.backups)
    assert Manifest.verified?(manifest)

    on_disk =
      ctx.backups |> Path.join("{db,media}/kiln-*-#{stamp}*.{dump,tar.gz}") |> Path.wildcard()

    assert Manifest.total_bytes(manifest) ==
             on_disk |> Enum.map(&File.stat!(&1).size) |> Enum.sum()

    assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)
    run = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
    assert run.status == :succeeded
    assert run.trigger == "cron"

    assert [media] = Enum.filter(run.artifacts, &(&1.kind == :media))

    {:ok, sidecar} =
      Checksum.parse_sidecar(Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256"))

    assert length(sidecar) == 3

    assert Enum.map(media.parts, &{&1["sha256"], &1["name"]}) == sidecar

    manifest_parts =
      for %{kind: "media"} = a <- manifest.artifacts, do: {a.sha256, Path.basename(a.path)}

    assert manifest_parts == sidecar

    # A second run, a different stamp (stamps have one-second resolution).
    Process.sleep(1100)
    assert {_, 0} = backup(ctx)
    second = ctx |> stamps() |> Enum.reject(&(&1 == stamp)) |> hd()
    File.rm!(Path.join(ctx.backups, "media/kiln-media-#{second}.part02.tar.gz"))
    age!(ctx, second, 20)

    assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)

    assert %{status: :failed, error: "incomplete media set: missing part02"} =
             Backups.get_run_by_stamp!(second, actor: Backups.system())
  end

  describe "a run killed outright (#2478)" do
    test "is held back while fresh, recorded as interrupted after 3 h, and its marker " <>
           "pruned after 12 h",
         ctx do
      kill_at_part02!(ctx)

      assert {out, status} = backup(ctx)
      assert status != 0
      refute out =~ "Terminated"

      stamp = only_stamp(ctx)
      part01 = Path.join(ctx.backups, "media/kiln-media-#{stamp}.part01.tar.gz")
      marker = marker(ctx, stamp)
      dump = Path.join(ctx.backups, "db/kiln-db-#{stamp}.dump")
      assert File.exists?(part01)
      assert File.exists?(marker)

      # A prune right away keeps everything.
      assert {_, 0} = run_script(ctx, @script, ["prune"])
      assert Enum.all?([part01, marker, dump], &File.exists?/1)

      # Old enough to settle, too young to be called dead: pending.
      age!(ctx, stamp, 20)
      assert {:ok, %{imported: 0, pending: 1}} = Importer.run(ctx.backups)
      assert {:ok, nil} = Backups.get_run_by_stamp(stamp, actor: Backups.system())
      refuses!(ctx, stamp, part01)

      # Four hours quiet: a failed run, with what it left.
      age!(ctx, stamp, 4 * 60)
      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)
      run = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert %{status: :failed, error: @interrupted, components: [:db, :media]} = run

      part_names = for %{kind: :media, parts: parts} <- run.artifacts, p <- parts, do: p["name"]
      assert part_names == ["kiln-media-#{stamp}.part01.tar.gz"]

      refuses!(ctx, stamp, part01)

      # Thirteen hours: the next prune removes the marker, and only the marker.
      age!(ctx, stamp, 13 * 60)
      assert {out, 0} = run_script(ctx, @script, ["prune"])
      assert out =~ marker
      refute File.exists?(marker)
      assert File.exists?(part01)
      assert File.exists?(dump)

      # The missing sidecar still gives the set away, and the row stays.
      assert {out, status} = run_script(ctx, @script, ["verify"])
      assert status != 0
      assert out =~ "has parts but no sidecar"
      assert {:ok, %{imported: 0}} = Importer.run(ctx.backups)

      assert %{status: :failed, error: @interrupted} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())
    end

    test "end to end, with no one stepping in: the marker sync records it, the next " <>
           "cron run prunes it",
         ctx do
      kill_at_part02!(ctx)
      assert {_, status} = backup(ctx)
      assert status != 0
      killed = only_stamp(ctx)

      age!(ctx, killed, 4 * 60)
      assert {:ok, _} = Chain.sync_last_good(ctx.backups)

      assert %{status: :failed, error: @interrupted} =
               Backups.get_run_by_stamp!(killed, actor: Backups.system())

      age!(ctx, killed, 13 * 60)
      File.rm!(Path.join(ctx.bin, "tar"))
      # A new stamp (stamps have one-second resolution).
      Process.sleep(1100)
      assert {out, 0} = backup(ctx)
      assert out =~ marker(ctx, killed)
      refute File.exists?(marker(ctx, killed))

      [next] = ctx |> stamps() |> Enum.reject(&(&1 == killed))
      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)
      assert %{status: :succeeded} = Backups.get_run_by_stamp!(next, actor: Backups.system())
      assert {_, 0} = run_script(ctx, @script, ["verify"])

      assert [{^killed, :failed}, {^next, :succeeded}] =
               Backups.list_runs!(actor: Backups.system())
               |> Enum.map(&{&1.stamp, &1.status})
               |> Enum.sort()
    end

    test "the evidence lost (no import within 12 h): the leftovers import as what they are",
         ctx do
      kill_at_part02!(ctx)
      assert {_, status} = backup(ctx)
      assert status != 0
      stamp = only_stamp(ctx)
      part01 = Path.join(ctx.backups, "media/kiln-media-#{stamp}.part01.tar.gz")

      age!(ctx, stamp, 13 * 60)
      assert {_, 0} = run_script(ctx, @script, ["prune"])
      refute File.exists?(marker(ctx, stamp))

      assert {out, status} = run_script(ctx, @restore, ["media", part01])
      assert status != 0
      assert out =~ "has no sidecar, so it is probably incomplete"
      refute File.exists?(Path.join(ctx.tmp, "restored"))

      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)

      assert %{status: :failed, error: "incomplete media set: parts but no sidecar"} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())
    end

    test "a single archive killed before its sidecar: interrupted with the marker; " <>
           "succeeded once the marker is lost",
         ctx do
      one_part_media!(ctx)
      kill_on_du!(ctx, "kiln-media-*.tar.gz")

      assert {_, status} = backup(ctx)
      assert status != 0
      first = only_stamp(ctx)
      assert File.exists?(Path.join(ctx.backups, "media/kiln-media-#{first}.tar.gz"))
      assert File.exists?(marker(ctx, first))

      age!(ctx, first, 4 * 60)
      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)

      assert %{status: :failed, error: @interrupted} =
               Backups.get_run_by_stamp!(first, actor: Backups.system())

      # The same kill, but nothing reads the stamp before prune: the archive
      # passed `tar -tzf` before its rename, so it imports as the backup it is.
      Process.sleep(1100)
      assert {_, status} = backup(ctx)
      assert status != 0
      [second] = ctx |> stamps() |> Enum.reject(&(&1 == first))
      age!(ctx, second, 13 * 60)
      assert {_, 0} = run_script(ctx, @script, ["prune"])
      refute File.exists?(marker(ctx, second))

      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)
      assert %{status: :succeeded} = Backups.get_run_by_stamp!(second, actor: Backups.system())
    end

    test "killed inside pg_dump: only partials, a failed run with no artifacts, pruned at 13 h",
         ctx do
      stub!(ctx.bin, "pg_dump", """
      #!/bin/sh
      for a in "$@"; do
        case "$a" in --file=*) printf 'PGDMP half a dump' > "${a#--file=}" ;; esac
      done
      kill -KILL "$KILN_TEST_SCRIPT_PID"
      """)

      assert {_, status} = backup(ctx)
      assert status != 0

      assert [dump_partial] = Path.wildcard(Path.join(ctx.backups, "db/kiln-db-*.dump.partial"))
      [_, stamp] = Regex.run(~r/kiln-db-(\d{8}-\d{6})\.dump\.partial\z/, dump_partial)
      # `all` opens the media marker before the dump.
      assert File.exists?(marker(ctx, stamp))

      age!(ctx, stamp, 4 * 60)
      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)

      assert %{status: :failed, error: @interrupted, artifacts: [], components: [:db, :media]} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      age!(ctx, stamp, 13 * 60)
      assert {_, 0} = run_script(ctx, @script, ["prune"])
      refute File.exists?(dump_partial)
      refute File.exists?(marker(ctx, stamp))
    end

    test "killed after the dump, before media: interrupted, never a succeeded db-only backup",
         ctx do
      kill_on_du!(ctx, "kiln-db-*.dump")

      assert {_, status} = backup(ctx)
      assert status != 0
      stamp = only_stamp(ctx)
      assert File.exists?(marker(ctx, stamp))
      assert Path.wildcard(Path.join(ctx.backups, "media/*.tar.gz")) == []

      age!(ctx, stamp, 4 * 60)
      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)

      assert %{status: :failed, error: @interrupted, components: [:db, :media]} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())
    end

    test "the orphaned heartbeat does not keep the marker fresh", ctx do
      kill_at_part02!(ctx)
      assert {_, status} = backup(ctx)
      assert status != 0
      stamp = only_stamp(ctx)

      # Two intervals for the orphan to notice, then twenty for it to betray
      # itself.
      Process.sleep(100)
      age!(ctx, stamp, 4 * 60)
      aged = File.stat!(marker(ctx, stamp), time: :posix).mtime
      Process.sleep(1000)
      assert File.stat!(marker(ctx, stamp), time: :posix).mtime == aged
    end
  end

  describe "a live run is never taken for a dead one (#2478)" do
    test "a run stalled for hours keeps its partials fresh; it is pending, then succeeds",
         ctx do
      real_tar = System.find_executable("tar")
      fifo = Path.join(ctx.tmp, "release")
      flag = Path.join(ctx.tmp, "stalled")
      {_, 0} = System.cmd("mkfifo", [fifo])
      # A failed assertion must not leave the script blocked for ever.
      on_exit(fn -> release(fifo) end)

      # The first archive check (the tar probe) blocks until the test
      # releases it.
      stub!(ctx.bin, "tar", """
      #!/bin/sh
      case "$*" in
        *-tzf*) if [ ! -e "#{flag}" ]; then : > "#{flag}"; cat "#{fifo}" > /dev/null; fi ;;
      esac
      exec #{real_tar} "$@"
      """)

      task = Task.async(fn -> backup(ctx) end)
      wait_until(fn -> File.exists?(flag) end)
      stamp = only_stamp(ctx)

      # Every file of the stamp, as if the stall had lasted four hours.
      age!(ctx, stamp, 4 * 60)
      wait_until(fn -> fresh?(marker(ctx, stamp)) end)

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run(ctx.backups)
      assert {:ok, nil} = Backups.get_run_by_stamp(stamp, actor: Backups.system())

      release(fifo)
      assert {_, 0} = Task.await(task, 60_000)

      assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)
      assert %{status: :succeeded} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
    end

    test "a normal run returns at once, prints no job notice, and leaves no sleep behind", ctx do
      pids = Path.join(ctx.tmp, "sleeps")

      # A heartbeat sleep long enough to outlive the script if nothing stops it.
      stub!(ctx.bin, "sleep", """
      #!/bin/sh
      echo $$ >> "#{pids}"
      exec #{@real_sleep} 30
      """)

      {elapsed, {out, 0}} = :timer.tc(fn -> backup(ctx) end)
      assert elapsed < 15_000_000
      refute out =~ "Terminated"
      refute out =~ "Killed"

      sleepers = pids |> File.read!() |> String.split()
      assert sleepers != []
      wait_until(fn -> Enum.all?(sleepers, &gone?/1) end)
    end

    if match?({:unix, :darwin}, :os.type()) and File.exists?("/bin/bash") do
      test "the heartbeat touches the partials under /bin/bash 3.2 too", ctx do
        {version, 0} = System.cmd("/bin/bash", ["-c", "echo $BASH_VERSION"])
        assert version =~ ~r/\A3\.2\./

        log = Path.join(ctx.tmp, "touches")
        real_touch = System.find_executable("touch")

        stub!(ctx.bin, "touch", """
        #!/bin/sh
        [ "$1" = "-c" ] && echo "$3" >> "#{log}"
        exec #{real_touch} "$@"
        """)

        # A dump that takes a while: the heartbeat runs meanwhile.
        stub!(ctx.bin, "pg_dump", """
        #!/bin/sh
        for a in "$@"; do
          case "$a" in --file=*) printf 'PGDMP pretend dump' > "${a#--file=}" ;; esac
        done
        #{@real_sleep} 0.6
        """)

        assert {_, 0} = backup(ctx, "/bin/bash")
        touched = log |> File.read!() |> String.split("\n", trim: true)
        assert Enum.count(touched, &String.ends_with?(&1, ".dump.partial")) >= 2
        assert Enum.count(touched, &String.ends_with?(&1, ".sha256.partial")) >= 2
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp backup(ctx, bash \\ "bash"), do: run_script(ctx, @script, ["all"], bash)

  # Through a wrapper that exports the script's own PID: `exec` keeps it.
  defp run_script(ctx, script, args, bash \\ "bash") do
    env = [
      {"RESTORE_MEDIA_DIR", Path.join(ctx.tmp, "restored")},
      {"RESTORE_REQUIRE_CHECKSUM", nil},
      {"RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM", nil},
      {"BACKUP_DIR", ctx.backups},
      {"MEDIA_DIR", ctx.media},
      {"DATABASE_URL", "postgres://stub/stub"},
      {"BACKUP_KEEP_DAYS", "14"},
      {"BACKUP_MEDIA_PART_MB", "16"},
      {"BACKUP_MEDIA_EXCLUDE", nil},
      {"BACKUP_RCLONE_REMOTE", nil},
      {"BACKUP_PING_URL", nil},
      {"BACKUP_TRIGGER", nil},
      {"S3_BUCKET", nil},
      {"TMPDIR", ctx.scratch},
      {"COPYFILE_DISABLE", "1"},
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
    ]

    wrapper = ~s(export KILN_TEST_SCRIPT_PID=$$; exec "$0" "$@")
    System.cmd(bash, ["-c", wrapper, bash, script | args], env: env, stderr_to_stdout: true)
  end

  # The script is killed (SIGKILL, so no trap runs) as it starts part 2 of 3.
  defp kill_at_part02!(ctx) do
    real_tar = System.find_executable("tar")

    stub!(ctx.bin, "tar", """
    #!/bin/sh
    case "$*" in
      *-czf*part02.tar.gz.partial*) kill -KILL "$KILN_TEST_SCRIPT_PID"; exit 1 ;;
    esac
    exec #{real_tar} "$@"
    """)
  end

  # The script is killed when it measures a finished file matching `glob`.
  defp kill_on_du!(ctx, glob) do
    real_du = System.find_executable("du")

    stub!(ctx.bin, "du", """
    #!/bin/sh
    for a in "$@"; do
      case "${a##*/}" in #{glob}) kill -KILL "$KILN_TEST_SCRIPT_PID"; exit 1 ;; esac
    done
    exec #{real_du} "$@"
    """)
  end

  defp one_part_media!(ctx) do
    File.rm_rf!(ctx.media)
    File.mkdir_p!(ctx.media)
    File.write!(Path.join(ctx.media, "small.txt"), "one small upload")
  end

  defp marker(ctx, stamp), do: Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256.partial")

  # Neither `verify` nor `restore.sh` takes the leftovers for a backup.
  defp refuses!(ctx, stamp, part01) do
    assert {out, status} = run_script(ctx, @script, ["verify"])
    assert status != 0
    assert out =~ "Skipping media set #{stamp}"
    assert out =~ "no complete media set"

    assert {out, status} = run_script(ctx, @restore, ["media", part01])
    assert status != 0
    assert out =~ "kiln-media-#{stamp}.sha256.partial is beside the set"
    refute File.exists?(Path.join(ctx.tmp, "restored"))
  end

  # Opened read-write, so this never waits for a reader.
  defp release(fifo), do: System.cmd("sh", ["-c", ~s(exec 3<>"$1"; printf go >&3), "sh", fifo])

  defp fresh?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime > System.os_time(:second) - 60
      _ -> false
    end
  end

  defp gone?(pid),
    do: match?({_, n} when n != 0, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("timed out waiting")

      true ->
        Process.sleep(25)
        wait_until(fun, tries - 1)
    end
  end

  defp stamps(ctx) do
    ctx.backups
    |> Path.join("db/kiln-db-*.dump")
    |> Path.wildcard()
    |> Enum.map(&(Regex.run(~r/kiln-db-(\d{8}-\d{6})\.dump\z/, &1) |> List.last()))
  end

  defp only_stamp(ctx) do
    assert [stamp] = stamps(ctx)
    stamp
  end

  # Set every file of `stamp` back `minutes`, past the Importer's settle window.
  defp age!(ctx, stamp, minutes) do
    time = System.os_time(:second) - minutes * 60

    for f <- Path.wildcard(Path.join(ctx.backups, "{db,media}/kiln-*-#{stamp}*")),
        do: File.touch!(f, time)
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp sparse!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = :file.open(path, [:write, :raw, :binary])
    {:ok, _} = :file.position(io, bytes - 1)
    :ok = :file.write(io, <<0>>)
    :ok = :file.close(io)
  end
end
