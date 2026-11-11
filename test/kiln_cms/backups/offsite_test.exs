defmodule KilnCMS.Backups.OffsiteTest do
  @moduledoc """
  Off-site copies of part sets (#2218): one `rclone copy` per part and per
  checksum sidecar, per-part results on the run, one aggregate per artifact.
  The rclone binary is a stub on PATH that logs its arguments.
  """
  # `async: false`: `PATH` and `Application.put_env` are VM-global.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups.{Artifact, Checksum, Recorder, Worker}

  @moduletag :capture_log

  @stamp "20260805-031700"
  @remote ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_off_#{System.unique_integer([:positive])}")
    for sub <- ["db", "media"], do: File.mkdir_p!(Path.join(dir, sub))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, dir: dir, rclone_remote: @remote)
    )

    path = System.get_env("PATH")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    System.put_env("PATH", bin <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir, bin: bin, log: Path.join(dir, "rclone.log")}
  end

  # An rclone that logs `$*` and fails (with the secret in its output) for any
  # call whose arguments match `fail_on`.
  defp stub_rclone(bin, log, fail_on \\ nil, extra \\ "") do
    fail =
      if fail_on,
        do:
          ~S|case "$*" in *FAILON*) echo "Failed secret_access_key=SUPERSECRETVAL ($*)" >&2; exit 1;; esac|
          |> String.replace("FAILON", fail_on)
          |> Kernel.<>("\n"),
        else: ""

    path = Path.join(bin, "rclone")
    File.write!(path, ~s(#!/bin/sh\necho "$*" >> "#{log}"\n) <> fail <> extra <> "exit 0\n")
    File.chmod!(path, 0o755)
  end

  defp uploaded?(log, path), do: Enum.any?(calls(log), &String.contains?(&1, " #{path} "))

  defp calls(log) do
    case File.read(log) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # A three-part media set, a dump, and their sidecars, as the worker leaves
  # them: real bytes, the digests recorded for them, and sidecars that say so.
  defp land(dir) do
    names = Artifact.set_names(@stamp, 3)

    entries =
      for {name, i} <- Enum.with_index(names, 1) do
        path = Path.join([dir, "media", name])
        File.write!(path, "part #{i} bytes")
        {:ok, hex, bytes} = Checksum.file(path)

        %{
          kind: "media",
          path: "media/#{name}",
          bytes: bytes,
          verified: true,
          sha256: hex,
          part: i,
          parts_total: 3
        }
      end

    :ok =
      Checksum.write_sidecar(
        Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)]),
        Enum.map(entries, &{Path.basename(&1.path), &1.sha256})
      )

    dump = Path.join([dir, "db", "kiln-db-#{@stamp}.dump"])
    File.write!(dump, "PGDMP dump bytes")
    {:ok, hex, bytes} = Checksum.file(dump)

    :ok =
      Checksum.write_sidecar(Path.join([dir, "db", Artifact.sidecar_name(:db, @stamp)]), [
        {Path.basename(dump), hex}
      ])

    [
      %{kind: "db", path: "db/kiln-db-#{@stamp}.dump", bytes: bytes, verified: true, sha256: hex}
      | entries
    ]
  end

  defp part(dir, i), do: Path.join([dir, "media", Artifact.part_name(@stamp, i)])
  defp media_sidecar(dir), do: Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)])
  defp key, do: "rclone:" <> KilnCMS.Backups.Redact.text(@remote)

  defp recorder(entries) do
    rec = %Recorder{components: [:db, :media]}

    flat =
      for entry <- entries do
        {:ok, attrs} = Artifact.from_manifest(entry)
        attrs
      end

    %{rec | artifacts: Artifact.group_files(flat)}
  end

  test "one rclone copy per part and per sidecar, into db/ and media/, in order",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log)
    entries = land(dir)

    assert {@remote, results} = Worker.offsite_results(dir, entries)
    assert Enum.all?(results, &match?({_, :ok}, &1))

    names = Artifact.set_names(@stamp, 3)

    # The connection string's parameters went to rclone's environment, so
    # its argv names the remote it defines there (#2690).
    assert calls(log) ==
             ["copy #{dir}/db/kiln-db-#{@stamp}.dump kiln_offsite:bucket/db"] ++
               for(name <- names, do: "copy #{dir}/media/#{name} kiln_offsite:bucket/media") ++
               [
                 "copy #{dir}/db/#{Artifact.sidecar_name(:db, @stamp)} kiln_offsite:bucket/db",
                 "copy #{media_sidecar(dir)} kiln_offsite:bucket/media"
               ]
  end

  describe "a connection-string remote's credentials (#2690)" do
    # An rclone that logs its argv to `log` and its RCLONE_CONFIG_* environment
    # to `log.env`, one block per call.
    defp stub_rclone_env(bin, log) do
      stub_rclone(
        bin,
        log,
        nil,
        ~s(env | grep '^RCLONE_CONFIG_' | sort >> "#{log}.env"\necho -- >> "#{log}.env"\n)
      )
    end

    test "reach rclone through its environment, never its argv",
         %{dir: dir, bin: bin, log: log} do
      stub_rclone_env(bin, log)
      entries = land(dir)

      assert {@remote, results} = Worker.offsite_results(dir, entries)
      assert Enum.all?(results, &match?({_, :ok}, &1))

      assert [_ | _] = calls = calls(log)

      for call <- calls do
        refute call =~ "SUPERSECRETVAL"
        refute call =~ "AKIAEXAMPLE1"
        refute call =~ "secret_access_key"
      end

      blocks = (log <> ".env") |> File.read!() |> String.split("--\n", trim: true)
      assert length(blocks) == length(calls)

      for block <- blocks do
        assert String.split(block, "\n", trim: true) == [
                 "RCLONE_CONFIG_KILN_OFFSITE_ACCESS_KEY_ID=AKIAEXAMPLE1",
                 "RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY=SUPERSECRETVAL",
                 "RCLONE_CONFIG_KILN_OFFSITE_TYPE=s3"
               ]
      end

      # Only rclone's: the app's own environment is untouched.
      refute System.get_env("RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY")
    end

    test "a named remote is passed as it is, with no environment",
         %{dir: dir, bin: bin, log: log} do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, "r2:kiln")
      )

      stub_rclone_env(bin, log)
      entries = land(dir)

      assert {"r2:kiln", _results} = Worker.offsite_results(dir, entries)
      assert hd(calls(log)) == "copy #{dir}/db/kiln-db-#{@stamp}.dump r2:kiln/db"
      assert (log <> ".env") |> File.read!() |> String.replace("--\n", "") == ""
    end
  end

  describe "re-hash before each copy (#2218)" do
    test "a part changed after it verified is refused, not uploaded; the others are", %{
      dir: dir,
      bin: bin,
      log: log
    } do
      stub_rclone(bin, log)
      entries = land(dir)
      %{sha256: recorded} = Enum.at(entries, 2)

      # Same size, different bytes: only a re-hash notices.
      File.write!(part(dir, 2), "part 9 bytes")
      {:ok, found, _} = Checksum.file(part(dir, 2))

      {result, log_output} =
        ExUnit.CaptureLog.with_log(fn ->
          Worker.offsite_step(dir, entries, recorder(entries))
        end)

      assert {:error, {:offsite, %{refused: [{name, _}], failed: []}}, rec} = result
      assert name == Artifact.part_name(@stamp, 2)

      refute uploaded?(log, part(dir, 2))
      assert uploaded?(log, part(dir, 1))
      assert uploaded?(log, part(dir, 3))
      assert uploaded?(log, media_sidecar(dir))
      assert length(calls(log)) == 5

      assert [db, media] = rec.artifacts
      assert db.verified
      refute media.verified

      assert [one, two, three] = media.parts
      assert %{"status" => "ok"} = one["destinations"][key()]
      assert %{"status" => "failed", "error" => "Refused: " <> why} = two["destinations"][key()]
      assert why =~ "changed on disk"
      assert %{"status" => "ok"} = three["destinations"][key()]
      assert %{"status" => "failed", "error" => "Refused: " <> _} = media.destinations[key()]

      # Loud, with both full digests, in the log and on the Run log.
      assert log_output =~ "REFUSED"
      assert log_output =~ recorded
      assert log_output =~ found

      assert Enum.any?(
               rec.log,
               &(&1.level == :error and &1.message =~ "REFUSED" and &1.message =~ found)
             )
    end

    test "the real race: a file changed WHILE the previous one uploads is refused", %{
      dir: dir,
      bin: bin,
      log: log
    } do
      # rclone, uploading part01, appends to part02 — after any up-front check
      # would have passed it.
      stub_rclone(
        bin,
        log,
        nil,
        ~s|case "$2" in *part01*) printf tampered >> "#{part(dir, 2)}" ;; esac\n|
      )

      entries = land(dir)

      assert {:error, {:offsite, %{refused: [{name, {:changed, changed}}]}}, _rec} =
               Worker.offsite_step(dir, entries, recorder(entries))

      assert name == Artifact.part_name(@stamp, 2)
      assert changed.bytes > changed.expected_bytes
      assert uploaded?(log, part(dir, 1))
      refute uploaded?(log, part(dir, 2))
      assert uploaded?(log, part(dir, 3))
    end

    test "a sidecar rewritten after it was written is refused; the artifacts still go", %{
      dir: dir,
      bin: bin,
      log: log
    } do
      stub_rclone(bin, log)
      entries = land(dir)
      {:ok, [{h1, _n1}, {h2, n2}, {h3, n3}]} = Checksum.parse_sidecar(media_sidecar(dir))
      File.write!(media_sidecar(dir), "#{h1}  #{n3}\n#{h2}  #{n2}\n#{h3}  #{n3}\n")

      assert {:error, {:offsite, %{refused: [{sidecar, :sidecar_changed}], failed: []}}, rec} =
               Worker.offsite_step(dir, entries, recorder(entries))

      assert sidecar == Artifact.sidecar_name(:media, @stamp)
      refute uploaded?(log, media_sidecar(dir))
      for i <- 1..3, do: assert(uploaded?(log, part(dir, i)))

      # The data itself is what it verified: the artifact is not marked down.
      assert [_db, media] = rec.artifacts
      assert media.verified
      assert %{"status" => "ok"} = media.destinations[key()]
    end

    test "a missing sidecar is refused, not skipped", %{dir: dir, bin: bin, log: log} do
      stub_rclone(bin, log)
      entries = land(dir)
      File.rm!(media_sidecar(dir))

      assert {:error, {:offsite, %{refused: [{_sidecar, :enoent}]}}, _rec} =
               Worker.offsite_step(dir, entries, recorder(entries))

      assert length(calls(log)) == 5
    end

    test "a file with no recorded digest is refused and rclone is never called for it", %{
      dir: dir,
      bin: bin,
      log: log
    } do
      stub_rclone(bin, log)
      [db | parts] = land(dir)
      entries = [Map.delete(db, :sha256) | parts]

      assert {:error, {:offsite, %{refused: refused}}, _rec} =
               Worker.offsite_step(dir, entries, recorder(entries))

      # The dump, and its sidecar (whose expected line has no digest either).
      assert {"kiln-db-#{@stamp}.dump", :no_digest} in refused
      assert {Artifact.sidecar_name(:db, @stamp), :no_digest} in refused
      refute uploaded?(log, Path.join([dir, "db", "kiln-db-#{@stamp}.dump"]))
    end

    test "a refused file and a failed upload are told apart, and no secret leaks", %{
      dir: dir,
      bin: bin,
      log: log
    } do
      stub_rclone(bin, log, "part03")
      entries = land(dir)
      File.write!(part(dir, 2), "part 9 bytes")

      assert {:error, {:offsite, problems} = reason, rec} =
               Worker.offsite_step(dir, entries, recorder(entries))

      assert [{refused, {:changed, _}}] = problems.refused
      assert refused == Artifact.part_name(@stamp, 2)
      assert [{failed, {:exit_status, _rclone, 1, _}}] = problems.failed
      assert failed == Artifact.part_name(@stamp, 3)

      assert [_db, media] = rec.artifacts
      assert [_one, two, three] = media.parts
      assert "Refused: " <> _ = two["destinations"][key()]["error"]
      assert %{"status" => "failed", "error" => error} = three["destinations"][key()]
      refute error =~ "Refused"
      assert error =~ "rclone exited 1"

      text = Worker.describe_offsite(reason, true)
      assert text =~ "Off-site copy REFUSED for 1 file: #{refused} (changed on disk"
      assert text =~ "Off-site copy FAILED for 1 file: #{failed} (rclone exited 1)"
      assert text =~ "Resume retries the off-site copy"
      # Short: names and reasons, never rclone's output.
      refute text =~ "Failed secret"

      for haystack <- [inspect(rec), text] do
        refute haystack =~ "SUPERSECRETVAL"
        refute haystack =~ "AKIAEXAMPLE1"
      end
    end

    test "more than five files per section are summarised" do
      failed = for i <- 1..7, do: {"f#{i}", {:exit_status, "rclone", 1, ""}}
      text = Worker.describe_offsite({:offsite, %{refused: [], failed: failed}}, false)

      assert text =~ "FAILED for 7 files: f1 (rclone exited 1)"
      assert text =~ "f5 (rclone exited 1) and 2 more."
      refute text =~ "f6"
      refute text =~ "REFUSED"
      assert text =~ "run a new backup"
    end
  end

  test "a failing part is recorded failed with the secret redacted; the aggregate follows",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log, "part02")
    entries = land(dir)

    assert {:error, {:offsite, %{failed: [_], refused: []}}, rec} =
             Worker.offsite_step(dir, entries, recorder(entries))

    refute key() =~ "SUPERSECRETVAL"

    assert [db, media] = rec.artifacts
    assert %{"status" => "ok"} = db.destinations[key()]
    # A failed upload is not a changed file: still verified.
    assert media.verified

    assert [one, two, three] = media.parts
    assert %{"status" => "ok"} = one["destinations"][key()]
    assert %{"status" => "failed", "error" => error} = two["destinations"][key()]
    assert error != ""
    assert %{"status" => "ok"} = three["destinations"][key()]

    # worst-first aggregate on the artifact
    assert %{"status" => "failed", "error" => ^error} = media.destinations[key()]

    refute inspect(rec) =~ "SUPERSECRETVAL"
    refute inspect(rec) =~ "AKIAEXAMPLE1"
  end

  test "every file reaching the remote makes the artifact ok and the step ok", %{
    dir: dir,
    bin: bin,
    log: log
  } do
    stub_rclone(bin, log)
    entries = land(dir)

    assert {:ok, @remote, rec} = Worker.offsite_step(dir, entries, recorder(entries))

    assert [_db, media] = rec.artifacts
    assert %{"status" => "ok"} = media.destinations[key()]
    assert Enum.all?(media.parts, &(&1["destinations"][key()]["status"] == "ok"))
  end

  test "a failed sidecar copy fails the step, though the artifact's data arrived",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log, ".sha256")
    entries = land(dir)

    assert {:error, {:offsite, %{failed: failed, refused: []}}, rec} =
             Worker.offsite_step(dir, entries, recorder(entries))

    assert Enum.map(failed, &elem(&1, 0)) == [
             Artifact.sidecar_name(:db, @stamp),
             Artifact.sidecar_name(:media, @stamp)
           ]

    assert [_db, media] = rec.artifacts
    assert %{"status" => "ok"} = media.destinations[key()]

    assert Enum.any?(rec.log, &(&1.level == :error and &1.message =~ ".sha256 failed"))
    refute inspect(rec) =~ "SUPERSECRETVAL"
  end

  test "copy_offsite/2 answers the remote only when every file, sidecars too, arrived",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log)
    entries = land(dir)
    assert Worker.copy_offsite(dir, entries) == @remote

    stub_rclone(bin, log, "part03")
    assert Worker.copy_offsite(dir, entries) == nil

    stub_rclone(bin, log, ".sha256")
    assert Worker.copy_offsite(dir, entries) == nil

    stub_rclone(bin, log)
    File.write!(part(dir, 1), "part 8 bytes")
    assert Worker.copy_offsite(dir, entries) == nil
  end

  test "with no remote nothing is copied", %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log)
    Application.put_env(:kiln_cms, KilnCMS.Backups, rclone_remote: nil, dir: dir)
    entries = land(dir)
    assert Worker.offsite_results(dir, entries) == nil
    assert {:ok, nil, _rec} = Worker.offsite_step(dir, entries, recorder(entries))
    assert calls(log) == []
  end

  test "a remote with no rclone in the image fails the step, before any file is touched (#2482)",
       %{dir: dir, bin: bin} do
    # PATH holds only the (empty) stub directory: no rclone anywhere.
    System.put_env("PATH", bin)
    entries = land(dir)

    assert {:missing_rclone, @remote} = Worker.offsite_results(dir, entries)
    assert Worker.copy_offsite(dir, entries) == nil

    {result, log_output} =
      ExUnit.CaptureLog.with_log(fn -> Worker.offsite_step(dir, entries, recorder(entries)) end)

    # No remote in the reason: the chain logs `inspect(reason)` on failure.
    assert {:error, {:offsite, :missing_rclone} = reason, rec} = result
    assert log_output =~ "[error]"
    assert log_output =~ "rclone is not installed in this image"
    refute log_output =~ "SUPERSECRETVAL"

    assert Enum.any?(
             rec.log,
             &(&1.level == :error and
                 &1.message ==
                   "BACKUP_RCLONE_REMOTE is set but rclone is not installed in this image; " <>
                     "nothing was copied off-site")
           )

    # No destination is recorded: nothing was tried, so nothing is "failed"
    # per file, and nothing is unverified.
    for artifact <- rec.artifacts do
      assert artifact.verified
      refute Map.has_key?(artifact.destinations, key())
    end

    # The run's error says what is wrong and both ways out.
    text = Worker.describe_offsite(reason, true)
    assert text =~ "Off-site copy FAILED: BACKUP_RCLONE_REMOTE is set but rclone is not installed"
    assert text =~ "Install rclone in the image"
    assert text =~ "unset BACKUP_RCLONE_REMOTE, then Resume this backup."
    assert Worker.describe_offsite(reason, false) =~ "then run a new backup."

    for haystack <- [inspect(rec), inspect(reason), text] do
      refute haystack =~ "SUPERSECRETVAL"
      refute haystack =~ "AKIAEXAMPLE1"
    end
  end

  describe "Recorder.put_destination/4" do
    test "attaches a result to a part by file name, not by the logical artifact name" do
      rec = recorder(land_entries())
      rec = Recorder.put_destination(rec, Artifact.part_name(@stamp, 2), "rclone:r", :ok)

      assert [media] = rec.artifacts
      assert [one, two, three] = media.parts
      refute Map.has_key?(one["destinations"], "rclone:r")
      assert %{"status" => "ok"} = two["destinations"]["rclone:r"]
      refute Map.has_key?(three["destinations"], "rclone:r")
      # not all parts have it yet
      assert %{"status" => "pending"} = media.destinations["rclone:r"]
    end

    test "put_unverified/2 marks the set holding a part, or a single file, and nothing else" do
      rec =
        recorder(
          land_entries() ++ [%{kind: "db", path: "db/kiln-db-#{@stamp}.dump", verified: true}]
        )

      rec = %{rec | artifacts: Enum.map(rec.artifacts, &%{&1 | verified: true})}

      assert [media, db] = Recorder.put_unverified(rec, Artifact.part_name(@stamp, 3)).artifacts
      refute media.verified
      assert db.verified

      assert [media, db] = Recorder.put_unverified(rec, "kiln-db-#{@stamp}.dump").artifacts
      assert media.verified
      refute db.verified

      assert Recorder.put_unverified(rec, "nope.tar.gz") == rec
    end

    test "an unknown name leaves everything alone" do
      rec = recorder(land_entries())
      assert Recorder.put_destination(rec, "nope.tar.gz", "rclone:r", :ok) == rec
    end

    defp land_entries do
      for i <- 1..3 do
        %{
          kind: "media",
          path: "media/#{Artifact.part_name(@stamp, i)}",
          bytes: 1,
          part: i,
          parts_total: 3
        }
      end
    end
  end
end
