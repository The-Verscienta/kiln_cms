defmodule Mix.Tasks.Kiln.Plugins.ListHealthTest do
  @moduledoc """
  `mix kiln.plugins.list --health` (#2244): off by default, so the plain
  listing makes no request; with the flag it checks every plugin even when the
  server's own check is turned off. Requests go to the `Kiln.Plugins.Health`
  Req.Test stub.
  """
  # async: false - the task flips `Kiln.Plugins.Health`'s app env for the
  # length of the check, and the check's cache is a VM-wide :persistent_term.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.PluginStatus
  alias Mix.Tasks.Kiln.Plugins.List

  @moduletag :capture_log

  setup do
    original = Application.get_env(:kiln_cms, Health, [])
    Health.clear_cache()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Health, original)
      Health.clear_cache()
    end)

    %{original: original}
  end

  defp stub(notices) do
    test = self()

    Req.Test.stub(Health, fn conn ->
      send(test, {:health_request, conn.request_path})
      notices.(conn)
    end)
  end

  defp run_task(argv), do: capture_io(fn -> assert List.run(argv) == :ok end)

  test "without --health nothing is asked and no status is printed" do
    stub(&Req.Test.json(&1, %{"data" => []}))

    output = run_task([])

    refute output =~ "health:"
    refute_received {:health_request, _path}
  end

  test "--health checks even when the server's check is off, and leaves it off",
       %{original: original} do
    refute Health.enabled?()
    stub(&Req.Test.json(&1, %{"data" => []}))

    output = run_task(["--health"])

    assert_received {:health_request, "/api/json/entries/published"}
    assert output =~ "Plugin checks are turned off for the server; checking anyway"
    assert output =~ "health: built from this project"
    assert output =~ "health: can't verify (git or path: no registry checksum)"
    assert output =~ "Checked against hex.pm and the security notices feed."
    assert Application.get_env(:kiln_cms, Health, []) == original
  end

  test "--health with an unreachable feed says unknown, not ok" do
    stub(&Plug.Conn.send_resp(&1, 503, ""))

    output = run_task(["--health"])

    assert output =~ "health: unknown (not ok: a source did not answer)"
    assert output =~ "could not be reached"
    refute output =~ "health: ok"
  end

  test "a package that changed on Hex prints as a failure with both checksums" do
    status = %PluginStatus{
      plugin: FakeHexPlugin,
      name: "fake",
      source: :hex,
      version: "1.4.5",
      integrity: {:mismatch, %{locked: "b0c823996102bcd0", registry: "ffffffffffff0000"}},
      advisories: {:ok, []},
      overall: :fail
    }

    assert List.format_health(status) ==
             "    health: FAIL\n" <>
               "      - changed on Hex since this build: locked b0c823996102, Hex has ffffffffffff"
  end
end
