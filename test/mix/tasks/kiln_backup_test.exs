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

  describe "the app a task starts" do
    # A checkout pointed at a deployment's database must not drain its jobs:
    # with `app.start`'s Oban, `mix kiln.backup.run` picked up its own backup
    # step and was killed mid-`pg_dump` when the task exited.
    test "has no Oban queue or plugin, is never the leader, and runs no heartbeat" do
      oban = Application.get_env(:kiln_cms, Oban)
      backups = Application.get_env(:kiln_cms, KilnCMS.Backups)

      on_exit(fn ->
        Application.put_env(:kiln_cms, Oban, oban)
        Application.put_env(:kiln_cms, KilnCMS.Backups, backups)
      end)

      # What a deployment's config looks like: queues and plugins, no testing mode.
      Application.put_env(
        :kiln_cms,
        Oban,
        oban
        |> Keyword.delete(:testing)
        |> Keyword.put(:plugins, [Oban.Plugins.Pruner])
      )

      refute KilnCMS.Application.oban_config()[:queues] in [nil, []]

      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(backups, :heartbeat?, true))

      assert :ok = KilnCMS.Backups.CLI.quiet_node_env()

      config =
        Oban.Config.new(
          AshOban.config(
            Application.fetch_env!(:kiln_cms, :ash_domains),
            KilnCMS.Application.oban_config()
          )
        )

      assert config.queues == []
      assert config.plugins == []
      assert config.peer == {Oban.Peers.Isolated, [leader?: false]}
      refute KilnCMS.Backups.Chain.heartbeat?()
    end

    test "no task asks Mix for the full app.start" do
      for path <- Path.wildcard("lib/mix/tasks/kiln.backup.*.ex") do
        refute File.read!(path) =~ ~r/^\s*@requirements/m, path
      end
    end

    test "the start step runs before the command" do
      test = self()

      capture_io(fn ->
        KilnCMS.Backups.CLI.mix_main("list", [], fn -> send(test, :started) end)
      end)

      assert_received :started
    end
  end
end
