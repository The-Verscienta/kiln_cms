defmodule KilnCMS.Backups.MediaArchiveTest do
  # async: false: the archiver shells out to tar, so concurrent heavy tests
  # would slow it down. The bounded-memory tests measure only the archiving
  # work's own processes (see peak_growth/1), not the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Backups.{Artifact, Checksum, MediaArchive}
  alias KilnCMS.Test.{Eventually, OsProcess}

  @moduletag :tmp_dir

  @stamp "20260805-031700"

  setup %{tmp_dir: tmp} do
    media = Path.join(tmp, "media")
    out = Path.join(tmp, "out")
    work = Path.join([tmp, "backup", ".work", @stamp])
    File.mkdir_p!(media)
    %{media: media, out: out, work: work, tmp: tmp}
  end

  # -- helpers ---------------------------------------------------------------

  defp put(media, rel, data) do
    path = Path.join(media, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    path
  end

  defp plan!(ctx, opts \\ []) do
    opts = Keyword.merge([stamp: @stamp, part_bytes: 1_000_000, exclude: []], opts)
    assert {:ok, plan} = MediaArchive.plan(ctx.media, ctx.work, opts)
    plan
  end

  defp archive!(plan, ctx, opts \\ []) do
    assert {:ok, parts} = MediaArchive.archive(plan, ctx.out, opts)
    parts
  end

  # {relative path => {:file, sha} | {:link, target}} for a whole tree.
  defp snapshot(root), do: snapshot(root, "", %{})

  defp snapshot(root, rel, acc) do
    dir = if rel == "", do: root, else: Path.join(root, rel)

    dir
    |> File.ls!()
    |> Enum.reduce(acc, fn name, acc ->
      child = if rel == "", do: name, else: Path.join(rel, name)
      path = Path.join(root, child)

      case File.lstat!(path) do
        %{type: :directory} -> snapshot(root, child, acc)
        %{type: :symlink} -> Map.put(acc, child, {:link, File.read_link!(path)})
        %{type: :regular} -> Map.put(acc, child, {:file, sha(File.read!(path))})
      end
    end)
  end

  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  defp extract_all(parts, dest) do
    File.mkdir_p!(dest)

    for part <- parts do
      assert {_, 0} = System.cmd("tar", ["-xzf", part.path, "-C", dest], stderr_to_stdout: true)
    end
  end

  defp listing(path) do
    assert {out, 0} = System.cmd("tar", ["-tzf", path])
    out |> String.split("\n", trim: true) |> Enum.reject(&(&1 in ["./", "."]))
  end

  # An executable that stands in for tar.
  defp stub_tar(tmp, name, body) do
    path = Path.join(tmp, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp real_tar, do: System.find_executable("tar")

  defp partials(dir), do: Path.wildcard(Path.join(dir, "**/*.partial"), match_dot: true)

  # Peak memory held by the archiving work while `fun` runs, polling every
  # 10 ms. Only the work is measured, not the whole VM: `:erlang.memory/1`
  # also counts whatever Oban, caches and other apps allocate meanwhile, which
  # made this flaky under CI load (#2218).
  #
  # `fun` runs in a fresh worker whose group leader is a private forwarder.
  # Every process the worker spawns, transitively, inherits that group leader
  # unless something resets it, so "has our group leader" is the work's process
  # family (Tasks, file io servers, port watchers). Its footprint is the
  # processes' own memory plus each off-heap (refc) binary they reference,
  # counted once by id, plus ports they own. A file read into memory is a
  # binary some family member holds, so it still counts in full.
  defp peak_growth(fun) do
    caller_gl = Process.group_leader()
    gl = spawn_link(fn -> forward_io(caller_gl) end)
    parent = self()
    ref = make_ref()

    worker =
      spawn_link(fn ->
        Process.group_leader(self(), gl)
        send(parent, {ref, :ready})

        receive do
          {^ref, :go} -> :ok
        end

        result =
          try do
            {:ok, fun.()}
          rescue
            e -> {:raise, e, __STACKTRACE__}
          catch
            kind, reason -> {kind, reason, __STACKTRACE__}
          end

        send(parent, {ref, :done, result})
      end)

    receive do
      {^ref, :ready} -> :ok
    end

    sampler = Task.async(fn -> sample(gl, 0) end)
    send(worker, {ref, :go})

    result =
      receive do
        {^ref, :done, result} -> result
      end

    send(sampler.pid, :stop)
    peak = Task.await(sampler, 5_000)
    Process.unlink(gl)
    Process.exit(gl, :kill)

    case result do
      {:ok, _} -> peak
      {:raise, e, stack} -> reraise e, stack
      {kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp forward_io(target) do
    receive do
      msg ->
        send(target, msg)
        forward_io(target)
    end
  end

  defp sample(gl, peak) do
    receive do
      :stop -> max(peak, footprint(gl))
    after
      10 -> sample(gl, max(peak, footprint(gl)))
    end
  end

  defp footprint(gl) do
    family =
      for pid <- Process.list(),
          Process.info(pid, :group_leader) == {:group_leader, gl},
          do: pid

    {heaps, binaries} =
      Enum.reduce(family, {0, %{}}, fn pid, {heaps, binaries} ->
        case Process.info(pid, [:memory, :binary]) do
          [memory: memory, binary: bins] ->
            {heaps + memory,
             Enum.reduce(bins, binaries, fn {id, size, _}, acc -> Map.put(acc, id, size) end)}

          nil ->
            {heaps, binaries}
        end
      end)

    ports =
      for port <- Port.list(),
          {:connected, owner} <- [Port.info(port, :connected)],
          owner in family,
          {:memory, memory} <- [Port.info(port, :memory)],
          reduce: 0,
          do: (acc -> acc + memory)

    heaps + (binaries |> Map.values() |> Enum.sum()) + ports
  end

  defp sparse!(path, bytes) do
    {:ok, io} = :file.open(path, [:write, :raw, :binary])
    {:ok, _} = :file.position(io, bytes - 1)
    :ok = :file.write(io, <<0>>)
    :ok = :file.close(io)
  end

  # -- planning --------------------------------------------------------------

  describe "plan/3" do
    test "closes parts on the sum of input sizes and writes private lists", ctx do
      for n <- 1..9, do: put(ctx.media, "d#{rem(n, 3)}/f#{n}.bin", :binary.copy("x", 400))

      plan = plan!(ctx, part_bytes: 1000)

      assert plan.files == 9
      assert length(plan.parts) == 5
      assert Enum.all?(plan.parts, &(&1.bytes <= 1000 and not &1.oversize))
      assert Enum.sum(Enum.map(plan.parts, & &1.files)) == 9

      assert {:ok, %{mode: mode}} = File.stat(ctx.work)
      assert Bitwise.band(mode, 0o077) == 0

      for part <- plan.parts do
        list = Path.join(ctx.work, part.list)
        assert {:ok, %{mode: mode}} = File.stat(list)
        assert Bitwise.band(mode, 0o077) == 0
        entries = list |> File.read!() |> String.split(<<0>>, trim: true)
        assert length(entries) == part.files
        assert Enum.all?(entries, &String.starts_with?(&1, "./"))
      end
    end

    test "is deterministic: the same tree plans the same parts", ctx do
      for n <- 1..20, do: put(ctx.media, "a/#{n}/f.bin", "12345")

      a = plan!(ctx, part_bytes: 30)
      b = plan!(ctx, part_bytes: 30)
      assert a.parts == b.parts

      assert Enum.map(a.parts, &File.read!(Path.join(ctx.work, &1.list))) ==
               Enum.map(b.parts, &File.read!(Path.join(ctx.work, &1.list)))
    end

    test "a file larger than the cap is its own flagged part and is never split", ctx do
      put(ctx.media, "a.bin", "tiny")
      big = put(ctx.media, "big.bin", :binary.copy("B", 5_000))
      put(ctx.media, "z.bin", "tiny")

      plan = plan!(ctx, part_bytes: 1000)

      assert [oversize] = Enum.filter(plan.parts, & &1.oversize)
      assert oversize.files == 1 and oversize.bytes == 5_000

      assert File.read!(Path.join(ctx.work, oversize.list)) == "./big.bin" <> <<0>>
      assert File.exists?(big)

      parts = archive!(plan, ctx)
      assert Enum.count(parts, & &1.oversize) == 1
      assert Enum.all?(parts, & &1.verified)
    end

    test "an empty tree is one part with no files, archived as a valid empty tarball", ctx do
      plan = plan!(ctx)
      assert [%{index: 1, files: 0}] = plan.parts

      [part] = archive!(plan, ctx)
      assert part.verified
      assert listing(part.path) == []
    end

    test "regular files and symlinks only; sockets, devices and directories are skipped", ctx do
      put(ctx.media, "real.txt", "r")
      File.mkdir_p!(Path.join(ctx.media, "empty-dir"))
      File.ln_s!("real.txt", Path.join(ctx.media, "link"))
      File.ln_s!("nowhere", Path.join(ctx.media, "dangling"))
      File.ln_s!("empty-dir", Path.join(ctx.media, "dirlink"))

      plan = plan!(ctx)
      assert plan.files == 4

      parts = archive!(plan, ctx)
      dest = Path.join(ctx.tmp, "restored")
      extract_all(parts, dest)

      assert snapshot(dest) == snapshot(ctx.media)
      assert {:ok, "real.txt"} = File.read_link(Path.join(dest, "link"))
      assert {:ok, "nowhere"} = File.read_link(Path.join(dest, "dangling"))
      refute File.dir?(Path.join(dest, "empty-dir"))
    end

    test "exclusions are off by default and applied by the planner when set", ctx do
      put(ctx.media, "keep.jpg", "k")
      put(ctx.media, "scratch.tmp", "t")
      put(ctx.media, "sub/deep/x.tmp", "t")
      put(ctx.media, "cache/a.jpg", "c")
      put(ctx.media, "cache/b/c.jpg", "c")
      put(ctx.media, "variants/v.webp", "v")

      assert plan!(ctx).files == 6
      assert plan!(ctx).excluded == 0

      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log(fn ->
          send(self(), {:plan, plan!(ctx, exclude: ["*.tmp", "cache", "variants/**"])})
        end)

      assert_received {:plan, plan}

      assert plan.files == 1
      assert plan.excluded >= 3
      assert log =~ "excludes 3 pattern"

      [part] = archive!(plan, ctx)
      assert listing(part.path) == ["./keep.jpg"]
    end

    test "`**/` and `?` globs", ctx do
      put(ctx.media, "a/b/c.raw", "1")
      put(ctx.media, "c.raw", "1")
      put(ctx.media, "x1.png", "1")
      put(ctx.media, "x22.png", "1")

      assert plan!(ctx, exclude: ["**/*.raw"]).files == 2
      assert plan!(ctx, exclude: ["x?.png"]).files == 3
      assert plan!(ctx, exclude: ["a/*"]).files == 3
      assert plan!(ctx, exclude: ["a/**"]).files == 3
    end

    test "a missing media directory is an error", ctx do
      assert {:error, {:missing_media_dir, _}} =
               MediaArchive.plan(Path.join(ctx.tmp, "nope"), ctx.work, stamp: @stamp)
    end

    test "the plan is frozen: load_plan/2 returns it, later files are not in it", ctx do
      for n <- 1..4, do: put(ctx.media, "f#{n}", String.duplicate("z", 400))
      plan = plan!(ctx, part_bytes: 500)

      put(ctx.media, "added-later", "late")

      assert {:ok, loaded} = MediaArchive.load_plan(ctx.media, ctx.work)
      assert loaded.parts == plan.parts
      assert loaded.stamp == @stamp
      assert loaded.files == 4

      assert {:ok, again} =
               MediaArchive.plan_or_load(ctx.media, ctx.work, stamp: @stamp, part_bytes: 500)

      assert again.files == 4
    end

    test "load_plan/2 refuses an interrupted plan", ctx do
      assert {:error, :no_plan} = MediaArchive.load_plan(ctx.media, ctx.work)

      put(ctx.media, "f", "1")
      plan = plan!(ctx)
      File.rm!(Path.join(ctx.work, hd(plan.parts).list))
      assert {:error, :no_plan} = MediaArchive.load_plan(ctx.media, ctx.work)

      File.rm!(Path.join(ctx.work, "plan.json"))
      assert {:error, :no_plan} = MediaArchive.load_plan(ctx.media, ctx.work)
    end
  end

  # -- archiving -------------------------------------------------------------

  describe "archive/3" do
    test "parts are numbered numerically past part99, never lexicographically", ctx do
      for n <- 1..105, do: put(ctx.media, "f#{String.pad_leading("#{n}", 3, "0")}", "12345678")

      plan = plan!(ctx, part_bytes: 10)
      assert length(plan.parts) == 105

      parts = archive!(plan, ctx)
      names = Enum.map(parts, & &1.name)

      assert Enum.map(names, &(&1 |> Artifact.parse_file() |> elem(1) |> Map.fetch!(:part))) ==
               Enum.to_list(1..105)

      assert "kiln-media-#{@stamp}.part100.tar.gz" in names
      assert names == Artifact.set_names(@stamp, 105)
      # The lexicographic order differs, which is exactly the bug to avoid.
      assert Enum.sort(names) != names
      assert Enum.all?(parts, & &1.verified)
    end

    test "each part is a valid archive alone; their union is the tree; they are disjoint", ctx do
      for n <- 1..40 do
        put(ctx.media, "d#{rem(n, 4)}/sub/f#{n}.bin", :crypto.strong_rand_bytes(100 + n * 37))
      end

      plan = plan!(ctx, part_bytes: 1500)
      parts = archive!(plan, ctx)
      assert length(parts) > 3

      listings = Enum.map(parts, &listing(&1.path))
      all = List.flatten(listings)
      assert length(all) == length(Enum.uniq(all))

      assert Enum.sort(Enum.filter(all, &String.contains?(&1, ".bin"))) ==
               Enum.sort(for {rel, _} <- snapshot(ctx.media), do: "./" <> rel)

      for part <- parts do
        assert {_, 0} = System.cmd("tar", ["-tzf", part.path], stderr_to_stdout: true)
        assert {:ok, %{mode: mode}} = File.stat(part.path)
        assert Bitwise.band(mode, 0o077) == 0
      end

      dest = Path.join(ctx.tmp, "restored")
      extract_all(parts, dest)
      assert snapshot(dest) == snapshot(ctx.media)
    end

    test "odd file names round-trip: leading dash, newline, spaces, unicode", ctx do
      names = ["-weird", "two\nlines.txt", "sp ace/ü ñ.jpg", "--also=weird", "-C"]
      for name <- names, do: put(ctx.media, name, "data:" <> name)

      plan = plan!(ctx, part_bytes: 40)
      parts = archive!(plan, ctx)
      assert plan.unreadable_names == 0

      dest = Path.join(ctx.tmp, "restored")
      extract_all(parts, dest)

      assert snapshot(dest) == snapshot(ctx.media)
      assert File.read!(Path.join(dest, "-weird")) == "data:-weird"
      assert File.read!(Path.join(dest, "two\nlines.txt")) == "data:two\nlines.txt"
      assert File.read!(Path.join(dest, "sp ace/ü ñ.jpg")) == "data:sp ace/ü ñ.jpg"
    end

    # `File.ls` omits a name that is not valid in the VM's file-name encoding
    # (UTF-8 on Linux); `:file.list_dir_all` returns it as a raw binary. The
    # planner must see it and archive it byte for byte. APFS refuses the name,
    # so there the creation is skipped (the stub test below covers the logic).
    test "a non-UTF-8 file name is archived byte-exact, not left out", ctx do
      put(ctx.media, "plain.txt", "plain")
      raw = <<0xFF, 0xFE, "latin1-é"::binary>>

      if File.write(Path.join(ctx.media, raw), "raw bytes") == :ok do
        plan = plan!(ctx)
        assert plan.files == 2
        assert plan.unreadable_names == 0

        parts = archive!(plan, ctx)
        dest = Path.join(ctx.tmp, "restored")
        extract_all(parts, dest)

        assert File.read!(Path.join(dest, "plain.txt")) == "plain"
        assert {:ok, names} = :file.list_dir_all(String.to_charlist(dest))
        assert raw in names
        assert File.read!(Path.join(dest, raw)) == "raw bytes"
      end
    end

    test "names the VM lists but cannot stat are counted and warned, the rest archived",
         ctx do
      put(ctx.media, "ok.txt", "fine")
      bad = <<0xFF, "bad">>

      list_dir = fn path ->
        # A raw binary and a decoded charlist, as `:file.list_dir_all` returns.
        {:ok, names} = :file.list_dir_all(path)
        {:ok, [bad, ~c"ok.txt"] ++ (names -- [~c"ok.txt"])}
      end

      lstat = fn path ->
        if Path.basename(path) == bad, do: {:error, :no_translation}, else: File.lstat(path)
      end

      log =
        capture_log(fn ->
          send(self(), {:plan, plan!(ctx, list_dir: list_dir, lstat: lstat)})
        end)

      assert_received {:plan, plan}
      assert plan.files == 1
      assert plan.unreadable_names == 1
      assert plan.unreadable_examples == [inspect("\uFFFDbad")]
      assert log =~ "could not archive 1 file name(s)"

      # Survives the frozen-plan round trip.
      assert {:ok, loaded} = MediaArchive.load_plan(ctx.media, ctx.work)
      assert loaded.unreadable_names == 1
      assert loaded.unreadable_examples == plan.unreadable_examples

      parts = archive!(plan, ctx)
      assert Enum.flat_map(parts, &listing(&1.path)) == ["./ok.txt"]
    end

    test "a plan.json without the unreadable fields (an older plan) loads as zero", ctx do
      put(ctx.media, "a.txt", "a")
      plan!(ctx)

      path = Path.join(ctx.work, "plan.json")

      stripped =
        path
        |> File.read!()
        |> Jason.decode!()
        |> Map.drop(["unreadable_names", "unreadable_examples"])

      File.write!(path, Jason.encode!(stripped))

      assert {:ok, %{unreadable_names: 0, unreadable_examples: []}} =
               MediaArchive.load_plan(ctx.media, ctx.work)
    end

    test "a file that vanished after planning is dropped (and counted), not fatal", ctx do
      a = put(ctx.media, "a.bin", "aaaa")
      put(ctx.media, "b.bin", "bbbb")
      plan = plan!(ctx)

      File.rm!(a)

      log = capture_log(fn -> send(self(), {:parts, archive!(plan, ctx)}) end)
      assert_received {:parts, [part]}

      assert part.dropped == 1
      assert part.files == 1
      assert part.verified
      assert listing(part.path) == ["./b.bin"]
      assert log =~ "vanished"
    end

    test "every listed file vanished: a valid empty archive, not a tar error", ctx do
      a = put(ctx.media, "a.bin", "aaaa")
      plan = plan!(ctx)
      File.rm!(a)

      assert [part] = archive!(plan, ctx)
      assert part.dropped == 1 and part.verified
      assert listing(part.path) == []
    end

    for {label, code} <- [bsdtar: 1, gnu_cannot_stat: 2] do
      test "a file vanishing between the filter and tar (#{label}, exit #{code}) is retried from a re-filtered list",
           ctx do
        victim = put(ctx.media, "victim.bin", "going away")
        put(ctx.media, "stays.bin", "stays")
        plan = plan!(ctx)

        marker = Path.join(ctx.tmp, "marker-#{unquote(label)}")

        # First -czf: the file disappears just before tar reads it, tar still
        # writes what it can and exits non-zero. The second -czf is clean.
        tar =
          stub_tar(ctx.tmp, "tar-#{unquote(label)}", """
          if [ "$1" = "-czf" ] && [ ! -e "#{marker}" ]; then
            touch "#{marker}"
            rm -f "#{victim}"
            "#{real_tar()}" "$@" 2>/dev/null
            exit #{unquote(code)}
          fi
          exec "#{real_tar()}" "$@"
          """)

        capture_log(fn -> send(self(), {:parts, archive!(plan, ctx, tar: tar)}) end)
        assert_received {:parts, [part]}

        assert File.exists?(marker)
        assert part.dropped == 1
        assert part.verified
        assert listing(part.path) == ["./stays.bin"]
        assert partials(ctx.tmp) == []
      end
    end

    test "a non-zero tar exit is never accepted on its own, even when the archive lists", ctx do
      put(ctx.media, "a.bin", "aaaa")
      plan = plan!(ctx)

      # Writes a perfectly good archive, then exits 2 every time.
      tar =
        stub_tar(ctx.tmp, "tar-liar", """
        if [ "$1" = "-czf" ]; then
          "#{real_tar()}" "$@"
          echo "tar: something went wrong" >&2
          exit 2
        fi
        exec "#{real_tar()}" "$@"
        """)

      capture_log(fn ->
        assert {:error, {:exit_status, "tar", 2, output}, []} =
                 MediaArchive.archive(plan, ctx.out, tar: tar)

        assert output =~ "something went wrong"
      end)

      assert partials(ctx.tmp) == []
      assert Path.wildcard(Path.join(ctx.out, "*")) == []
    end

    test "killing the caller mid-tar kills the tar OS process too", ctx do
      put(ctx.media, "a.bin", "aaaa")
      plan = plan!(ctx)
      pidfile = Path.join(ctx.tmp, "tar.pid")

      # `exec`, so the recorded pid is the one the port holds.
      tar =
        stub_tar(ctx.tmp, "tar-slow", """
        echo $$ > "#{pidfile}"
        exec sleep 30
        """)

      caller = spawn(fn -> MediaArchive.archive_part(plan, 1, ctx.out, tar: tar) end)

      Eventually.eventually(
        fn -> File.exists?(pidfile) and File.read!(pidfile) =~ ~r/\d+\n/ end,
        timeout_ms: 10_000,
        message: "the stub tar never wrote its pid"
      )

      os_pid = pidfile |> File.read!() |> String.trim()
      assert OsProcess.alive?(os_pid)

      Process.exit(caller, :kill)

      # Killed, whether or not reaped yet, inside a wall-clock budget: the
      # watcher's `kill -9` is a fork that a loaded host can delay for
      # seconds (#2564), and the stub sleeps 30 s, so 10 s still fails a
      # watcher that never fires.
      Eventually.eventually(fn -> OsProcess.gone?(os_pid) end,
        timeout_ms: 10_000,
        message: fn ->
          "tar (pid #{os_pid}) outlived its killed caller: " <>
            "ps state #{inspect(OsProcess.state(os_pid))}"
        end
      )
    end

    test "a tar that cannot list its archive fails the part", ctx do
      put(ctx.media, "a.bin", "aaaa")
      plan = plan!(ctx)

      tar =
        stub_tar(ctx.tmp, "tar-badlist", """
        if [ "$1" = "-czf" ]; then printf 'not a tarball' > "$2"; exit 0; fi
        exec "#{real_tar()}" "$@"
        """)

      capture_log(fn ->
        assert {:error, {:exit_status, "tar", _, _}, []} =
                 MediaArchive.archive(plan, ctx.out, tar: tar)
      end)

      assert partials(ctx.tmp) == []
    end

    test "partial failure keeps earlier parts, leaves no .partial, reports what landed", ctx do
      for n <- 1..6, do: put(ctx.media, "f#{n}", String.duplicate("q", 400))
      plan = plan!(ctx, part_bytes: 500)
      assert length(plan.parts) == 6

      # Dies on the third part (its list is part03.*), both attempts.
      tar =
        stub_tar(ctx.tmp, "tar-dies", """
        case "$*" in
          *part03*) echo "tar: disk on fire" >&2; : > "$2"; exit 2;;
        esac
        exec "#{real_tar()}" "$@"
        """)

      capture_log(fn ->
        assert {:error, {:exit_status, "tar", 2, output}, done} =
                 MediaArchive.archive(plan, ctx.out, tar: tar)

        assert output =~ "disk on fire"
        assert Enum.map(done, & &1.index) == [1, 2]
      end)

      assert partials(ctx.tmp) == []

      assert Path.wildcard(Path.join(ctx.out, "*")) |> Enum.map(&Path.basename/1) |> Enum.sort() ==
               Enum.take(Artifact.set_names(@stamp, 6), 2)
    end

    test ":reuse keeps a part that is already on disk and builds the rest", ctx do
      for n <- 1..3, do: put(ctx.media, "f#{n}", String.duplicate("q", 400))
      plan = plan!(ctx, part_bytes: 500)
      [first | _] = archive!(plan, ctx)
      mtime = File.stat!(first.path, time: :posix).mtime
      Process.sleep(1100)

      parts =
        archive!(plan, ctx,
          reuse: fn
            %{index: 1} -> {:ok, first}
            _ -> :build
          end
        )

      assert length(parts) == 3
      assert File.stat!(first.path, time: :posix).mtime == mtime
    end

    test "archive_part/4 rejects an unknown part and a missing tar", ctx do
      put(ctx.media, "f", "1")
      plan = plan!(ctx)
      assert {:error, {:no_such_part, 9}} = MediaArchive.archive_part(plan, 9, ctx.out)

      assert {:error, {:missing_executable, "tar"}} =
               MediaArchive.archive_part(plan, 1, ctx.out, tar: nil)
    end
  end

  # -- checksums -------------------------------------------------------------

  describe "checksum/3" do
    setup ctx do
      for n <- 1..6, do: put(ctx.media, "f#{n}", :crypto.strong_rand_bytes(400))
      plan = plan!(ctx, part_bytes: 900)
      parts = archive!(plan, ctx)
      %{plan: plan, parts: parts}
    end

    test "per-part digests equal an independent hash; the set digest hashes the concatenation",
         ctx do
      assert length(ctx.parts) >= 3

      for part <- ctx.parts do
        assert part.sha256 == sha(File.read!(part.path))
        assert part.bytes == File.stat!(part.path).size
      end

      assert {:ok, set} = MediaArchive.checksum(ctx.plan, ctx.parts, ctx.out)

      concatenated = Enum.map_join(ctx.parts, &File.read!(&1.path))
      assert set.sha256 == sha(concatenated)
      assert set.bytes == byte_size(concatenated)
      assert set.sidecar == "kiln-media-#{@stamp}.sha256"
    end

    test "the sidecar verifies with the system's sha256 tool, in part order, mode 0600", ctx do
      assert {:ok, %{sidecar: sidecar}} = MediaArchive.checksum(ctx.plan, ctx.parts, ctx.out)
      path = Path.join(ctx.out, sidecar)

      assert {:ok, entries} = Checksum.parse_sidecar(path)
      assert Enum.map(entries, &elem(&1, 1)) == Enum.map(ctx.parts, & &1.name)
      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0

      {exe, args} =
        if System.find_executable("sha256sum"),
          do: {"sha256sum", ["-c", sidecar]},
          else: {"shasum", ["-a", "256", "-c", sidecar]}

      assert {out, 0} = System.cmd(exe, args, cd: ctx.out, stderr_to_stdout: true)
      assert out =~ "OK"

      # And a flipped byte is caught by the same tool.
      part = hd(ctx.parts)
      <<first, rest::binary>> = File.read!(part.path)
      File.write!(part.path, <<Bitwise.bxor(first, 1), rest::binary>>)
      assert {_, status} = System.cmd(exe, args, cd: ctx.out, stderr_to_stdout: true)
      assert status != 0
    end

    test "a part that changed since it was hashed is refused", ctx do
      part = List.last(ctx.parts)
      File.write!(part.path, "tampered", [:append])

      assert {:error, {:checksum_changed, [name]}} =
               MediaArchive.checksum(ctx.plan, ctx.parts, ctx.out)

      assert name == part.name
      refute File.exists?(Path.join(ctx.out, "kiln-media-#{@stamp}.sha256"))
    end

    test "a single-part set keeps the legacy name and its digest is the part's", ctx do
      File.rm_rf!(ctx.out)
      File.rm_rf!(ctx.work)
      plan = plan!(ctx, part_bytes: 10_000_000)
      [part] = archive!(plan, ctx)

      assert part.name == "kiln-media-#{@stamp}.tar.gz"
      assert {:ok, set} = MediaArchive.checksum(plan, [part], ctx.out)
      assert set.sha256 == part.sha256
    end
  end

  # -- bounded memory --------------------------------------------------------

  describe "bounded memory" do
    test "archiving a tree with a large sparse file stays far below its size", ctx do
      for n <- 1..1500, do: put(ctx.media, "d#{rem(n, 30)}/f#{n}.bin", :binary.copy("m", 700))
      sparse!(Path.join(ctx.media, "huge.bin"), 256 * 1_048_576)

      growth =
        peak_growth(fn ->
          plan = plan!(ctx, part_bytes: 64 * 1_048_576)
          parts = archive!(plan, ctx)
          assert {:ok, _} = MediaArchive.checksum(plan, parts, ctx.out)
          assert Enum.any?(parts, & &1.oversize) or length(parts) >= 2
        end)

      assert growth < 32 * 1_048_576, "memory grew by #{div(growth, 1_048_576)} MiB"
    end

    @tag :backup_scale
    test "a 3 GiB tree: plan, tar, gzip and hash without the VM growing", ctx do
      for n <- 1..5000, do: put(ctx.media, "d#{rem(n, 50)}/f#{n}.bin", :binary.copy("m", 900))
      sparse!(Path.join(ctx.media, "huge-a.bin"), 2 * 1_073_741_824)
      sparse!(Path.join(ctx.media, "huge-b.bin"), 1_073_741_824)

      growth =
        peak_growth(fn ->
          plan = plan!(ctx, part_bytes: 400 * 1_048_576)
          parts = archive!(plan, ctx)
          assert {:ok, _} = MediaArchive.checksum(plan, parts, ctx.out)
          assert Enum.count(parts, & &1.oversize) == 2
        end)

      assert growth < 64 * 1_048_576, "memory grew by #{div(growth, 1_048_576)} MiB"
    end
  end
end
