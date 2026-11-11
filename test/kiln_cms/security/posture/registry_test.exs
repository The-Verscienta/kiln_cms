defmodule KilnCMS.Security.Posture.RegistryTest do
  @moduledoc """
  `KilnCMS.Security.Posture.Registry` (#2252): the core's checks, the
  dependency fixture plugin's (compiled against the SDK alone), and the
  `checks:` test seam; one id each, the core's always; `core.` reserved;
  non-conforming modules and broken callbacks skipped, never fatal.

  `async: false`: the seam is application env, which is node-wide.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Skipped modules are logged on purpose; the tests that care capture it.
  @moduletag :capture_log

  alias KilnCMS.Security.Posture.Registry

  defmodule TakesCoreId do
    use Kiln.Security.Check
    def id, do: "core.second_factor"
    def title, do: "Impostor"
    def scope, do: :site
    def run(_context), do: pass("Everything is fine.")
  end

  defmodule NewCoreId do
    use Kiln.Security.Check
    def id, do: "core.brand_new"
    def title, do: "Squatter"
    def scope, do: :site
    def run(_context), do: pass("ok")
  end

  defmodule SameAsFixture do
    use Kiln.Security.Check
    def id, do: "dep_fixture.build_env"
    def title, do: "Second claimant"
    def scope, do: :site
    def run(_context), do: pass("ok")
  end

  defmodule Slow do
    use Kiln.Security.Check
    def id, do: "test.slow"
    def title, do: "Slow"
    def scope, do: :deployment
    def timeout, do: 60_000
    def run(_context), do: pass("ok")
  end

  defmodule BadTitle do
    use Kiln.Security.Check
    def id, do: "test.bad_title"
    def title, do: "ok" <> <<0xFF>>
    def description, do: "fine" <> <<0xFE>>
    def scope, do: :site
    def run(_context), do: pass("ok")
  end

  defmodule BadNamePlugin do
    def name, do: "p" <> <<0xFF>>
  end

  defmodule NotACheck do
    def id, do: "test.not_a_check"
  end

  defmodule OldPlugin do
    def name, do: "old"
  end

  defmodule RaisingPlugin do
    use Kiln.Plugin
    def security_checks, do: raise("boom")
  end

  defmodule SloppyPlugin do
    use Kiln.Plugin
    def security_checks, do: [Slow, "not a module", {Slow, []}]
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Security.Posture, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Security.Posture, original) end)
    :ok
  end

  defp seam!(checks) do
    Application.put_env(:kiln_cms, KilnCMS.Security.Posture, checks: checks)
  end

  defp ids, do: Enum.map(Registry.checks(), & &1.id)

  test "the core's checks come first, each with the core as its source" do
    checks = Registry.checks()
    core_ids = Enum.map(Registry.core(), & &1.id())

    assert Enum.take(Enum.map(checks, & &1.id), length(core_ids)) == core_ids
    assert Enum.all?(Enum.take(checks, length(core_ids)), &(&1.source == :core))
  end

  test "a plugin compiled as a dependency contributes its check" do
    assert KilnDepFixture.SecurityCheck in Registry.plugin_checks()
    assert KilnDepFixture.SecurityCheck in Kiln.Plugins.security_checks()

    assert %{scope: :site, source: {:plugin, "kiln_dep_fixture"}, timeout: 1000} =
             Enum.find(Registry.checks(), &(&1.id == "dep_fixture.build_env"))

    manifest = Enum.find(Kiln.Plugins.manifests(), &(&1.module == KilnDepFixture.Plugin))
    assert manifest.security_checks == [KilnDepFixture.SecurityCheck]
  end

  test "a core id is never displaced, nor a new one under core. taken" do
    seam!([TakesCoreId, NewCoreId])

    log = capture_log(fn -> send(self(), {:ids, ids()}) end)
    assert_received {:ids, ids}

    assert Enum.count(ids, &(&1 == "core.second_factor")) == 1
    refute "core.brand_new" in ids

    assert Enum.find(Registry.checks(), &(&1.id == "core.second_factor")).source == :core
    assert log =~ "reserved id"
  end

  test "the first module registered under an id wins" do
    seam!([SameAsFixture])

    capture_log(fn ->
      check = Enum.find(Registry.checks(), &(&1.id == "dep_fixture.build_env"))
      assert check.module == KilnDepFixture.SecurityCheck
    end)
  end

  test "a module that is not a check is skipped and logged" do
    seam!([NotACheck, Slow])

    log = capture_log(fn -> send(self(), {:ids, ids()}) end)
    assert_received {:ids, ids}

    assert "test.slow" in ids
    refute "test.not_a_check" in ids
    assert log =~ "not a usable check"
  end

  test "a check's own timeout is held to the core's bounds" do
    seam!([Slow])
    assert Enum.find(Registry.checks(), &(&1.id == "test.slow")).timeout == 5000
    assert Registry.clamp(1) == 100
  end

  test "a plugin without the callback, or whose callback raises, contributes nothing" do
    assert Registry.of_plugin(OldPlugin) == []
    assert Registry.of_plugin(NotLoadedAnywhere) == []
    assert Registry.of_plugin(RaisingPlugin) == []
    assert Registry.of_plugin(SloppyPlugin) == [Slow]
  end

  test "a title that is not valid UTF-8 is repaired, and the check kept" do
    seam!([BadTitle])

    assert %{title: "ok\uFFFD", description: "fine\uFFFD"} =
             Enum.find(Registry.checks(), &(&1.id == "test.bad_title"))
  end

  test "a plugin name that is not valid UTF-8 is replaced by the module name" do
    assert Registry.plugin_name(BadNamePlugin) == inspect(BadNamePlugin)
    assert Registry.plugin_name(OldPlugin) == "old"
    assert Registry.plugin_name(NotLoadedAnywhere) == "NotLoadedAnywhere"
  end
end
