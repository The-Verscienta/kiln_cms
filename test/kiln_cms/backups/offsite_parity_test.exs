defmodule KilnCMS.Backups.OffsiteParityTest do
  @moduledoc """
  What a deployment that sets only `BACKUP_RCLONE_REMOTE` sees of the in-app
  backup's off-site copy, pinned through the whole step chain (#2220).

  Backup destinations (#2220) rewrite the off-site step around a list of
  destinations, of which the env remote becomes one. This file is the proof
  that nothing changes for an env-only user: the exact `rclone` command lines
  and environment, their order, the Run log, the destination keys, the
  manifest's `offsite`, the Run's status and error, how each failure is
  retried or not, and what a Resume copies. It must pass, unmodified, before
  and after that rewrite.

  It complements, and does not repeat:

    * `offsite_test.exs`, which pins the same argv and environment one level
      down, through `Worker.offsite_results/2` (kept for the console);
    * `worker_test.exs`, which pins a missing rclone's exact Run error and
      manifest, and a refused single-file archive's `unverify`;
    * `resume_test.exs`, which pins that a Resume after a failed copy rebuilds
      nothing and copies six files again.

  Runs real `pg_dump` and `tar` (`:pg_tools`); `rclone` is a stub ahead of
  them on PATH. `async: false`: PATH and `Application` env are VM-global.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Manifest}
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  @conn_remote ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket"
  # What the Run, the manifest and the destination key show of it, literally.
  @conn_redacted ":s3,access_key_id=***,secret_access_key=***:bucket"

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkp_#{System.unique_integer([:positive])}")
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

    %{base: base, dir: dir}
  end

  # -- helpers ---------------------------------------------------------------

  defp remote!(remote) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, remote)
    )
  end

  # An rclone that logs its argv to `log` and its RCLONE_CONFIG_* environment
  # to `env`, one block per call; exits 1 with a message while `fail` exists,
  # and appends to part 2 while it uploads part 1 while `tamper` exists.
  defp fake_rclone!(base) do
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    f = Map.new([:log, :env, :fail, :tamper], &{&1, Path.join(base, "rclone.#{&1}")})

    File.write!(Path.join(bin, "rclone"), """
    #!/bin/sh
    echo "$*" >> "#{f.log}"
    env | grep '^RCLONE_CONFIG_' | sort >> "#{f.env}"
    echo -- >> "#{f.env}"
    [ -f "#{f.fail}" ] && { echo "upload refused" >&2; exit 1; }
    case "$2" in
      *part01.tar.gz)
        if [ -f "#{f.tamper}" ]; then
          printf tampered >> "$(printf '%s' "$2" | sed 's/part01/part02/')"
        fi ;;
    esac
    exit 0
    """)

    File.chmod!(Path.join(bin, "rclone"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    Map.put(f, :exe, Path.join(bin, "rclone"))
  end

  defp gate!(path), do: File.write!(path, "")

  defp lines(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp env_blocks(%{env: env}) do
    case File.read(env) do
      {:ok, text} -> text |> String.split("--\n") |> Enum.drop(-1)
      {:error, :enoent} -> []
    end
  end

  defp run!, do: hd(Backups.list_runs!(actor: Backups.system()))

  defp offsite_job do
    [job] =
      Repo.all(
        from(j in Oban.Job,
          where: j.queue == "backup_steps" and fragment("?->>'step' = 'offsite'", j.args)
        )
      )

    job
  end

  # The files the off-site step copies, in the order it copies them: the
  # dump, the media parts, then the db and media checksum sidecars.
  defp files(dir, stamp) do
    [
      Path.join([dir, "db", "kiln-db-#{stamp}.dump"])
      | Enum.map(1..3, &Path.join([dir, "media", Artifact.part_name(stamp, &1)]))
    ] ++
      [
        Path.join([dir, "db", Artifact.sidecar_name(:db, stamp)]),
        Path.join([dir, "media", Artifact.sidecar_name(:media, stamp)])
      ]
  end

  # `rclone copy <file> <remote>/<db|media>` for each of them.
  defp copies(dir, stamp, target) do
    for file <- files(dir, stamp),
        do: "copy #{file} #{target}/#{file |> Path.dirname() |> Path.basename()}"
  end

  # A destination result without its `"at"` timestamp.
  defp dest(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, Map.delete(v, "at")} end)

  defp offsite_log(run, level),
    do: for(%{step: "offsite", level: ^level} = l <- run.log, do: l.message)

  # Hides `rclone` on a host or CI runner that has one installed (as
  # `worker_test.exs` does): each PATH directory holding one is swapped for a
  # directory of symlinks to everything else in it.
  defp no_rclone_on_path(base) do
    shims = Path.join(base, "norclone")

    kept =
      System.get_env("PATH")
      |> String.split(":")
      |> Enum.with_index()
      |> Enum.map_join(":", fn {dir, i} -> without_rclone(dir, Path.join(shims, "#{i}")) end)

    System.put_env("PATH", kept)
  end

  defp without_rclone(dir, shim) do
    if File.exists?(Path.join(dir, "rclone")) do
      File.mkdir_p!(shim)
      for name <- File.ls!(dir), name != "rclone", do: link!(dir, name, shim)
      shim
    else
      dir
    end
  end

  defp link!(dir, name, shim), do: File.ln_s!(Path.join(dir, name), Path.join(shim, name))

  # -- success ---------------------------------------------------------------

  describe "a connection-string remote" do
    test "copies dump, parts, then sidecars, credentials in the environment only", %{
      base: base,
      dir: dir
    } do
      remote!(@conn_remote)
      rclone = fake_rclone!(base)

      assert :ok = BackupChain.run()
      run = run!()
      stamp = run.stamp

      # #2690: the connection string's parameters define `kiln_offsite` in
      # rclone's environment; argv names only that remote.
      assert lines(rclone.log) == copies(dir, stamp, "kiln_offsite:bucket")

      blocks = env_blocks(rclone)
      assert length(blocks) == 6

      for block <- blocks do
        assert String.split(block, "\n", trim: true) == [
                 "RCLONE_CONFIG_KILN_OFFSITE_ACCESS_KEY_ID=AKIAEXAMPLE1",
                 "RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY=SUPERSECRETVAL",
                 "RCLONE_CONFIG_KILN_OFFSITE_TYPE=s3"
               ]
      end

      assert run.status == :succeeded
      assert run.error == nil

      assert offsite_log(run, :info) ==
               Enum.map(files(dir, stamp), &"Copied #{Path.basename(&1)} off-site")

      assert offsite_log(run, :error) == []

      key = "rclone:" <> @conn_redacted
      assert [db, media] = run.artifacts

      assert dest(db.destinations) == %{
               "local" => %{"status" => "ok"},
               key => %{"status" => "ok"}
             }

      assert dest(media.destinations) == %{
               "local" => %{"status" => "ok"},
               key => %{"status" => "ok"}
             }

      assert db.verified and media.verified

      assert [_, _, _] = media.parts

      for part <- media.parts,
          do:
            assert(
              dest(part["destinations"]) == %{
                "local" => %{"status" => "ok"},
                key => %{"status" => "ok"}
              }
            )

      manifest = Manifest.read(dir)
      assert manifest.ok
      assert manifest.offsite == @conn_redacted

      for haystack <- [inspect(run), File.read!(Manifest.path(dir))] do
        refute haystack =~ "SUPERSECRETVAL"
        refute haystack =~ "AKIAEXAMPLE1"
      end
    end
  end

  describe "a named remote" do
    test "is passed as it is, with no environment, and is the manifest's offsite", %{
      base: base,
      dir: dir
    } do
      remote!("r2:kiln/backups")
      rclone = fake_rclone!(base)

      assert :ok = BackupChain.run()
      run = run!()

      assert lines(rclone.log) == copies(dir, run.stamp, "r2:kiln/backups")
      assert env_blocks(rclone) == List.duplicate("", 6)

      assert run.status == :succeeded
      assert [db, media] = run.artifacts
      assert Map.keys(db.destinations) == ["local", "rclone:r2:kiln/backups"]
      assert Map.keys(media.destinations) == ["local", "rclone:r2:kiln/backups"]
      assert Manifest.read(dir).offsite == "r2:kiln/backups"
    end
  end

  # -- failures --------------------------------------------------------------

  describe "an rclone that exits 1" do
    test "is retried with the step, then fails the run with every file named", %{
      base: base,
      dir: dir
    } do
      remote!("r2:kiln")
      rclone = fake_rclone!(base)
      gate!(rclone.fail)

      assert {:error, {:offsite, %{failed: failed, refused: []}}} = BackupChain.run()
      assert length(failed) == 6

      run = run!()
      stamp = run.stamp

      # Four attempts, each trying every file in the same order.
      job = offsite_job()
      assert job.attempt == 4
      assert job.state == "cancelled"
      assert lines(rclone.log) == List.flatten(List.duplicate(copies(dir, stamp, "r2:kiln"), 4))

      [dump, p1, p2, p3, db_sidecar, _media_sidecar] =
        Enum.map(files(dir, stamp), &Path.basename/1)

      assert run.status == :failed

      assert run.error ==
               "Off-site copy FAILED for 6 files: #{dump} (rclone exited 1), " <>
                 "#{p1} (rclone exited 1), #{p2} (rclone exited 1), #{p3} (rclone exited 1), " <>
                 "#{db_sidecar} (rclone exited 1) and 1 more. The local files are kept; " <>
                 "Resume retries the off-site copy and rebuilds any file that changed."

      # The last attempt's lines: rclone's own output, redacted, per file.
      assert Enum.take(offsite_log(run, :error), -6) ==
               Enum.map(
                 files(dir, stamp),
                 &"Off-site copy of #{Path.basename(&1)} failed: #{rclone.exe} exited 1: upload refused\n"
               )

      assert [db, media] = run.artifacts
      assert db.verified and media.verified

      assert dest(db.destinations)["rclone:r2:kiln"] == %{
               "status" => "failed",
               "error" => "#{rclone.exe} exited 1: upload refused\n"
             }

      assert %{"status" => "failed"} = media.destinations["rclone:r2:kiln"]

      manifest = Manifest.read(dir)
      refute manifest.ok
      assert manifest.offsite == nil
      assert Backups.work_state?(stamp)
    end
  end

  describe "a remote with no rclone in the image" do
    # The exact Run error and manifest are pinned in `worker_test.exs` ("a remote
    # set with no rclone in the image fails the run, keeping it resumable").
    test "is fatal on the first attempt", %{base: base} do
      remote!("r2:kiln")
      no_rclone_on_path(base)

      assert {:error, {:offsite, :missing_rclone}} = BackupChain.run()

      job = offsite_job()
      assert job.attempt == 1
      assert job.state == "cancelled"

      run = run!()
      assert run.status == :failed

      assert offsite_log(run, :error) == [
               "BACKUP_RCLONE_REMOTE is set but rclone is not installed in this image; " <>
                 "nothing was copied off-site"
             ]

      assert Backups.work_state?(run.stamp)
    end
  end

  describe "a part changed after it verified" do
    # `worker_test.exs` pins the single-archive case; this is the part set.
    test "is refused on the first attempt, never uploaded, and marked unverified", %{
      base: base,
      dir: dir
    } do
      remote!("r2:kiln")
      rclone = fake_rclone!(base)
      gate!(rclone.tamper)

      assert {:error, {:offsite, %{refused: [{p2, {:changed, _}}], failed: []}}} =
               BackupChain.run()

      job = offsite_job()
      assert job.attempt == 1
      assert job.state == "cancelled"

      run = run!()
      stamp = run.stamp
      assert p2 == Artifact.part_name(stamp, 2)

      # Every other file still went, in order.
      assert lines(rclone.log) ==
               Enum.reject(copies(dir, stamp, "r2:kiln"), &String.contains?(&1, p2))

      assert run.status == :failed
      assert run.error =~ "Off-site copy REFUSED for 1 file: #{p2} (changed on disk"

      assert [db, media] = run.artifacts
      assert db.verified
      refute media.verified
      assert [one, two, three] = media.parts
      assert dest(one["destinations"])["rclone:r2:kiln"] == %{"status" => "ok"}

      assert %{"status" => "failed", "error" => "Refused: changed on disk" <> _} =
               two["destinations"]["rclone:r2:kiln"]

      assert dest(three["destinations"])["rclone:r2:kiln"] == %{"status" => "ok"}

      # The failure manifest unverifies only the refused file.
      manifest = Manifest.read(dir)
      refute manifest.ok

      assert Enum.map(manifest.artifacts, &{Path.basename(&1.path), &1.verified}) ==
               [
                 {"kiln-db-#{stamp}.dump", true},
                 {Artifact.part_name(stamp, 1), true},
                 {p2, false},
                 {Artifact.part_name(stamp, 3), true}
               ]
    end
  end

  # -- resume ----------------------------------------------------------------

  describe "a Resume after a failed copy" do
    # `resume_test.exs` pins that nothing is rebuilt and six files go again.
    test "copies every file again, with the same command lines, and succeeds", %{
      base: base,
      dir: dir
    } do
      remote!(@conn_remote)
      rclone = fake_rclone!(base)
      gate!(rclone.fail)

      assert {:error, {:offsite, _}} = BackupChain.run()
      stamp = run!().stamp
      File.rm!(rclone.fail)
      File.rm!(rclone.log)
      File.rm!(rclone.env)

      assert :ok = BackupChain.resume(stamp)

      assert lines(rclone.log) == copies(dir, stamp, "kiln_offsite:bucket")
      assert length(env_blocks(rclone)) == 6

      run = run!()
      assert run.stamp == stamp
      assert run.status == :succeeded

      key = "rclone:" <> @conn_redacted

      for artifact <- run.artifacts,
          do: assert(dest(artifact.destinations)[key] == %{"status" => "ok"})

      assert Manifest.read(dir).offsite == @conn_redacted
    end
  end
end
