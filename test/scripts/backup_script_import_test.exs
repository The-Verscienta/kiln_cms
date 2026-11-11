defmodule KilnCMS.Scripts.BackupScriptImportTest do
  @moduledoc """
  A media part set written by `scripts/backup.sh` (#2218) is read by the app as
  its own: `Importer` records it as one run with one media artifact whose parts
  match the sidecar and the manifest, a set with a missing part imports as
  failed, and a run killed outright (no EXIT trap) leaves an in-progress marker
  that keeps its stamp from importing as a succeeded, smaller set.

  `pg_dump` / `pg_restore` are stubbed on `PATH`; tar and the rest are real.
  Sparse files keep the 16 MB parts cheap. `async: false`: it spawns the
  script and shares the tmp namespace with the other backup tests.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Checksum, Importer, Manifest}

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

  test "a run killed outright does not import its finished parts as a set", ctx do
    real_tar = System.find_executable("tar")

    stub!(ctx.bin, "tar", """
    #!/bin/sh
    case "$*" in
      *-czf*part02.tar.gz.partial*) kill -KILL "$PPID"; exit 1 ;;
    esac
    exec #{real_tar} "$@"
    """)

    assert {_, status} = backup(ctx)
    assert status != 0

    stamp = only_stamp(ctx)
    assert File.exists?(Path.join(ctx.backups, "media/kiln-media-#{stamp}.part01.tar.gz"))
    marker = Path.join(ctx.backups, "media/kiln-media-#{stamp}.sha256.partial")
    assert File.exists?(marker)

    # Old enough to settle: only the marker holds the stamp back.
    age!(ctx, stamp, 20)

    assert {:ok, %{imported: 0, pending: 1}} = Importer.run(ctx.backups)
    assert {:ok, nil} = Backups.get_run_by_stamp(stamp, actor: Backups.system())

    # Neither `verify` nor `restore.sh` takes the leftovers for a backup.
    part01 = Path.join(ctx.backups, "media/kiln-media-#{stamp}.part01.tar.gz")
    assert {out, status} = run_script(ctx, @script, ["verify"])
    assert status != 0
    assert out =~ "Skipping media set #{stamp}"
    assert out =~ "no complete media set"

    assert {out, status} = run_script(ctx, @restore, ["media", part01])
    assert status != 0
    assert out =~ "kiln-media-#{stamp}.sha256.partial is beside the set"

    # With the marker gone (the app sweeps stale partials after an hour), the
    # missing sidecar still gives the set away.
    File.rm!(marker)
    assert {out, status} = run_script(ctx, @script, ["verify"])
    assert status != 0
    assert out =~ "has parts but no sidecar"

    assert {out, status} = run_script(ctx, @restore, ["media", part01])
    assert status != 0
    assert out =~ "has no sidecar, so it is probably incomplete"
    refute File.exists?(Path.join(ctx.tmp, "restored"))

    # …and the Importer records it as the failed run it was.
    assert {:ok, %{imported: 1}} = Importer.run(ctx.backups)

    assert %{status: :failed, error: "incomplete media set: parts but no sidecar"} =
             Backups.get_run_by_stamp!(stamp, actor: Backups.system())
  end

  # --- helpers ---------------------------------------------------------------

  defp backup(ctx), do: run_script(ctx, @script, ["all"])

  defp run_script(ctx, script, args) do
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

    System.cmd("bash", [script | args], env: env, stderr_to_stdout: true)
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
