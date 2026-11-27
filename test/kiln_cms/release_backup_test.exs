defmodule KilnCMS.ReleaseBackupTest do
  @moduledoc """
  `KilnCMS.Release.backup/1` (#2234), the release side of `bin/backup`: the
  argv arrives base64-encoded and is decoded, never evaluated; `run`,
  `rescan` and `prune` are refused under `eval` before anything starts;
  `verify` is refused under `rpc`; exit codes travel as
  `exit({:shutdown, code})`, which `bin/kiln_cms eval` and `rpc` turn into
  exactly that exit status without stopping the serving node.

  The commands themselves are `KilnCMS.Backups.CLITest`'s; the overlay that
  encodes the argv is `KilnCMS.Scripts.BackupOverlayTest`'s.

  `async: false`: it changes the VM-wide `KilnCMS.Backups` and
  `KilnCMS.Cache` env, and the logger's handlers.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Backups
  alias KilnCMS.Release

  @moduletag :capture_log

  setup do
    dir =
      Path.join(System.tmp_dir!(), "kiln_release_backup_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    backups = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    cache = Application.get_env(:kiln_cms, KilnCMS.Cache)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(backups, dir: dir, enabled: true)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, backups)

      if cache,
        do: Application.put_env(:kiln_cms, KilnCMS.Cache, cache),
        else: Application.delete_env(:kiln_cms, KilnCMS.Cache)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # What `rel/overlays/bin/backup` sends: `printf '%s\n' "$@" | base64`.
  defp enc([]), do: ""
  defp enc(argv), do: Base.encode64(Enum.map_join(argv, &(&1 <> "\n")))

  # `{:ok | {:exit, reason}, stdout}`.
  defp backup(argv, serving?, opts \\ []) do
    test = self()

    out =
      capture_io(fn ->
        result =
          try do
            Release.run_backup(enc(argv), serving?, opts)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(test, {:result, result})
      end)

    assert_received {:result, result}
    {result, out}
  end

  defp refusing_with_repo(test) do
    fn _repo, _fun ->
      send(test, :with_repo)
      {:error, :unexpected}
    end
  end

  describe "decode_backup_argv/1" do
    test "round-trips what the overlay encodes, empty and odd arguments included" do
      for argv <- [
            [],
            ["verify", "20261118-031700", "--json"],
            ["verify", ""],
            [""],
            ["it's", "a b", "$(touch pwned)", "#{"\#{System.halt()}"}", "\\", "é"]
          ] do
        assert Release.decode_backup_argv(enc(argv)) == {:ok, argv}
      end
    end

    test "refuses what is not base64 of UTF-8" do
      assert Release.decode_backup_argv("not base64!") == :error
      assert Release.decode_backup_argv(Base.encode64(<<0xFF, 0xFE, ?\n>>)) == :error
      assert Release.decode_backup_argv(nil) == :error
    end
  end

  test "malformed arguments exit 2" do
    out =
      capture_io(fn ->
        assert {:shutdown, 2} = catch_exit(Release.run_backup("%%%", false))
      end)

    assert out == "bin/backup: malformed arguments\n"
  end

  describe "under eval (not serving)" do
    test "run, rescan and prune are refused before the app is loaded" do
      test = self()
      cache = Application.get_env(:kiln_cms, KilnCMS.Cache)

      for command <- ~w(run rescan prune) do
        {result, out} =
          backup([command], false,
            with_repo: refusing_with_repo(test),
            logger_to_stderr: fn -> send(test, :logger) end,
            cli: [importer: fn -> send(test, :imported) end]
          )

        assert result == {:exit, {:shutdown, 1}}
        assert out =~ "needs the running application"
      end

      refute_received :with_repo
      refute_received :imported
      assert Application.get_env(:kiln_cms, KilnCMS.Cache) == cache
      assert Backups.backup_lock!(actor: Backups.system()) == nil
      refute_received :logger
    end

    test "help and usage errors start nothing" do
      test = self()

      assert {:ok, "Usage:" <> _} = backup(["help"], false, with_repo: refusing_with_repo(test))

      assert {{:exit, {:shutdown, 2}}, _out} =
               backup(["list", "--bogus"], false, with_repo: refusing_with_repo(test))

      assert {{:exit, {:shutdown, 2}}, _out} =
               backup([], false, with_repo: refusing_with_repo(test))

      refute_received :with_repo
    end

    test "list starts the repo and runs" do
      test = self()

      {result, out} =
        backup(["list", "--json"], false, logger_to_stderr: fn -> send(test, :logger) end)

      assert result == :ok
      # The log moves off stdout, which a --json reader parses.
      assert_received :logger
      assert %{"command" => "list", "ok" => true} = Jason.decode!(out)
      # `load_app` ran: an eval VM reads through its cache.
      refute Application.get_env(:kiln_cms, KilnCMS.Cache)[:enabled]
    end

    test "a repo that can't start exits 1 and says so" do
      {result, out} =
        backup(["verify", "20261118-031700", "--json"], false,
          with_repo: fn _repo, _fun -> {:error, :econnrefused} end,
          logger_to_stderr: fn -> :ok end
        )

      assert result == {:exit, {:shutdown, 1}}
      assert %{"error" => %{"code" => "database_unreachable"}} = Jason.decode!(out)
    end
  end

  describe "under rpc (serving)" do
    test "verify is refused with 2" do
      {result, out} = backup(["verify", "20261118-031700"], true)
      assert result == {:exit, {:shutdown, 2}}
      assert out =~ "runs beside the application"
    end

    test "rescan runs, and a failure exits without halting the node" do
      assert {:ok, out} = backup(["rescan"], true)
      assert out =~ "Rescanned"

      # The importer's grant taken away: its reads are refused.
      {result, out} = Backups.with_actor(nil, fn -> backup(["rescan", "--json"], true) end)
      assert result == {:exit, {:shutdown, 1}}
      assert %{"ok" => false} = Jason.decode!(out)
      assert Process.alive?(self())
    end
  end

  test "logger_to_stderr/1 moves a std handler to standard_error, config kept" do
    id = :"kiln_release_backup_test_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(id, :logger_std_h, %{
        level: :critical,
        config: %{type: :standard_io, burst_limit_enable: false}
      })

    on_exit(fn -> :logger.remove_handler(id) end)

    assert :ok = Release.logger_to_stderr(id)

    assert {:ok, %{level: :critical, config: %{type: :standard_error, burst_limit_enable: false}}} =
             :logger.get_handler_config(id)
  end

  # Under rpc, a halt would stop the serving node, not the operator's
  # `bin/backup`. The exit-code transport is `exit({:shutdown, code})`.
  test "nothing on the CLI path halts the VM" do
    for path <-
          ~w(lib/kiln_cms/release.ex lib/kiln_cms/backups/cli.ex lib/kiln_cms/backups/verify.ex) do
      refute File.read!(path) =~ ~r/System\.halt|:erlang\.halt|:init\.stop/, path
    end
  end

  # Canaries for the Elixir behaviour the exit codes rely on, found by reading
  # `Kernel.CLI` (1.20): `bin/kiln_cms rpc` calls `Kernel.CLI.rpc_eval/1` on
  # the server through `:erpc.call/4`, which evaluates the expression inside
  # a `try ... catch kind, reason -> {kind, reason, stack}`, so an exit stays in
  # that call's process on the server; the client re-raises it in its
  # `exec_fun/2`, which turns `exit({:shutdown, n})` into exit status n with
  # no stack trace. `rpc_eval/1` is undocumented: this is brittle on purpose,
  # so a toolchain bump that changes it fails here rather than in production.
  describe "Kernel.CLI" do
    test "rpc_eval/1 catches an exit on the evaluating side" do
      assert {:exit, {:shutdown, 2}, _stack} = Kernel.CLI.rpc_eval(~c"exit({:shutdown, 2})")
    end

    test "a re-raised {:shutdown, n} exit, and a plain one, exit with n" do
      elixir = System.find_executable("elixir")

      assert {_out, 2} = System.cmd(elixir, ["-e", ":erlang.raise(:exit, {:shutdown, 2}, [])"])
      assert {_out, 2} = System.cmd(elixir, ["-e", "exit({:shutdown, 2})"])
      assert {_out, 1} = System.cmd(elixir, ["-e", "exit({:shutdown, 1})"])
    end
  end
end
