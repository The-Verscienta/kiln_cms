defmodule KilnCMS.Scripts.BackupScriptTest do
  @moduledoc """
  `scripts/backup.sh` (#2218): the sha256 sidecar and manifest keys it writes,
  `verify` over a whole part set, `prune` treating a stamp as one set, and the
  media split — part membership compared against the app's own planner
  (`MediaArchive.plan/3`), exclusions, `BACKUP_MEDIA_PART_MB`, and what a
  failed run leaves behind.

  Part caps are real megabytes (the script has no smaller knob), so the trees
  are built from sparse files: a 9 MB file costs one block on disk.

  `pg_dump` / `pg_restore` are stubbed on `PATH` (the script only needs them to
  write a file and to accept `--list`); everything else is the real tooling.
  Part sets are built with the app's own pipeline so `verify` and `prune` see
  what the app writes.

  Skipped, with the reason, where bash, tar or a sha256 tool is missing.
  `COPYFILE_DISABLE=1` keeps macOS bsdtar from adding AppleDouble `._` members
  the membership checks would see; the script itself does not set it.

  `async: false`: it spawns processes and rewrites `PATH` for the child only,
  but shares the tmp namespace with the other backup tests.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Backups.{Checksum, MediaArchive, Retention}
  alias KilnCMS.Backups.Retention.Policy

  @moduletag :capture_log

  @mb 1_048_576
  @script Path.expand("../../scripts/backup.sh", __DIR__)
  @restore Path.expand("../../scripts/restore.sh", __DIR__)

  tools = ["bash", "tar", "gzip", "find", "stat", "xargs", "mktemp", "head"]
  missing = Enum.reject(tools, &System.find_executable/1)
  sha_tool? = System.find_executable("sha256sum") || System.find_executable("shasum")

  cond do
    missing != [] -> @moduletag skip: "needs #{Enum.join(missing, ", ")} on PATH"
    !sha_tool? -> @moduletag skip: "needs sha256sum or shasum on PATH"
    true -> :ok
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "kiln_backup_script_#{System.unique_integer([:positive])}")
    media = Path.join(tmp, "uploads")
    backups = Path.join(tmp, "backups")
    bin = Path.join(tmp, "bin")
    scratch = Path.join(tmp, "scratch")
    File.mkdir_p!(media)
    File.mkdir_p!(bin)
    File.mkdir_p!(scratch)
    File.mkdir_p!(Path.join(backups, "db"))
    File.mkdir_p!(Path.join(backups, "media"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    for n <- 1..6, do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

    stub!(bin, "pg_dump", """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in --file=*) printf 'PGDMP pretend dump' > "${a#--file=}" ;; esac
    done
    """)

    stub!(bin, "pg_restore", "#!/bin/sh\nexit 0\n")

    %{tmp: tmp, media: media, backups: backups, bin: bin, scratch: scratch}
  end

  describe "a cron-style run" do
    test "writes sidecars next to the archives and sha256 keys in the manifest", ctx do
      assert {out, 0} = backup(ctx, "all")

      assert [dump] = Path.wildcard(Path.join(ctx.backups, "db/kiln-db-*.dump"))
      assert [archive] = Path.wildcard(Path.join(ctx.backups, "media/kiln-media-*.tar.gz"))
      dump_sha = Path.rootname(dump) <> ".sha256"
      archive_sha = Path.join(ctx.backups, "media/" <> sidecar_for(archive, "kiln-media-"))

      {:ok, dump_hex, _} = Checksum.file(dump)
      {:ok, archive_hex, _} = Checksum.file(archive)

      # `sha256sum -c` format, one `<hex>  <name>` line, 0600.
      assert File.read!(dump_sha) == "#{dump_hex}  #{Path.basename(dump)}\n"
      assert File.read!(archive_sha) == "#{archive_hex}  #{Path.basename(archive)}\n"
      assert {:ok, [{^dump_hex, _}]} = Checksum.parse_sidecar(dump_sha)
      assert Bitwise.band(File.stat!(archive_sha).mode, 0o077) == 0

      manifest = ctx.backups |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["ok"]
      assert [%{"kind" => "db"} = d, %{"kind" => "media"} = m] = manifest["artifacts"]
      assert d["sha256"] == dump_hex
      assert m["sha256"] == archive_hex
      assert out =~ "ok:"

      # The stamp its files carry, and a start in that same second: one
      # reading of the clock, so the two can't straddle a second boundary.
      stamp = dump |> Path.basename(".dump") |> String.replace_prefix("kiln-db-", "")
      assert manifest["stamp"] == stamp
      assert {:ok, started_at, 0} = DateTime.from_iso8601(manifest["started_at"])
      assert KilnCMS.Backups.Artifact.stamp(started_at) == stamp

      # The same sidecar tool-chain the restore side uses accepts the archive.
      assert {_, 0} = System.cmd("bash", [@restore, "media", archive], env: restore_env(ctx))
    end

    test "no .partial is left behind", ctx do
      assert {_, 0} = backup(ctx, "all")
      assert Path.wildcard(Path.join(ctx.backups, "**/*.partial")) == []
    end
  end

  describe "verify" do
    test "passes on a healthy newest set and names every part", ctx do
      stamp = "20260805-031700"
      parts = app_set!(ctx, stamp)
      assert length(parts) >= 2
      dump!(ctx, stamp)

      assert {out, 0} = backup(ctx, "verify")
      assert out =~ "Newest media backup: #{stamp}"
      for part <- parts, do: assert(out =~ Path.basename(part))
      assert out =~ "sha256: ok (kiln-media-#{stamp}.sha256)"
    end

    test "catches a corrupted part that is not the newest file", ctx do
      stamp = "20260805-031700"
      [p1, p2 | _] = app_set!(ctx, stamp)
      dump!(ctx, stamp)

      flip_byte!(p2)
      # part01 is the newest by mtime, which is what the old check looked at.
      File.touch!(p1, System.os_time(:second) + 100)

      assert {_out, status} = backup(ctx, "verify")
      assert status != 0
    end

    test "catches a sidecar mismatch on an intact archive", ctx do
      stamp = "20260805-031700"
      app_set!(ctx, stamp)
      dump!(ctx, stamp)

      sidecar = Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256")
      [line | _] = File.read!(sidecar) |> String.split("\n", trim: true)
      File.write!(sidecar, String.duplicate("0", 64) <> String.slice(line, 64..-1//1) <> "\n")

      assert {out, status} = backup(ctx, "verify")
      assert status != 0
      assert out =~ "checksum mismatch"
    end

    test "a sidecar line with a truncated digest fails (not silently skipped)", ctx do
      stamp = "20260805-031700"
      app_set!(ctx, stamp)
      dump!(ctx, stamp)

      sidecar = Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256")
      [first | rest] = File.read!(sidecar) |> String.split("\n", trim: true)
      File.write!(sidecar, Enum.join([String.slice(first, 10..-1//1) | rest], "\n") <> "\n")

      assert {_out, status} = backup(ctx, "verify")
      assert status != 0
    end

    test "without a sidecar a missing middle part is caught", ctx do
      stamp = "20260805-031700"
      [_p1, p2, _p3 | _] = app_set!(ctx, stamp)
      dump!(ctx, stamp)
      File.rm!(Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256"))
      File.rm!(p2)

      assert {out, status} = backup(ctx, "verify")
      assert status != 0
      assert out =~ "missing part02"
    end

    test "without a sidecar a part set is incomplete, contiguous or not", ctx do
      stamp = "20260805-031700"
      app_set!(ctx, stamp)
      dump!(ctx, stamp)
      File.rm!(Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256"))

      assert {out, status} = backup(ctx, "verify")
      assert status != 0
      assert out =~ "has parts but no sidecar"
    end

    test "without a sidecar a legacy single archive passes (pre-checksum backups)", ctx do
      stamp = "20260805-031700"
      dump!(ctx, stamp)
      archive = Path.join(ctx.backups, "media/kiln-media-#{stamp}.tar.gz")
      {_, 0} = System.cmd("tar", ["-czf", archive, "-C", ctx.media, "."])

      assert {out, 0} = backup(ctx, "verify")
      assert out =~ "media: ok"
      assert out =~ "no sidecar"
    end

    test "a set with the in-progress marker is skipped for the newest complete one", ctx do
      old = "20260101-000000"
      new = "20260805-031700"
      app_set!(ctx, old)
      dump!(ctx, old)
      [_p1, _p2 | rest] = app_set!(ctx, new)
      dump!(ctx, new)
      # What a cron run killed outright leaves: the first parts and its marker.
      sidecar = Path.join(ctx.backups, "media/kiln-media-#{new}.sha256")
      for p <- rest, do: File.rm!(p)
      File.rename!(sidecar, sidecar <> ".partial")

      assert {out, 0} = backup(ctx, "verify")
      assert out =~ "Skipping media set #{new}: still being written, or interrupted"
      assert out =~ "Newest media backup: #{old}"
      assert out =~ "sha256: ok (kiln-media-#{old}.sha256)"
    end

    test "fails when the only media set is an interrupted one", ctx do
      stamp = "20260805-031700"
      app_set!(ctx, stamp)
      dump!(ctx, stamp)
      sidecar = Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256")
      File.rename!(sidecar, sidecar <> ".partial")

      assert {out, status} = backup(ctx, "verify")
      assert status != 0
      assert out =~ "no complete media set"
    end

    test "only the NEWEST stamp is checked", ctx do
      old = "20260101-000000"
      new = "20260805-031700"
      [o1 | _] = app_set!(ctx, old)
      app_set!(ctx, new)
      dump!(ctx, old)
      dump!(ctx, new)
      flip_byte!(o1)

      assert {_out, 0} = backup(ctx, "verify")
    end
  end

  describe "prune" do
    test "removes a whole old unit, and keeps a component whose newest member is fresh", ctx do
      old = "20260101-000000"
      mixed = "20260301-000000"
      fresh = "20260805-031700"

      old_files = set_files!(ctx, old)
      mixed_files = set_files!(ctx, mixed)
      fresh_files = set_files!(ctx, fresh)

      age!(old_files, 40)
      age!(mixed_files, 40)
      # One media member is new: the media unit is not old; its dump is (#2219).
      age!([List.last(Enum.filter(mixed_files, &String.contains?(&1, ".part")))], 1)
      age!(fresh_files, 1)

      assert {_out, 0} = backup(ctx, "prune")

      {mixed_db, mixed_media} = Enum.split_with(mixed_files, &String.contains?(&1, "/db/"))
      assert Enum.all?(old_files, &(not File.exists?(&1)))
      assert Enum.all?(mixed_db, &(not File.exists?(&1)))
      assert Enum.all?(mixed_media, &File.exists?/1)
      assert Enum.all?(fresh_files, &File.exists?/1)
    end

    test "one very old member does not reap its siblings", ctx do
      stamp = "20260301-000000"
      files = set_files!(ctx, stamp)
      age!(files, 1)
      age!([hd(files)], 90)

      assert {_out, 0} = backup(ctx, "prune")
      assert Enum.all?(files, &File.exists?/1)
    end

    test "leaves unrelated files and partials alone", ctx do
      other = Path.join(ctx.backups, "db/notes.txt")
      stray = Path.join(ctx.backups, "media/kiln-media-notes.txt")
      partial = Path.join(ctx.backups, "media/kiln-media-20260101-000000.part01.tar.gz.partial")
      File.write!(other, "keep")
      File.write!(stray, "keep")
      File.write!(partial, "in flight")
      age!([other, stray, partial], 90)

      assert {_out, 0} = backup(ctx, "prune")
      assert File.exists?(other)
      assert File.exists?(stray)
      assert File.exists?(partial)
    end

    test "the newest complete unit of each kind is kept however old", ctx do
      older = "20260101-000000"
      newest = "20260301-000000"
      older_files = set_files!(ctx, older)
      newest_files = set_files!(ctx, newest)
      age!(older_files ++ newest_files, 400)

      assert {_out, 0} = backup(ctx, "prune")
      assert Enum.all?(older_files, &(not File.exists?(&1)))
      assert Enum.all?(newest_files, &File.exists?/1)
    end

    test "newer parts without their sidecar are not complete and protect nothing", ctx do
      complete = "20260101-000000"
      orphan = "20260301-000000"
      complete_files = set_files!(ctx, complete)
      orphan_files = app_set!(ctx, orphan)
      File.rm!(Path.join(ctx.backups, "media/kiln-media-#{orphan}.sha256"))
      age!(complete_files ++ orphan_files, 400)

      assert {_out, 0} = backup(ctx, "prune")
      assert Enum.all?(complete_files, &File.exists?/1)
      assert Enum.all?(orphan_files, &(not File.exists?(&1)))
    end

    test "a recovery point in db/ or media/ pins both components, and stays", ctx do
      pinned_db = "20260101-000000"
      pinned_media = "20260201-000000"
      newest = "20260301-000000"
      files = Enum.flat_map([pinned_db, pinned_media, newest], &set_files!(ctx, &1))
      db_marker = Path.join(ctx.backups, "db/kiln-#{pinned_db}.keep")
      media_marker = Path.join(ctx.backups, "media/kiln-#{pinned_media}.keep")
      File.write!(db_marker, "")
      File.ln_s!("/nonexistent", media_marker)
      age!(files ++ [db_marker], 400)

      assert {_out, 0} = backup(ctx, "prune")
      assert Enum.all?(files, &File.exists?/1)
      assert File.exists?(db_marker)
      assert {:ok, %{type: :symlink}} = File.lstat(media_marker)
    end

    test "a last-good marker keeps its own component only (#2219)", ctx do
      [marked, newest] = ~w(20260101-000000 20260301-000000)
      marked_files = set_files!(ctx, marked)
      age!(marked_files ++ set_files!(ctx, newest), 400)
      File.write!(Path.join(ctx.backups, "db/kiln-#{marked}.good"), "")

      assert {_out, 0} = backup(ctx, "prune")

      {marked_db, marked_media} = Enum.split_with(marked_files, &String.contains?(&1, "/db/"))
      assert Enum.all?(marked_db, &File.exists?/1)
      assert Enum.all?(marked_media, &(not File.exists?(&1)))
    end

    # The owner's sign-off for #2219: a backup the app verified must not be
    # taken by cron because a later run failed after writing a complete set.
    test "SIGN-OFF: the newest verified set survives a newer complete set from a failed run",
         ctx do
      [older, verified, failed] = ~w(20260101-000000 20260201-000000 20260301-000000)
      files = Map.new([older, verified, failed], &{&1, set_files!(ctx, &1)})
      age!(Enum.flat_map(Map.values(files), & &1), 400)
      # What the app writes on the newest backup its run history verified.
      File.write!(Path.join(ctx.backups, "db/kiln-#{verified}.good"), "")
      File.write!(Path.join(ctx.backups, "media/kiln-#{verified}.good"), "")

      assert {_out, 0} = backup(ctx, "prune")

      assert Enum.all?(files[verified], &File.exists?/1)
      assert Enum.all?(files[failed], &File.exists?/1)
      assert Enum.all?(files[older], &(not File.exists?(&1)))
    end

    test "a last-good marker is never deleted, of any kind or age", ctx do
      newest = "20260301-000000"
      age!(set_files!(ctx, newest), 400)
      regular = Path.join(ctx.backups, "db/kiln-20250101-000000.good")
      link = Path.join(ctx.backups, "media/kiln-20250101-000000.good")
      current = Path.join(ctx.backups, "db/kiln-#{newest}.good")
      File.write!(regular, "")
      File.write!(current, "")
      File.ln_s!("/nonexistent", link)
      age!([regular, current], 400)

      assert {_out, 0} = backup(ctx, "prune")
      assert File.exists?(regular)
      assert File.exists?(current)
      assert {:ok, %{type: :symlink}} = File.lstat(link)
    end

    test "a .work/<stamp> or a fresh .partial keeps its unit; an old .partial doesn't", ctx do
      [working, writing, stale, newest] =
        ~w(20260101-000000 20260201-000000 20260301-000000 20260401-000000)

      files = Map.new([working, writing, stale, newest], &{&1, set_files!(ctx, &1)})
      age!(Enum.flat_map(Map.values(files), & &1), 400)
      File.mkdir_p!(Path.join(ctx.backups, ".work/#{working}"))
      fresh = Path.join(ctx.backups, "media/kiln-media-#{writing}.sha256.partial")
      old = Path.join(ctx.backups, "media/kiln-media-#{stale}.part09.tar.gz.partial")
      File.write!(fresh, "")
      File.write!(old, "")
      age!([old], 2)

      assert {_out, 0} = backup(ctx, "prune")

      assert Enum.all?(files[working], &File.exists?/1)
      {writing_db, writing_media} = Enum.split_with(files[writing], &String.contains?(&1, "/db/"))
      assert Enum.all?(writing_media, &File.exists?/1)
      assert Enum.all?(writing_db, &(not File.exists?(&1)))
      assert Enum.all?(files[stale], &(not File.exists?(&1)))
      assert File.exists?(fresh)
      assert File.exists?(old)
    end

    test "a run in flight never takes the newest-complete slot from the last finished one",
         ctx do
      [older, previous, current] = ~w(20260101-000000 20260201-000000 20260301-000000)
      files = Map.new([older, previous, current], &{&1, set_files!(ctx, &1)})
      age!(Enum.flat_map(Map.values(files), & &1), 400)
      File.mkdir_p!(Path.join(ctx.backups, ".work/#{current}"))

      assert {_out, 0} = backup(ctx, "prune")
      assert Enum.all?(files[current], &File.exists?/1)
      assert Enum.all?(files[previous], &File.exists?/1)
      assert Enum.all?(files[older], &(not File.exists?(&1)))
    end

    test "a .work that is not a listable directory: nothing is pruned", ctx do
      files = set_files!(ctx, "20260101-000000") ++ set_files!(ctx, "20260201-000000")
      age!(files, 400)
      File.write!(Path.join(ctx.backups, ".work"), "not a directory")

      assert {out, 0} = backup(ctx, "prune")
      assert out =~ "could not list #{ctx.backups}/.work — nothing was pruned"
      assert Enum.all?(files, &File.exists?/1)
    end

    test "a recovery point counts from the listing, even where it can't be stat'ed", ctx do
      pinned = "20260101-000000"
      newest = "20260201-000000"
      dump = dump!(ctx, pinned)
      dump!(ctx, newest)
      age!([dump, Path.join(ctx.backups, "db/kiln-db-#{pinned}.sha256")], 400)
      File.write!(Path.join(ctx.backups, "media/kiln-#{pinned}.keep"), "")
      media = Path.join(ctx.backups, "media")
      # Readable (listable) but not searchable: names, but no stat.
      File.chmod!(media, 0o444)
      on_exit(fn -> File.chmod(media, 0o700) end)

      if File.exists?(Path.join(media, "kiln-#{pinned}.keep")) do
        # Running as root: permissions don't bind, so there is nothing to test.
        :ok
      else
        assert {_out, 0} = backup(ctx, "prune")
        File.chmod!(media, 0o700)
        assert File.exists?(dump)
      end
    end

    test "if the search for partials fails, the unit is kept", ctx do
      real_find = System.find_executable("find")

      stub!(ctx.bin, "find", """
      #!/bin/sh
      for a in "$@"; do [ "$a" = "-mmin" ] && exit 1; done
      exec #{real_find} "$@"
      """)

      [older, newest] = ~w(20260101-000000 20260201-000000)
      older_files = set_files!(ctx, older)
      age!(older_files ++ set_files!(ctx, newest), 400)

      assert {out, 0} = backup(ctx, "prune")
      assert out =~ "could not look for partials of db #{older}"
      assert Enum.all?(older_files, &File.exists?/1)
    end

    # The app and the script must agree wherever the script can see what the
    # app's rules need: recovery points, work in flight, newest complete, age,
    # and newest verified, which the script sees through the `.good` markers
    # the app keeps on it (#2219). The app reads its run history instead (the
    # runs below), never the markers.
    test "PARITY: the app's plan and cron's prune keep the same files", ctx do
      expected = parity_fixture!(ctx)

      runs = %{
        "20250315-000000" => %{
          status: :succeeded,
          origin: :app,
          artifacts: [%{kind: :db, verified: true}, %{kind: :media, verified: true}]
        },
        "20250701-000000" => %{
          status: :failed,
          origin: :app,
          artifacts: [%{kind: :db, verified: false}]
        }
      }

      {:ok, inventory} = Retention.scan(ctx.backups)
      plan = Retention.plan(inventory, runs, Policy.legacy(14), System.os_time(:second))
      assert plan.last_good == %{db: "20250315-000000", media: "20250315-000000"}
      planned = for e <- plan.delete, name <- e.files, into: MapSet.new(), do: "#{e.sub}/#{name}"
      app_survivors = MapSet.difference(listing(ctx), planned)

      assert {_out, 0} = backup(ctx, "prune")
      assert listing(ctx) == app_survivors

      for {file, should_survive?} <- expected do
        assert MapSet.member?(app_survivors, file) == should_survive?,
               "#{file} should #{if should_survive?, do: "survive", else: "go"}"
      end
    end
  end

  # Every case the two prunes must agree on, `400` days old unless noted.
  # Returns `[{relative path, survives?}]` for the ones the test spells out.
  defp parity_fixture!(ctx) do
    b = ctx.backups
    put = fn rel, days, content -> parity_put!(b, rel, days, content) end
    outside = Path.join(ctx.tmp, "outside.dump")
    File.write!(outside, "precious")

    # S1: complete db + single media → both go.
    put.("db/kiln-db-20250101-000000.dump", 400, "d")
    put.("db/kiln-db-20250101-000000.sha256", 400, "s")
    put.("media/kiln-media-20250101-000000.tar.gz", 400, "m")

    # S2: a complete part set with an OLD .partial beside it → the set goes, the
    # partial stays.
    for i <- 1..2, do: put.("media/kiln-media-20250201-000000.part0#{i}.tar.gz", 400, "p")
    put.("media/kiln-media-20250201-000000.sha256", 400, "s")
    put.("media/kiln-media-20250201-000000.part03.tar.gz.partial", 2, "p")
    put.("db/kiln-db-20250201-000000.dump", 400, "d")

    # S3: a symlinked dump (never deleted) with a regular sidecar (goes); parts
    # with a zero-byte sidecar (incomplete; all regular files go).
    File.ln_s!(outside, Path.join(b, "db/kiln-db-20250301-000000.dump"))
    put.("db/kiln-db-20250301-000000.sha256", 400, "s")
    for i <- 1..2, do: put.("media/kiln-media-20250301-000000.part0#{i}.tar.gz", 400, "p")
    put.("media/kiln-media-20250301-000000.sha256", 400, "")

    # S4: a complete 100-part set (part100 has three digits): the newest
    # complete media unit → kept.
    for i <- 1..100 do
      put.("media/kiln-media-20250401-000000.part#{pad(i)}.tar.gz", 400, "p")
    end

    put.("media/kiln-media-20250401-000000.sha256", 400, "s")

    # S5: single archive AND parts (incomplete) → goes; its complete dump goes.
    put.("media/kiln-media-20250501-000000.tar.gz", 400, "m")
    put.("media/kiln-media-20250501-000000.part01.tar.gz", 400, "p")
    put.("media/kiln-media-20250501-000000.sha256", 400, "s")
    put.("db/kiln-db-20250501-000000.dump", 400, "d")

    # S6: a zero-byte dump; a gap set (part02 missing) → both go.
    put.("db/kiln-db-20250601-000000.dump", 400, "")
    for i <- [1, 3], do: put.("media/kiln-media-20250601-000000.part0#{i}.tar.gz", 400, "p")
    put.("media/kiln-media-20250601-000000.sha256", 400, "s")

    # S7: the newest complete dump → kept; parts without a sidecar → go.
    put.("db/kiln-db-20250701-000000.dump", 400, "d")
    put.("db/kiln-db-20250701-000000.sha256", 400, "s")
    for i <- 1..2, do: put.("media/kiln-media-20250701-000000.part0#{i}.tar.gz", 400, "p")

    # S8/S9: pinned from db/ and from media/ (zero-byte dumps: not complete,
    # so they don't take the newest-complete slot) → kept.
    put.("db/kiln-20250801-000000.keep", 400, "")
    put.("db/kiln-db-20250801-000000.dump", 400, "")
    put.("media/kiln-20250901-000000.keep", 400, "")
    put.("db/kiln-db-20250901-000000.dump", 400, "")

    # S10: .work/<stamp> → kept. S11: a fresh sidecar .partial → kept.
    File.mkdir_p!(Path.join(b, ".work/20251001-000000"))
    put.("db/kiln-db-20251001-000000.dump", 400, "")
    put.("db/kiln-db-20251101-000000.dump", 400, "")
    put.("db/kiln-db-20251101-000000.sha256.partial", 0, "")

    # S13: a future-dated complete dump and an impossible-stamp (month 13)
    # complete archive: neither may hold the newest slot, so S7 and S4 keep it
    # and these age out.
    put.("db/kiln-db-29991231-000000.dump", 400, "d")
    put.("media/kiln-media-20251399-000000.tar.gz", 400, "m")
    # November 31st and hour 24: the right shape, no real instant.
    put.("db/kiln-db-20251131-000000.dump", 400, "d")
    put.("media/kiln-media-20251231-240000.tar.gz", 400, "m")

    # S12: incomplete but young → kept. An orphan marker → untouched.
    for i <- 1..2, do: put.("media/kiln-media-20251201-000000.part0#{i}.tar.gz", 1, "p")
    put.("media/kiln-20240101-000000.keep", 400, "")

    # S14 (#2219): a verified set older than the newest complete ones (S7's
    # dump is a failed run's) → kept, by its run in the app and by its `.good`
    # markers in cron. A stale `.good` on a gone stamp → untouched by both.
    put.("db/kiln-db-20250315-000000.dump", 400, "d")
    put.("db/kiln-db-20250315-000000.sha256", 400, "s")
    put.("media/kiln-media-20250315-000000.tar.gz", 400, "m")
    # The names the script reads are the ones the app writes.
    assert KilnCMS.Backups.Artifact.good_name("20250315-000000") == "kiln-20250315-000000.good"
    assert KilnCMS.Backups.Artifact.subdir(:db) == "db"
    assert KilnCMS.Backups.Artifact.subdir(:media) == "media"
    put.("db/kiln-20250315-000000.good", 400, "")
    put.("media/kiln-20250315-000000.good", 400, "")
    put.("db/kiln-20240101-000000.good", 400, "")

    [
      {"db/kiln-db-20250101-000000.dump", false},
      {"media/kiln-media-20250101-000000.tar.gz", false},
      {"media/kiln-media-20250201-000000.part01.tar.gz", false},
      {"media/kiln-media-20250201-000000.part03.tar.gz.partial", true},
      {"db/kiln-db-20250301-000000.dump", true},
      {"db/kiln-db-20250301-000000.sha256", false},
      {"media/kiln-media-20250301-000000.sha256", false},
      {"media/kiln-media-20250401-000000.part100.tar.gz", true},
      {"media/kiln-media-20250401-000000.sha256", true},
      {"media/kiln-media-20250501-000000.tar.gz", false},
      {"db/kiln-db-20250501-000000.dump", false},
      {"db/kiln-db-20250601-000000.dump", false},
      {"media/kiln-media-20250601-000000.part03.tar.gz", false},
      {"db/kiln-db-20250701-000000.dump", true},
      {"media/kiln-media-20250701-000000.part01.tar.gz", false},
      {"db/kiln-db-20250801-000000.dump", true},
      {"db/kiln-20250801-000000.keep", true},
      {"db/kiln-db-20250901-000000.dump", true},
      {"db/kiln-db-20251001-000000.dump", true},
      {"db/kiln-db-20251101-000000.dump", true},
      {"media/kiln-media-20251201-000000.part01.tar.gz", true},
      {"media/kiln-20240101-000000.keep", true},
      {"db/kiln-db-20250315-000000.dump", true},
      {"db/kiln-db-20250315-000000.sha256", true},
      {"media/kiln-media-20250315-000000.tar.gz", true},
      {"db/kiln-20250315-000000.good", true},
      {"media/kiln-20250315-000000.good", true},
      {"db/kiln-20240101-000000.good", true},
      {"db/kiln-db-29991231-000000.dump", false},
      {"media/kiln-media-20251399-000000.tar.gz", false},
      {"db/kiln-db-20251131-000000.dump", false},
      {"media/kiln-media-20251231-240000.tar.gz", false}
    ]
  end

  defp parity_put!(root, rel, days, content) do
    path = Path.join(root, rel)
    File.write!(path, content)
    File.touch!(path, System.os_time(:second) - days * 86_400)
  end

  defp listing(ctx) do
    for sub <- ["db", "media"],
        name <- File.ls!(Path.join(ctx.backups, sub)),
        into: MapSet.new(),
        do: "#{sub}/#{name}"
  end

  describe "splitting media into parts" do
    setup ctx do
      # A fresh media tree per test; the shared one holds six 300-byte files.
      File.rm_rf!(ctx.media)
      File.mkdir_p!(ctx.media)
      :ok
    end

    test "the parts hold the same files, in the same order, as the app's planner", ctx do
      sparse!(Path.join(ctx.media, "a/one.bin"), 10 * @mb)
      sparse!(Path.join(ctx.media, "a/b/two.bin"), 10 * @mb)
      sparse!(Path.join(ctx.media, "big.bin"), 20 * @mb)
      sparse!(Path.join(ctx.media, "z/three.bin"), 6 * @mb)
      sparse!(Path.join(ctx.media, "z/four.bin"), 6 * @mb)
      File.mkdir_p!(Path.join(ctx.media, ".hidden"))
      File.write!(Path.join(ctx.media, ".hidden/x.txt"), "dot")
      File.write!(Path.join(ctx.media, ".dotfile"), "dot")
      File.mkdir_p!(Path.join(ctx.media, "with space"))
      File.write!(Path.join(ctx.media, "with space/-leading dash.txt"), "dash")
      File.ln_s!("nowhere", Path.join(ctx.media, "dangling"))
      File.ln_s!("a", Path.join(ctx.media, "link-to-dir"))
      File.mkdir_p!(Path.join(ctx.media, "empty"))

      assert {out, 0} = backup(ctx, "media", [{"BACKUP_MEDIA_PART_MB", "16"}])

      expected = app_lists(ctx, [])
      assert length(expected) >= 4
      assert cron_lists(ctx) == expected
      files = expected |> List.flatten() |> length()
      assert files == 10
      assert out =~ "Planned #{files} file(s) in #{length(expected)} part(s) (cap 16 MB)"
      assert out =~ "1 file(s) larger than the part size were archived as parts of their own"
      # Directories are not members: an empty one is not kept.
      refute Enum.any?(List.flatten(cron_lists(ctx)), &(&1 in ["./empty", "./empty/"]))
    end

    test "a file larger than the cap is a part of its own, with a warning", ctx do
      File.write!(Path.join(ctx.media, "a.txt"), "small")
      sparse!(Path.join(ctx.media, "b.bin"), 17 * @mb)
      # Exactly the cap is not oversize (strictly larger is).
      sparse!(Path.join(ctx.media, "b2.bin"), 16 * @mb)
      File.write!(Path.join(ctx.media, "c.txt"), "small")

      assert {out, 0} = backup(ctx, "media", [{"BACKUP_MEDIA_PART_MB", "16"}])
      assert cron_lists(ctx) == [["./a.txt"], ["./b.bin"], ["./b2.bin"], ["./c.txt"]]
      assert cron_lists(ctx) == app_lists(ctx, [])
      assert out =~ "warning: 1 file(s) larger than the part size"
    end

    test "an empty tree is one legacy-named, valid, empty archive", ctx do
      File.mkdir_p!(Path.join(ctx.media, "only/empty/dirs"))

      assert {out, 0} = backup(ctx, "all")
      assert out =~ "Planned 0 file(s) in 1 part(s)"

      assert [archive] = media_files(ctx)
      assert Path.basename(archive) =~ ~r/\Akiln-media-\d{8}-\d{6}\.tar\.gz\z/
      assert {:ok, []} = :erl_tar.table(String.to_charlist(archive), [:compressed])

      sidecar = Path.join(ctx.backups, "media/" <> sidecar_for(archive, "kiln-media-"))
      {:ok, hex, _} = Checksum.file(archive)
      assert File.read!(sidecar) == "#{hex}  #{Path.basename(archive)}\n"

      assert [_db, media] = manifest!(ctx)["artifacts"]
      assert %{"part" => 1, "parts_total" => 1, "sha256" => ^hex} = media

      assert {_, 0} =
               System.cmd("bash", [@restore, "media", archive],
                 env: restore_env(ctx),
                 stderr_to_stdout: true
               )
    end

    test "excluding everything leaves one empty archive and says how much was left out", ctx do
      File.write!(Path.join(ctx.media, "a.jpg"), "a")
      File.mkdir_p!(Path.join(ctx.media, "d"))
      File.write!(Path.join(ctx.media, "d/b.jpg"), "b")

      assert {out, 0} = backup(ctx, "media", [{"BACKUP_MEDIA_EXCLUDE", "**"}])

      assert out =~
               "Planned 0 file(s) in 1 part(s) (cap 400 MB), 2 excluded by BACKUP_MEDIA_EXCLUDE"

      assert [archive] = media_files(ctx)
      assert {:ok, []} = :erl_tar.table(String.to_charlist(archive), [:compressed])
    end

    test "BACKUP_MEDIA_EXCLUDE matches exactly what the app's planner excludes", ctx do
      names =
        [
          "tmp/a.jpg",
          "tmp/deep/b.jpg",
          "keep/tmp/c.jpg",
          "f.tmp",
          "sub/g.tmp",
          "cache/h.jpg",
          "sub/cache/i.jpg",
          "top.txt",
          "sub/top.txt",
          "x.jpg",
          "sub/deep/x.jpg",
          "abc",
          "a/c",
          "lit[1].jpg",
          "lit1.jpg",
          "x+y(1){2}^$.jpg",
          "xxy(1)22.jpg",
          "éa.jpg",
          "ea.jpg",
          "nb.jpg",
          "back\\slash.jpg"
        ]

      for name <- names, do: File.write!(mkdir_for!(ctx.media, name), name)

      # A name that is not valid UTF-8 (Linux; APFS refuses one).
      latin1 = <<0xE9, "x.jpg">>
      _ = File.write(Path.join(ctx.media, latin1), "latin1")

      patterns = [
        "tmp/**",
        "*.tmp",
        " cache , ,",
        "./top.txt",
        "cache/",
        "**/x.jpg",
        "a?c",
        "lit[1].jpg",
        "x+y(1){2}^$.jpg",
        "é?.jpg",
        " nb.jpg　",
        "back\\slash.jpg",
        "tmp/**,*.tmp,**/x.jpg,a?c"
      ]

      for {raw, i} <- Enum.with_index(patterns) do
        backups = Path.join(ctx.tmp, "matrix-#{i}")
        File.mkdir_p!(backups)

        assert {out, 0} =
                 backup(ctx, "media", [
                   {"BACKUP_MEDIA_EXCLUDE", raw},
                   {"BACKUP_DIR", backups}
                 ]),
               "pattern #{inspect(raw)}"

        globs = app_globs(raw)
        {expected, excluded} = app_plan(ctx, globs)

        assert cron_lists(backups) == expected, "pattern #{inspect(raw)}"

        if excluded > 0,
          do: assert(out =~ ", #{excluded} excluded by BACKUP_MEDIA_EXCLUDE"),
          else: refute(out =~ "excluded by")
      end

      # Spot checks of the shared semantics (the parity above is the contract).
      assert {[[_ | _] = kept], _} = app_plan(ctx, app_globs("cache/"))
      assert "./cache/h.jpg" in kept, "a trailing slash excludes nothing on either path"
      assert {_, 2} = app_plan(ctx, app_globs("**/x.jpg"))
      assert {_, 1} = app_plan(ctx, app_globs(" nb.jpg　"))
    end

    test "names with spaces round-trip through restore.sh; a newline is archived", ctx do
      File.mkdir_p!(Path.join(ctx.media, "dir with space"))
      File.write!(Path.join(ctx.media, "dir with space/file name.txt"), "spaced")
      File.write!(Path.join(ctx.media, "plain.txt"), "plain")

      assert {_, 0} = backup(ctx, "media")
      assert [archive] = media_files(ctx)

      assert {_, 0} =
               System.cmd("bash", [@restore, "media", archive],
                 env: restore_env(ctx),
                 stderr_to_stdout: true
               )

      restored = Path.join(ctx.tmp, "restored")
      assert File.read!(Path.join(restored, "dir with space/file name.txt")) == "spaced"

      File.write!(Path.join(ctx.media, "new\nline.txt"), "nl")
      backups = Path.join(ctx.tmp, "newline")
      File.mkdir_p!(backups)
      assert {_, 0} = backup(ctx, "media", [{"BACKUP_DIR", backups}])
      assert "./new\nline.txt" in List.flatten(cron_lists(backups))
    end

    test "eleven parts: names, sidecar order, manifest entries, modes, verify, restore", ctx do
      eleven_part_run!(ctx, "bash")
    end

    test "BACKUP_MEDIA_PART_MB is read like the app reads it", ctx do
      File.write!(Path.join(ctx.media, "a.txt"), "a")

      cases = [
        {"", 400, false},
        {" 16 ", 16, false},
        {"+16", 16, false},
        {"0016", 16, false},
        {"00000000016", 16, false},
        {"10240", 10_240, false},
        {"abc", 400, true},
        {"5", 400, true},
        {"10241", 400, true},
        {"1.5", 400, true},
        {"-16", 400, true},
        {"16MB", 400, true},
        {"99999999999999999999", 400, true}
      ]

      for {{raw, mb, warns?}, i} <- Enum.with_index(cases) do
        backups = Path.join(ctx.tmp, "mb-#{i}")
        File.mkdir_p!(backups)

        assert {out, 0} =
                 backup(ctx, "media", [{"BACKUP_MEDIA_PART_MB", raw}, {"BACKUP_DIR", backups}])

        assert out =~ "(cap #{mb} MB)", "BACKUP_MEDIA_PART_MB=#{inspect(raw)}"

        assert out =~ "is not a whole number from 16 to 10240; using 400" == warns?,
               "BACKUP_MEDIA_PART_MB=#{inspect(raw)}"
      end
    end

    # bash 3.2 is what macOS ships as /bin/bash; CI (Linux) has 5.x, so this
    # only runs on a Mac.
    bash3? =
      File.exists?("/bin/bash") and
        match?(
          {"3\n", 0},
          System.cmd("/bin/bash", ["-c", "echo ${BASH_VERSINFO[0]}"], stderr_to_stdout: true)
        )

    unless bash3?, do: @tag(skip: "needs /bin/bash 3.x (macOS)")

    test "the eleven-part run also works under /bin/bash 3.2", ctx do
      eleven_part_run!(ctx, "/bin/bash")
    end
  end

  describe "a failed media run" do
    setup ctx do
      File.rm_rf!(ctx.media)
      File.mkdir_p!(ctx.media)
      for n <- 1..3, do: sparse!(Path.join(ctx.media, "f#{n}.bin"), 9 * @mb)
      %{real_tar: System.find_executable("tar")}
    end

    test "a part that keeps failing removes the whole unfinished set", ctx do
      stub!(ctx.bin, "tar", """
      #!/bin/sh
      case "$*" in
        *-czf*part02.tar.gz.partial*) echo "boom on part02" >&2; exit 2 ;;
      esac
      exec #{ctx.real_tar} "$@"
      """)

      assert {out, status} = backup(ctx, "all", [{"BACKUP_MEDIA_PART_MB", "16"}])
      assert status != 0
      assert out =~ "retrying once"

      assert media_dir_listing(ctx) == []
      assert Path.wildcard(Path.join(ctx.backups, "**/*.partial")) == []
      assert [_dump] = Path.wildcard(Path.join(ctx.backups, "db/kiln-db-*.dump"))
      assert File.ls!(ctx.scratch) == []

      manifest = manifest!(ctx)
      refute manifest["ok"]
      assert manifest["error"] =~ "media archive part 2 of 3 failed"
      assert manifest["error"] =~ "boom on part02"
      assert [%{"kind" => "db"}] = manifest["artifacts"]
    end

    test "a part that fails once is retried and the run succeeds", ctx do
      flag = Path.join(ctx.tmp, "failed-once")

      stub!(ctx.bin, "tar", """
      #!/bin/sh
      case "$*" in
        *-czf*part02.tar.gz.partial*)
          if [ ! -e "#{flag}" ]; then : > "#{flag}"; echo "transient" >&2; exit 1; fi ;;
      esac
      exec #{ctx.real_tar} "$@"
      """)

      assert {out, 0} = backup(ctx, "all", [{"BACKUP_MEDIA_PART_MB", "16"}])
      assert out =~ "media archive part 2 of 3 failed (transient"
      assert out =~ "retrying once from a re-filtered list"
      assert length(media_parts(ctx)) == 3
      assert manifest!(ctx)["ok"]
    end

    test "SIGTERM mid-part cleans up and records the failure", ctx do
      stub!(ctx.bin, "tar", """
      #!/bin/sh
      case "$*" in
        *-czf*part02.tar.gz.partial*) kill -TERM "$PPID" ;;
      esac
      exec #{ctx.real_tar} "$@"
      """)

      assert {out, 143} = backup(ctx, "all", [{"BACKUP_MEDIA_PART_MB", "16"}])
      assert out =~ "interrupted by SIGTERM"
      assert media_dir_listing(ctx) == []
      assert Path.wildcard(Path.join(ctx.backups, "**/*.partial")) == []
      assert File.ls!(ctx.scratch) == []

      manifest = manifest!(ctx)
      refute manifest["ok"]
      assert manifest["error"] == "interrupted by SIGTERM"
    end

    test "control bytes and invalid UTF-8 in tar's output still give a readable manifest",
         ctx do
      stub!(ctx.bin, "tar", """
      #!/bin/sh
      case "$*" in
        *-czf*.partial*) printf 'bad\\001\\033[31m\\r\\351name\\t"q"\\\\ \\n' >&2; exit 2 ;;
      esac
      exec #{ctx.real_tar} "$@"
      """)

      assert {_out, status} = backup(ctx, "all", [{"BACKUP_MEDIA_PART_MB", "16"}])
      assert status != 0

      raw = File.read!(Path.join(ctx.backups, "manifest.json"))
      assert String.valid?(raw)
      assert {:ok, manifest} = Jason.decode(raw)
      assert manifest["error"] =~ "media archive part 1 of 3 failed"
      assert manifest["error"] =~ "bad"
      assert manifest["error"] =~ ~s("q")
      assert KilnCMS.Backups.Manifest.read(ctx.backups).ok == false
    end
  end

  describe "media files are private, and the plan is never short" do
    setup ctx do
      File.rm_rf!(ctx.media)
      File.mkdir_p!(ctx.media)
      for n <- 1..3, do: File.write!(Path.join(ctx.media, "f#{n}.bin"), "file #{n}")
      :ok
    end

    test "parts are 0600 from the first byte; a media dir it creates is 0700", ctx do
      real_tar = System.find_executable("tar")
      log = Path.join(ctx.tmp, "modes.log")

      stub!(ctx.bin, "tar", """
      #!/bin/sh
      if [ "$1" = "-czf" ]; then
        #{real_tar} "$@"; rc=$?
        ls -l "$2" | cut -c1-10 >> "#{log}"
        exit $rc
      fi
      exec #{real_tar} "$@"
      """)

      fresh = Path.join(ctx.tmp, "fresh-backups")

      assert {_out, 0} =
               System.cmd("bash", ["-c", "umask 022 && exec bash \"$0\" media", @script],
                 env: merge_env(env(ctx), [{"BACKUP_DIR", fresh}]),
                 stderr_to_stdout: true
               )

      # The probe archive, then the one part: both private while being written.
      assert log |> File.read!() |> String.split("\n", trim: true) |> Enum.uniq() ==
               ["-rw-------"]

      assert Bitwise.band(File.stat!(Path.join(fresh, "media")).mode, 0o777) == 0o700
      # Only the directory it made for media; BACKUP_DIR keeps the operator's umask.
      assert Bitwise.band(File.stat!(fresh).mode, 0o777) == 0o755
    end

    test "an existing media dir keeps its mode", ctx do
      dir = Path.join(ctx.backups, "media")
      File.chmod!(dir, 0o755)

      assert {_out, 0} = backup(ctx, "media")
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o755
    end

    test "a file that vanishes during sizing is dropped and the batch re-run, not stat'ed one by one",
         ctx do
      real_stat = System.find_executable("stat")
      log = Path.join(ctx.tmp, "stat.log")
      flag = Path.join(ctx.tmp, "deleted-once")

      stub!(ctx.bin, "stat", """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{log}"
      if [ "$#" -gt 3 ] && [ ! -e "#{flag}" ]; then
        : > "#{flag}"
        rm -f "#{Path.join(ctx.media, "f2.bin")}"
      fi
      exec #{real_stat} "$@"
      """)

      assert {out, 0} = backup(ctx, "media")
      assert out =~ "Planned 2 file(s) in 1 part(s)"
      assert cron_lists(ctx) == [["./f1.bin", "./f3.bin"]]

      size_calls =
        log |> File.read!() |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "./"))

      assert length(size_calls) == 2
      for call <- size_calls, do: assert(length(String.split(call, " ./")) >= 3, call)
    end

    # /dev/full is Linux-only; there is no portable way to fail a write on macOS.
    unless File.exists?("/dev/full"), do: @tag(skip: "needs /dev/full (Linux)")

    test "a failed write of the file list stops the run instead of archiving a short list",
         ctx do
      real_mktemp = System.find_executable("mktemp")

      # The work directory's list is /dev/full: every write fails with ENOSPC.
      stub!(ctx.bin, "mktemp", """
      #!/bin/sh
      d="$(#{real_mktemp} "$@")" || exit 1
      ln -s /dev/full "$d/walk.list"
      printf '%s\\n' "$d"
      """)

      assert {out, status} = backup(ctx, "all")
      assert status != 0
      assert out =~ "could not list the media directory"
      assert media_dir_listing(ctx) == []
      refute manifest!(ctx)["ok"]
    end
  end

  describe "off-site copies of a part set" do
    setup ctx do
      File.rm_rf!(ctx.media)
      File.mkdir_p!(ctx.media)
      for n <- 1..3, do: sparse!(Path.join(ctx.media, "f#{n}.bin"), 9 * @mb)
      log = Path.join(ctx.tmp, "rclone.log")
      %{log: log}
    end

    test "copies the dump, its sidecar, every part in order, then the media sidecar", ctx do
      stub!(ctx.bin, "rclone", """
      #!/bin/sh
      printf '%s %s %s\\n' "$1" "$(basename "$2")" "$3" >> "#{ctx.log}"
      """)

      assert {_out, 0} =
               backup(ctx, "all", [
                 {"BACKUP_MEDIA_PART_MB", "16"},
                 {"BACKUP_RCLONE_REMOTE", "r2:kiln"}
               ])

      lines = ctx.log |> File.read!() |> String.split("\n", trim: true)

      assert [
               "copy kiln-db-" <> db,
               "copy kiln-db-" <> db_sidecar,
               "copy kiln-media-" <> p1,
               "copy kiln-media-" <> p2,
               "copy kiln-media-" <> p3,
               "copy kiln-media-" <> media_sidecar
             ] = lines

      assert db =~ ~r/\.dump r2:kiln\/db\z/
      assert db_sidecar =~ ~r/\.sha256 r2:kiln\/db\z/
      assert p1 =~ ~r/\.part01\.tar\.gz r2:kiln\/media\z/
      assert p2 =~ ~r/\.part02\.tar\.gz r2:kiln\/media\z/
      assert p3 =~ ~r/\.part03\.tar\.gz r2:kiln\/media\z/
      assert media_sidecar =~ ~r/\.sha256 r2:kiln\/media\z/
      assert manifest!(ctx)["offsite"] == "r2:kiln"
    end

    test "a connection-string remote's credentials reach rclone through its environment only (#2690)",
         ctx do
      stub!(ctx.bin, "rclone", """
      #!/bin/sh
      printf '%s %s %s\\n' "$1" "$(basename "$2")" "$3" >> "#{ctx.log}"
      env | grep '^RCLONE_CONFIG_' | sort >> "#{ctx.log}.env"
      echo -- >> "#{ctx.log}.env"
      """)

      remote =
        ":s3,provider=Cloudflare,access_key_id=AKIAEXAMPLE1,secret_access_key='SUPER,SECRET:VAL':kiln"

      assert {out, 0} =
               backup(ctx, "all", [
                 {"BACKUP_MEDIA_PART_MB", "16"},
                 {"BACKUP_RCLONE_REMOTE", remote}
               ])

      lines = ctx.log |> File.read!() |> String.split("\n", trim: true)
      assert [_ | _] = lines

      for line <- lines do
        assert line =~ ~r{ kiln_offsite:kiln/(db|media)\z}
        refute line =~ "SECRET"
        refute line =~ "AKIAEXAMPLE1"
      end

      blocks = (ctx.log <> ".env") |> File.read!() |> String.split("--\n", trim: true)
      assert length(blocks) == length(lines)

      for block <- blocks do
        assert String.split(block, "\n", trim: true) == [
                 "RCLONE_CONFIG_KILN_OFFSITE_ACCESS_KEY_ID=AKIAEXAMPLE1",
                 "RCLONE_CONFIG_KILN_OFFSITE_PROVIDER=Cloudflare",
                 "RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY=SUPER,SECRET:VAL",
                 "RCLONE_CONFIG_KILN_OFFSITE_TYPE=s3"
               ]
      end

      # The progress line names the remote rclone was given, not the string.
      assert out =~ "Off-site copy → kiln_offsite:kiln"
      refute out =~ "SECRET"
    end

    test "a failed copy of part 2 fails the run but keeps the finished local set", ctx do
      stub!(ctx.bin, "rclone", """
      #!/bin/sh
      case "$2" in *part02*) echo "upload refused" >&2; exit 1 ;; esac
      """)

      assert {out, status} =
               backup(ctx, "all", [
                 {"BACKUP_MEDIA_PART_MB", "16"},
                 {"BACKUP_RCLONE_REMOTE", "r2:kiln"}
               ])

      assert status != 0
      # An upload failure is not a refusal.
      refute out =~ "REFUSING"
      assert length(media_parts(ctx)) == 3
      assert [_sidecar] = Path.wildcard(Path.join(ctx.backups, "media/*.sha256"))
      assert {_, 0} = backup(ctx, "verify")
      refute manifest!(ctx)["ok"]
      # A failed run names no remote: nothing may read its files as off-site.
      assert manifest!(ctx)["offsite"] == nil
    end

    test "a part changed while the one before it uploads is refused, and the run stops", ctx do
      # rclone, copying part01, appends to part02: the real race.
      stub!(ctx.bin, "rclone", """
      #!/bin/sh
      printf '%s %s %s\\n' "$1" "$(basename "$2")" "$3" >> "#{ctx.log}"
      case "$2" in
        *part01.tar.gz) printf tampered >> "$(printf '%s' "$2" | sed 's/part01/part02/')" ;;
      esac
      """)

      assert {out, status} =
               backup(ctx, "all", [
                 {"BACKUP_MEDIA_PART_MB", "16"},
                 {"BACKUP_RCLONE_REMOTE", "r2:kiln"}
               ])

      assert status != 0
      [part02] = Enum.filter(media_parts(ctx), &(&1 =~ ".part02."))
      assert out =~ "REFUSING off-site copy of #{Path.basename(part02)}: its sha256 changed"
      assert out =~ "Nothing was uploaded for it"

      # The dump, its sidecar and part01 went; nothing after the refusal did.
      assert [
               "copy kiln-db-" <> _,
               "copy kiln-db-" <> db_sidecar,
               "copy kiln-media-" <> p1
             ] = ctx.log |> File.read!() |> String.split("\n", trim: true)

      assert db_sidecar =~ ".sha256 "
      assert p1 =~ ".part01.tar.gz "

      manifest = manifest!(ctx)
      refute manifest["ok"]
      assert manifest["error"] =~ "REFUSING off-site copy of #{Path.basename(part02)}"
      assert manifest["offsite"] == nil

      # The failure manifest does not call the refused part verified; the rest
      # still are.
      verified =
        Map.new(manifest["artifacts"], &{Path.basename(&1["path"]), &1["verified"]})

      assert verified[Path.basename(part02)] == false
      assert verified |> Map.delete(Path.basename(part02)) |> Map.values() |> Enum.all?()

      # The set is kept as evidence, and verify says it no longer checks out.
      assert length(media_parts(ctx)) == 3
      assert [_sidecar] = Path.wildcard(Path.join(ctx.backups, "media/*.sha256"))
      assert {_, verify_status} = backup(ctx, "verify")
      assert verify_status != 0
    end

    test "a sidecar rewritten during the upload is refused", ctx do
      stub!(ctx.bin, "rclone", """
      #!/bin/sh
      printf '%s %s %s\\n' "$1" "$(basename "$2")" "$3" >> "#{ctx.log}"
      case "$2" in
        *part03.tar.gz) for f in "$(dirname "$2")"/kiln-media-*.sha256; do echo >> "$f"; done ;;
      esac
      """)

      assert {out, status} =
               backup(ctx, "all", [
                 {"BACKUP_MEDIA_PART_MB", "16"},
                 {"BACKUP_RCLONE_REMOTE", "r2:kiln"}
               ])

      assert status != 0

      assert out =~
               ~r/REFUSING off-site copy of kiln-media-\d{8}-\d{6}\.sha256: its sha256 changed/

      refute File.read!(ctx.log) =~ ~r/kiln-media-\d{8}-\d{6}\.sha256 /
      assert manifest!(ctx)["error"] =~ "REFUSING"
      assert manifest!(ctx)["offsite"] == nil
      # Every part was the part it verified.
      assert Enum.all?(manifest!(ctx)["artifacts"], & &1["verified"])
    end
  end

  # --- helpers ---------------------------------------------------------------

  describe "the database connection (#2719, #2726)" do
    # `pg_dump` logs its argv and whether PGPASSWORD reached it. argv is
    # world-readable (/proc/<pid>/cmdline, `ps`); the environment is not.
    setup ctx do
      log = Path.join(ctx.tmp, "pg_dump")

      stub!(ctx.bin, "pg_dump", """
      #!/bin/sh
      printf '%s\\n' "$@" > "#{log}.args"
      if [ -n "${PGPASSWORD+set}" ]; then printf 'set:%s' "$PGPASSWORD"; else printf unset; fi > "#{log}.env"
      for a in "$@"; do
        case "$a" in --file=*) printf 'PGDMP pretend dump' > "${a#--file=}" ;; esac
      done
      """)

      %{log: log}
    end

    test "pg_dump gets a postgres:// URL and the password through PGPASSWORD only", ctx do
      cases = [
        {"postgres://kiln:hunter2@db:5432/kiln", "postgres://kiln@db:5432/kiln", "hunter2"},
        {"ecto://kiln:hunter2@db/kiln_prod", "postgres://kiln@db/kiln_prod", "hunter2"},
        {"ecto://kiln:p%40ss%3Aw%2Fd%25@db/kiln_prod", "postgres://kiln@db/kiln_prod",
         "p@ss:w/d%"},
        {"ecto://kiln:hunter2@db/kiln_prod?sslmode=require&connect_timeout=5",
         "postgres://kiln@db/kiln_prod?sslmode=require&connect_timeout=5", "hunter2"},
        {"ecto://kiln@db/kiln_prod?sslmode=require&password=hunter2",
         "postgres://kiln@db/kiln_prod?sslmode=require", "hunter2"},
        {"ecto://kiln:hunter2@[::1]:5432/kiln_prod", "postgres://kiln@[::1]:5432/kiln_prod",
         "hunter2"},
        {"postgres://kiln:hunter2%zz@db/kiln", "postgres://kiln@db/kiln", "hunter2%zz"},
        {"postgres://kiln:hunter2@h1:5432,h2:5433/kiln?application_name=a@b",
         "postgres://kiln@h1:5432,h2:5433/kiln?application_name=a@b", "hunter2"}
      ]

      for {input, url, password} <- cases do
        assert {_out, 0} = backup(ctx, "db", [{"DATABASE_URL", input}, {"PGPASSWORD", nil}])

        args = File.read!(ctx.log <> ".args")
        assert List.last(String.split(args, "\n", trim: true)) == url, input
        refute args =~ "hunter2", input
        assert File.read!(ctx.log <> ".env") == "set:" <> password, input
      end
    end

    test "without a password in the URL, the operator's own PGPASSWORD still applies", ctx do
      url = "ecto://kiln@db/kiln_prod"

      assert {_out, 0} = backup(ctx, "db", [{"DATABASE_URL", url}, {"PGPASSWORD", "from-env"}])
      assert File.read!(ctx.log <> ".args") =~ "\npostgres://kiln@db/kiln_prod\n"
      assert File.read!(ctx.log <> ".env") == "set:from-env"

      assert {_out, 0} = backup(ctx, "db", [{"DATABASE_URL", url}, {"PGPASSWORD", nil}])
      assert File.read!(ctx.log <> ".env") == "unset"
    end

    test "the password never reaches rclone, tar or anything else the run starts", ctx do
      rclone_log = Path.join(ctx.tmp, "rclone.env")

      stub!(ctx.bin, "rclone", """
      #!/bin/sh
      env | grep '^PGPASSWORD' >> "#{rclone_log}"
      echo -- >> "#{rclone_log}"
      """)

      assert {_out, 0} =
               backup(ctx, "all", [
                 {"DATABASE_URL", "ecto://kiln:hunter2@db/kiln_prod"},
                 {"PGPASSWORD", nil},
                 {"BACKUP_RCLONE_REMOTE", "r2:kiln"}
               ])

      assert File.read!(ctx.log <> ".env") == "set:hunter2"
      copies = rclone_log |> File.read!() |> String.split("\n", trim: true)
      assert [_ | _] = copies
      assert Enum.uniq(copies) == ["--"]
    end

    test "a failed dump records no secret, and none reaches the log", ctx do
      # libpq echoes the connection string it was given in its errors.
      stub!(ctx.bin, "pg_dump", """
      #!/bin/sh
      echo "pg_dump: error: could not connect: $*" >&2
      exit 1
      """)

      assert {out, status} =
               backup(ctx, "all", [
                 {"DATABASE_URL", "ecto://kiln:hunter2@db/kiln_prod"},
                 {"PGPASSWORD", nil}
               ])

      assert status != 0
      assert out =~ "could not connect"
      refute out =~ "hunter2"
      refute manifest!(ctx)["error"] =~ "hunter2"
      refute manifest!(ctx)["ok"]
    end

    # bash 3.2 is what macOS ships as /bin/bash; CI (Linux) has 5.x, so this
    # only runs on a Mac.
    bash3? =
      File.exists?("/bin/bash") and
        match?(
          {"3\n", 0},
          System.cmd("/bin/bash", ["-c", "echo ${BASH_VERSINFO[0]}"], stderr_to_stdout: true)
        )

    unless bash3?, do: @tag(skip: "needs /bin/bash 3.x (macOS)")

    test "the split also works under /bin/bash 3.2", ctx do
      # An encoded backslash before `c` (which `%b` would read as "stop
      # here"), an `@`, and a trailing newline (which `$(…)` would drop).
      url = "ecto://kiln:hun%5Cct%40er2%0A@db/kiln_prod?sslmode=require"

      assert {_out, 0} =
               backup(ctx, "db", [{"DATABASE_URL", url}, {"PGPASSWORD", nil}], "/bin/bash")

      args = File.read!(ctx.log <> ".args")
      assert args =~ "\npostgres://kiln@db/kiln_prod?sslmode=require\n"
      refute args =~ "hun"
      assert File.read!(ctx.log <> ".env") == "set:hun\\ct@er2\n"
    end
  end

  describe "BACKUP_KEEP_DAYS is read like the app reads it (#2727)" do
    @parity_var "KILN_BACKUP_SCRIPT_KEEP_DAYS_PARITY"

    test "the same value, or the same default and a warning, as Env.positive_integer/1", ctx do
      on_exit(fn -> System.delete_env(@parity_var) end)

      cases = [
        nil,
        "",
        "  ",
        "14",
        " 14",
        "14 ",
        # A no-break space, not a duplicate of " 14".
        "\u00A014",
        "+14",
        "014",
        "1",
        "2147483647",
        "0",
        "-1",
        "14d",
        "7 days",
        "1.5",
        "2147483648",
        "99999999999999999999"
      ]

      for raw <- cases do
        {app, warns?} = app_keep_days(raw)

        assert {out, 0} = backup(ctx, "prune", [{"BACKUP_KEEP_DAYS", raw}])
        assert out =~ "Pruning backups older than #{app} days", inspect(raw)

        assert out =~ "is not a whole number of days from 1 to 2147483647; using 14" == warns?,
               inspect(raw)
      end
    end

    test "an unusable value still gives `all` a manifest the app can read", ctx do
      assert {out, 0} = backup(ctx, "all", [{"BACKUP_KEEP_DAYS", "14d"}])
      assert out =~ "BACKUP_KEEP_DAYS=14d is not a whole number of days"

      assert %{"ok" => true, "keep_days" => 14} =
               ctx.backups |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

      assert %KilnCMS.Backups.Manifest{ok: true, keep_days: 14} =
               KilnCMS.Backups.Manifest.read(ctx.backups)
    end

    test "leading zeros are not written into the manifest's JSON", ctx do
      assert {_out, 0} = backup(ctx, "all", [{"BACKUP_KEEP_DAYS", "007"}])
      assert %{"keep_days" => 7} = manifest!(ctx)
    end

    test "0 and -1 keep the default, so a backup three days old survives", ctx do
      for raw <- ["0", "-1"] do
        older = dump!(ctx, "20260801-000000")
        newest = dump!(ctx, "20260805-000000")
        age!([older, sidecar(older)], 3)
        age!([newest, sidecar(newest)], 1)

        assert {_out, 0} = backup(ctx, "prune", [{"BACKUP_KEEP_DAYS", raw}])
        assert File.exists?(older), raw
      end
    end

    test "14d prunes like 14, where nothing was pruned before", ctx do
      older = dump!(ctx, "20260601-000000")
      newest = dump!(ctx, "20260805-000000")
      age!([older, sidecar(older)], 30)
      age!([newest, sidecar(newest)], 1)

      assert {_out, 0} = backup(ctx, "prune", [{"BACKUP_KEEP_DAYS", "14d"}])
      refute File.exists?(older)
      refute File.exists?(sidecar(older))
      assert File.exists?(newest)
    end
  end

  # What the app makes of `raw` as BACKUP_KEEP_DAYS (config/runtime/prod/backups.exs):
  # `{days, warned?}`.
  defp app_keep_days(raw) do
    if raw, do: System.put_env(@parity_var, raw), else: System.delete_env(@parity_var)

    {parsed, warning} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> KilnCMS.Config.Env.positive_integer(@parity_var) end)

    case parsed do
      {:ok, days} -> {days, warning != ""}
      _unset_or_unrecognized -> {14, warning != ""}
    end
  end

  defp sidecar(dump), do: Path.rootname(dump) <> ".sha256"

  # The eleven-part `all` run shared by the default-bash and bash-3.2 tests.
  defp eleven_part_run!(ctx, bash) do
    File.rm_rf!(ctx.media)
    File.mkdir_p!(ctx.media)
    # 9 MB each against a 16 MB cap: one file per part.
    for n <- 1..11,
        do: sparse!(Path.join(ctx.media, "f#{String.pad_leading("#{n}", 2, "0")}.bin"), 9 * @mb)

    # Off-site too, so every part is re-hashed before its copy under this bash.
    log = Path.join(ctx.tmp, "rclone-eleven.log")

    stub!(ctx.bin, "rclone", """
    #!/bin/sh
    printf '%s\\n' "$(basename "$2")" >> "#{log}"
    """)

    assert {_out, 0} =
             backup(
               ctx,
               "all",
               [{"BACKUP_MEDIA_PART_MB", "16"}, {"BACKUP_RCLONE_REMOTE", "r2:kiln"}],
               bash
             )

    # dump + its sidecar + 11 parts + the media sidecar
    assert log |> File.read!() |> String.split("\n", trim: true) |> length() == 14

    parts = media_parts(ctx)
    names = Enum.map(parts, &Path.basename/1)
    assert length(parts) == 11
    [stamp] = names |> Enum.map(&(&1 |> String.split(".") |> hd())) |> Enum.uniq()

    assert names ==
             for(n <- 1..11, do: "#{stamp}.part#{String.pad_leading("#{n}", 2, "0")}.tar.gz")

    for part <- parts, do: assert(Bitwise.band(File.stat!(part).mode, 0o777) == 0o600)

    sidecar = Path.join(ctx.backups, "media/#{stamp}.sha256")
    assert {:ok, entries} = Checksum.parse_sidecar(sidecar)
    assert Enum.map(entries, &elem(&1, 1)) == names
    assert Bitwise.band(File.stat!(sidecar).mode, 0o077) == 0

    for {{hex, _name}, part} <- Enum.zip(entries, parts) do
      assert {:ok, ^hex, _} = Checksum.file(part)
    end

    manifest = manifest!(ctx)
    assert manifest["ok"]
    assert [%{"kind" => "db"} | media] = manifest["artifacts"]

    for {{entry, part}, i} <- Enum.with_index(Enum.zip(media, parts), 1) do
      {:ok, hex, bytes} = Checksum.file(part)

      assert entry == %{
               "kind" => "media",
               "path" => "media/" <> Path.basename(part),
               "bytes" => bytes,
               "verified" => true,
               "sha256" => hex,
               "part" => i,
               "parts_total" => 11
             }
    end

    assert {out, 0} = backup(ctx, "verify", [], bash)
    assert out =~ "sha256: ok (#{stamp}.sha256)"

    assert {_, 0} =
             System.cmd("bash", [@restore, "media", Enum.at(parts, 4)],
               env: restore_env(ctx),
               stderr_to_stdout: true
             )

    restored = Path.join(ctx.tmp, "restored")
    for n <- 1..11, do: assert(File.stat!(Path.join(restored, "f#{pad(n)}.bin")).size == 9 * @mb)
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  # A file of `bytes` apparent size that occupies (almost) nothing on disk.
  defp sparse!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = :file.open(path, [:write, :raw, :binary])
    {:ok, _} = :file.position(io, bytes - 1)
    :ok = :file.write(io, <<0>>)
    :ok = :file.close(io)
  end

  defp mkdir_for!(root, rel) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    path
  end

  defp manifest!(ctx),
    do: ctx.backups |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  defp media_dir_listing(ctx), do: File.ls!(Path.join(ctx.backups, "media"))

  defp media_files(ctx_or_dir) do
    dir = if is_map(ctx_or_dir), do: ctx_or_dir.backups, else: ctx_or_dir
    Path.wildcard(Path.join(dir, "media/kiln-media-*.tar.gz"))
  end

  defp media_parts(ctx), do: Enum.sort(media_files(ctx))

  # Members of every media archive in `dir` (or the test's backup dir), in
  # part order, as raw `./rel` binaries.
  defp cron_lists(ctx_or_dir) do
    ctx_or_dir
    |> media_files()
    |> Enum.sort_by(&part_number/1)
    |> Enum.map(fn part ->
      case :erl_tar.table(String.to_charlist(part), [:compressed]) do
        {:ok, names} -> Enum.map(names, &norm/1)
        # `:erl_tar` refuses a member whose name is not valid UTF-8 (GNU tar
        # writes it raw on Linux): extract with the system tar instead.
        {:error, {:bad_header, :invalid_string}} -> extracted_members(part)
      end
    end)
  end

  # Members of `archive`, by extracting it with the system tar and walking the
  # result in the app's order (bytewise-sorted names, files and links before
  # each folder's subfolders), names kept as raw bytes.
  defp extracted_members(archive) do
    dir = Path.join(System.tmp_dir!(), "members-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      {_, 0} = System.cmd("tar", ["-xzf", archive, "-C", dir], stderr_to_stdout: true)
      dir |> walk_extracted("") |> Enum.map(&norm/1)
    after
      File.rm_rf!(dir)
    end
  end

  defp walk_extracted(root, rel) do
    abs = if rel == "", do: root, else: root <> "/" <> rel
    {:ok, names} = :file.list_dir_all(abs)

    {dirs, files} =
      names
      |> Enum.map(&IO.iodata_to_binary/1)
      |> Enum.sort()
      |> Enum.map(&if(rel == "", do: &1, else: rel <> "/" <> &1))
      |> Enum.split_with(
        &match?({:ok, %File.Stat{type: :directory}}, File.lstat(root <> "/" <> &1))
      )

    Enum.map(files, &("./" <> &1)) ++ Enum.flat_map(dirs, &walk_extracted(root, &1))
  end

  defp part_number(path) do
    case Regex.run(~r/\.part(\d+)\.tar\.gz\z/, path) do
      [_, n] -> String.to_integer(n)
      nil -> 0
    end
  end

  # The app's plan of the same tree, as per-part member lists, with the
  # number of excluded entries.
  defp app_plan(ctx, globs) do
    work = Path.join(ctx.tmp, "plan-#{System.unique_integer([:positive])}")

    {:ok, plan} =
      MediaArchive.plan(ctx.media, work,
        stamp: "20260101-000000",
        part_bytes: 16 * @mb,
        exclude: globs
      )

    lists =
      for p <- plan.parts do
        work
        |> Path.join(p.list)
        |> File.read!()
        |> :binary.split(<<0>>, [:global])
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&norm/1)
      end

    {lists, plan.excluded}
  end

  # The app's plan at the cap the cron runs in these tests use (16 MB).
  defp app_lists(ctx, globs), do: ctx |> app_plan(globs) |> elem(0)

  # BACKUP_MEDIA_EXCLUDE as config/runtime/prod/backups.exs reads it.
  defp app_globs(raw) do
    if String.trim(raw) == "" do
      []
    else
      raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  # One comparable form for a name from a plan list (raw bytes) and from
  # `:erl_tar` (which may decode a non-UTF-8 name as Latin-1): UTF-8 kept,
  # anything else read as Latin-1. bsdtar stores a sparse file as a PAX sparse
  # member, which `:erl_tar` (no sparse support) names `dir/GNUSparseFile.0/name`;
  # real tars restore it under its own name.
  defp norm(name) when is_list(name), do: name |> :unicode.characters_to_binary() |> norm()

  defp norm(name) when is_binary(name) do
    name = if String.valid?(name), do: name, else: :unicode.characters_to_binary(name, :latin1)
    String.replace(name, ~r{GNUSparseFile\.\d+/}, "")
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp env(ctx) do
    [
      {"BACKUP_DIR", ctx.backups},
      {"MEDIA_DIR", ctx.media},
      {"DATABASE_URL", "postgres://stub/stub"},
      {"BACKUP_KEEP_DAYS", "14"},
      {"BACKUP_RCLONE_REMOTE", nil},
      {"BACKUP_PING_URL", nil},
      {"S3_BUCKET", nil},
      {"BACKUP_MEDIA_PART_MB", nil},
      {"BACKUP_MEDIA_EXCLUDE", nil},
      {"TMPDIR", ctx.scratch},
      {"COPYFILE_DISABLE", "1"},
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
    ]
  end

  defp restore_env(ctx),
    do: [{"RESTORE_MEDIA_DIR", Path.join(ctx.tmp, "restored")}, {"RESTORE_REQUIRE_CHECKSUM", "1"}]

  # `extra` overrides (or adds to) the base environment, e.g.
  # `[{"BACKUP_MEDIA_PART_MB", "16"}]`.
  defp backup(ctx, command, extra \\ [], bash \\ "bash"),
    do:
      System.cmd(bash, [@script, command],
        env: merge_env(env(ctx), extra),
        stderr_to_stdout: true
      )

  defp merge_env(base, extra) do
    overrides = Map.new(extra)

    Enum.map(base, fn {k, v} -> {k, Map.get(overrides, k, v)} end) ++
      Enum.reject(extra, fn {k, _} -> List.keymember?(base, k, 0) end)
  end

  defp sidecar_for(archive, prefix) do
    stamp =
      archive |> Path.basename() |> String.replace_prefix(prefix, "") |> String.split(".") |> hd()

    prefix <> stamp <> ".sha256"
  end

  # A media set written by the app's pipeline (parts + sidecar).
  defp app_set!(ctx, stamp) do
    media_dir = Path.join(ctx.backups, "media")
    work = Path.join(ctx.tmp, "work-#{stamp}")

    {:ok, plan} = MediaArchive.plan(ctx.media, work, stamp: stamp, part_bytes: 700, exclude: [])
    {:ok, finished} = MediaArchive.archive(plan, media_dir)
    {:ok, _} = MediaArchive.checksum(plan, finished, media_dir)
    Enum.map(finished, & &1.path)
  end

  # A dump and its sidecar, as the app/cron write them.
  defp dump!(ctx, stamp) do
    path = Path.join(ctx.backups, "db/kiln-db-#{stamp}.dump")
    File.write!(path, "PGDMP #{stamp}")
    {:ok, hex, _} = Checksum.file(path)
    :ok = Checksum.write_sidecar(Path.rootname(path) <> ".sha256", [{Path.basename(path), hex}])
    path
  end

  defp set_files!(ctx, stamp) do
    parts = app_set!(ctx, stamp)
    dump = dump!(ctx, stamp)

    [
      dump,
      Path.join(ctx.backups, "db/kiln-db-#{stamp}.sha256"),
      Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256")
    ] ++ parts
  end

  defp age!(files, days) do
    time = System.os_time(:second) - days * 86_400
    for f <- files, do: File.touch!(f, time)
  end

  defp flip_byte!(path) do
    bytes = File.read!(path)
    pos = div(byte_size(bytes), 2)
    <<head::binary-size(^pos), byte, tail::binary>> = bytes
    File.write!(path, <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>)
  end
end
