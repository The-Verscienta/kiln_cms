defmodule KilnCMS.Backups.OffsiteTest do
  @moduledoc """
  Off-site copies of part sets (#2218): one `rclone copy` per part and per
  checksum sidecar, per-part results on the run, one aggregate per artifact.
  The rclone binary is a stub on PATH that logs its arguments.
  """
  # `async: false`: `PATH` and `Application.put_env` are VM-global.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups.{Artifact, Recorder, Worker}

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
  defp stub_rclone(bin, log, fail_on \\ nil) do
    fail =
      if fail_on,
        do:
          ~S|case "$*" in *FAILON*) echo "Failed secret_access_key=SUPERSECRETVAL ($*)" >&2; exit 1;; esac|
          |> String.replace("FAILON", fail_on)
          |> Kernel.<>("\n"),
        else: ""

    path = Path.join(bin, "rclone")
    File.write!(path, ~s(#!/bin/sh\necho "$*" >> "#{log}"\n) <> fail <> "exit 0\n")
    File.chmod!(path, 0o755)
  end

  defp calls(log), do: log |> File.read!() |> String.split("\n", trim: true)

  # A three-part media set, a dump, and their sidecars, as the worker leaves them.
  defp land(dir) do
    names = Artifact.set_names(@stamp, 3)
    for name <- names, do: File.write!(Path.join([dir, "media", name]), "x")
    File.write!(Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)]), "sums")
    File.write!(Path.join([dir, "db", "kiln-db-#{@stamp}.dump"]), "d")
    File.write!(Path.join([dir, "db", Artifact.sidecar_name(:db, @stamp)]), "sums")

    entries =
      for {name, i} <- Enum.with_index(names, 1) do
        %{
          kind: "media",
          path: "media/#{name}",
          bytes: 1,
          verified: true,
          sha256: String.duplicate("a", 63) <> "#{i}",
          part: i,
          parts_total: 3
        }
      end

    [%{kind: "db", path: "db/kiln-db-#{@stamp}.dump", bytes: 1, verified: true}] ++ entries
  end

  defp recorder(entries) do
    rec = %Recorder{components: [:db, :media]}

    flat =
      for entry <- entries do
        {:ok, attrs} = Artifact.from_manifest(entry)
        attrs
      end

    %{rec | artifacts: Artifact.group_files(flat)}
  end

  test "one rclone copy per part and per sidecar, into db/ and media/",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log)
    entries = land(dir)

    assert {@remote, results} = Worker.offsite_results(dir, entries)
    assert Enum.all?(results, &match?({_, :ok}, &1))

    sent = calls(log)
    assert length(sent) == 6

    for name <- Artifact.set_names(@stamp, 3) do
      assert "copy #{dir}/media/#{name} #{@remote}/media" in sent
    end

    assert "copy #{dir}/media/#{Artifact.sidecar_name(:media, @stamp)} #{@remote}/media" in sent
    assert "copy #{dir}/db/kiln-db-#{@stamp}.dump #{@remote}/db" in sent
    assert "copy #{dir}/db/#{Artifact.sidecar_name(:db, @stamp)} #{@remote}/db" in sent
  end

  test "a missing sidecar (legacy cron file) is simply not copied", %{
    dir: dir,
    bin: bin,
    log: log
  } do
    stub_rclone(bin, log)
    File.write!(Path.join([dir, "media", "kiln-media-#{@stamp}.tar.gz"]), "x")

    entry = %{kind: "media", path: "media/kiln-media-#{@stamp}.tar.gz", bytes: 1, verified: true}
    assert {_remote, [{^entry, :ok}]} = Worker.offsite_results(dir, [entry])
    assert length(calls(log)) == 1
  end

  test "a failing part is recorded failed with the secret redacted; the aggregate follows",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log, "part02")
    entries = land(dir)

    {offsite, rec} = Worker.offsite_step(dir, entries, recorder(entries))

    # All-or-nothing, as ever: a part that didn't arrive means no off-site claim.
    assert offsite == nil

    key = "rclone:" <> KilnCMS.Backups.Redact.text(@remote)
    refute key =~ "SUPERSECRETVAL"

    assert [db, media] = rec.artifacts
    assert %{"status" => "ok"} = db.destinations[key]

    assert [one, two, three] = media.parts
    assert %{"status" => "ok"} = one["destinations"][key]
    assert %{"status" => "failed", "error" => error} = two["destinations"][key]
    assert error != ""
    assert %{"status" => "ok"} = three["destinations"][key]

    # worst-first aggregate on the artifact
    assert %{"status" => "failed", "error" => ^error} = media.destinations[key]

    refute inspect(rec) =~ "SUPERSECRETVAL"
    refute inspect(rec) =~ "AKIAEXAMPLE1"
  end

  test "every part reaching the remote makes the artifact ok", %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log)
    entries = land(dir)

    {offsite, rec} = Worker.offsite_step(dir, entries, recorder(entries))
    assert offsite == @remote

    key = "rclone:" <> KilnCMS.Backups.Redact.text(@remote)
    assert [_db, media] = rec.artifacts
    assert %{"status" => "ok"} = media.destinations[key]
    assert Enum.all?(media.parts, &(&1["destinations"][key]["status"] == "ok"))
  end

  test "a failing sidecar is logged but does not fail the artifact",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log, ".sha256")
    entries = land(dir)

    {offsite, rec} = Worker.offsite_step(dir, entries, recorder(entries))
    assert offsite == @remote

    key = "rclone:" <> KilnCMS.Backups.Redact.text(@remote)
    assert [_db, media] = rec.artifacts
    assert %{"status" => "ok"} = media.destinations[key]

    assert Enum.any?(rec.log, &(&1.level == :warn and &1.message =~ ".sha256 failed"))
    refute inspect(rec) =~ "SUPERSECRETVAL"
  end

  test "copy_offsite/2 keeps its signature and answers for the whole set",
       %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log)
    entries = land(dir)
    assert Worker.copy_offsite(dir, entries) == @remote

    stub_rclone(bin, log, "part03")
    assert Worker.copy_offsite(dir, entries) == nil
  end

  test "with no remote nothing is copied", %{dir: dir, bin: bin, log: log} do
    stub_rclone(bin, log)
    Application.put_env(:kiln_cms, KilnCMS.Backups, rclone_remote: nil, dir: dir)
    assert Worker.offsite_results(dir, land(dir)) == nil
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
