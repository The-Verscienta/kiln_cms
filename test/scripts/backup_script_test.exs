defmodule KilnCMS.Scripts.BackupScriptTest do
  @moduledoc """
  `scripts/backup.sh` (#2218): the sha256 sidecar and manifest keys it writes,
  `verify` over a whole part set, and `prune` treating a stamp as one set.

  `pg_dump` / `pg_restore` are stubbed on `PATH` (the script only needs them to
  write a file and to accept `--list`); everything else is the real tooling.
  Part sets are built with the app's own pipeline so `verify` and `prune` see
  what the app writes.

  Skipped, with the reason, where bash, tar or a sha256 tool is missing.

  `async: false`: it spawns processes and rewrites `PATH` for the child only,
  but shares the tmp namespace with the other backup tests.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Backups.{Checksum, MediaArchive}

  @script Path.expand("../../scripts/backup.sh", __DIR__)
  @restore Path.expand("../../scripts/restore.sh", __DIR__)

  tools = ["bash", "tar", "gzip", "find"]
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
    File.mkdir_p!(media)
    File.mkdir_p!(bin)
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

    %{tmp: tmp, media: media, backups: backups, bin: bin}
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

    test "without a sidecar a complete part set passes", ctx do
      stamp = "20260805-031700"
      app_set!(ctx, stamp)
      dump!(ctx, stamp)
      File.rm!(Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256"))

      assert {out, 0} = backup(ctx, "verify")
      assert out =~ "no sidecar"
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
    test "removes a whole old set, and keeps one whose newest member is fresh", ctx do
      old = "20260101-000000"
      mixed = "20260301-000000"
      fresh = "20260805-031700"

      old_files = set_files!(ctx, old)
      mixed_files = set_files!(ctx, mixed)
      fresh_files = set_files!(ctx, fresh)

      age!(old_files, 40)
      age!(mixed_files, 40)
      # One member is new: the set is not old.
      age!([List.last(Enum.filter(mixed_files, &String.contains?(&1, ".part")))], 1)
      age!(fresh_files, 1)

      assert {_out, 0} = backup(ctx, "prune")

      assert Enum.all?(old_files, &(not File.exists?(&1)))
      assert Enum.all?(mixed_files, &File.exists?/1)
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
      partial = Path.join(ctx.backups, "media/kiln-media-20260101-000000.part01.tar.gz.partial")
      File.write!(other, "keep")
      File.write!(partial, "in flight")
      age!([other, partial], 90)

      assert {_out, 0} = backup(ctx, "prune")
      assert File.exists?(other)
      assert File.exists?(partial)
    end
  end

  # --- helpers ---------------------------------------------------------------

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
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
    ]
  end

  defp restore_env(ctx),
    do: [{"RESTORE_MEDIA_DIR", Path.join(ctx.tmp, "restored")}, {"RESTORE_REQUIRE_CHECKSUM", "1"}]

  defp backup(ctx, command),
    do: System.cmd("bash", [@script, command], env: env(ctx), stderr_to_stdout: true)

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
