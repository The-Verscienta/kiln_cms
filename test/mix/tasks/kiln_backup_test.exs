defmodule Mix.Tasks.Kiln.BackupTest do
  @moduledoc """
  `mix kiln.backup.*` (#2234): each task hands its argv to
  `KilnCMS.Backups.CLI` as `mix kiln.backup.<command>`, prints what it
  returns, and exits non-zero the Mix way (`exit({:shutdown, code})`). The
  commands themselves are `KilnCMS.Backups.CLITest`'s.

  `async: false`: it changes the VM-wide `KilnCMS.Backups` env.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum}

  @moduletag :capture_log

  @stamp "20261118-031700"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_backup_task_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "media"))
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp media!(dir) do
    name = "kiln-media-#{@stamp}.tar.gz"
    File.write!(Path.join([dir, "media", name]), "media bytes")
    hex = :sha256 |> :crypto.hash("media bytes") |> Base.encode16(case: :lower)

    :ok =
      Checksum.write_sidecar(Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)]), [
        {name, hex}
      ])

    Backups.import_run!(
      %{
        stamp: @stamp,
        trigger: "cron",
        status: :succeeded,
        components: [:media],
        artifacts: [%{kind: :media, name: name, bytes: 11, sha256: hex, verified: true}]
      },
      actor: Backups.system()
    )

    Path.join([dir, "media", name])
  end

  test "each task delegates to its command and prints" do
    assert capture_io(fn -> assert :ok = Mix.Tasks.Kiln.Backup.List.run([]) end) ==
             "No backups recorded.\n"

    out = capture_io(fn -> :ok = Mix.Tasks.Kiln.Backup.List.run(["--json"]) end)
    assert %{"command" => "list", "ok" => true} = Jason.decode!(out)

    importer_out = capture_io(fn -> :ok = Mix.Tasks.Kiln.Backup.Rescan.run([]) end)
    assert importer_out =~ "Rescanned this host's backup directory"
  end

  test "a usage error exits 2, with the mix form of the usage" do
    out =
      capture_io(fn ->
        assert {:shutdown, 2} = catch_exit(Mix.Tasks.Kiln.Backup.Verify.run(["bogus"]))
      end)

    assert out =~ "mix kiln.backup.verify <stamp|id>"

    capture_io(fn ->
      assert {:shutdown, 2} = catch_exit(Mix.Tasks.Kiln.Backup.Prune.run(["--apply"]))
      assert {:shutdown, 2} = catch_exit(Mix.Tasks.Kiln.Backup.Run.run(["--components", "x"]))
    end)
  end

  test "verify: a pass returns, a changed file exits 1", %{dir: dir} do
    path = media!(dir)

    assert capture_io(fn -> assert :ok = Mix.Tasks.Kiln.Backup.Verify.run([@stamp]) end) =~
             "verified here"

    File.write!(path, "media bytez")

    out =
      capture_io(fn ->
        assert {:shutdown, 1} = catch_exit(Mix.Tasks.Kiln.Backup.Verify.run([@stamp]))
      end)

    assert out =~ "NOT verified"
  end
end
