defmodule KilnCMSWeb.BuildFingerprintTest do
  @moduledoc "The build fingerprint the HTML delivery ETag names (#2463)."
  # async: false — loads applications and recomputes the VM-global
  # fingerprint, which every HTML request in another test reads.
  use ExUnit.Case, async: false

  alias KilnCMSWeb.BuildFingerprint

  @apps [{:kiln_cms, ~c"1.8.0"}, {:phoenix, ~c"1.8.1"}]
  @modules [{KilnCMS.A, <<1::128>>}, {KilnCMS.B, <<2::128>>}]

  describe "compute/3" do
    test "is deterministic and ignores the order its inputs arrive in" do
      value = BuildFingerprint.compute(@apps, @modules, "manifest")

      assert value =~ ~r/^[0-9a-f]{16}$/
      assert BuildFingerprint.compute(@apps, @modules, "manifest") == value

      assert BuildFingerprint.compute(Enum.reverse(@apps), Enum.reverse(@modules), "manifest") ==
               value
    end

    test "moves with an application version, a module's code, or the asset manifest" do
      value = BuildFingerprint.compute(@apps, @modules, "manifest")

      bumped = List.keyreplace(@apps, :phoenix, 0, {:phoenix, ~c"1.8.2"})
      recompiled = List.keyreplace(@modules, KilnCMS.B, 0, {KilnCMS.B, <<3::128>>})

      for other <- [
            BuildFingerprint.compute(bumped, @modules, "manifest"),
            BuildFingerprint.compute(@apps, recompiled, "manifest"),
            BuildFingerprint.compute(@apps, @modules, "other manifest"),
            BuildFingerprint.compute(@apps, @modules, nil)
          ] do
        refute other == value
      end
    end
  end

  # Recompute from scratch, as a fresh node would, and put back what was there.
  defp recompute do
    BuildFingerprint.reset()
    BuildFingerprint.fingerprint()
  end

  describe "fingerprint/0" do
    setup do
      original = BuildFingerprint.fingerprint()
      on_exit(fn -> BuildFingerprint.put(original) end)
      %{original: original}
    end

    test "is 16 hex characters and the same on every call", %{original: original} do
      assert original =~ ~r/^[0-9a-f]{16}$/
      assert BuildFingerprint.fingerprint() == original
      assert recompute() == original
    end

    test "concurrent first callers all get the one value" do
      BuildFingerprint.reset()

      values =
        1..8
        |> Enum.map(fn _ -> Task.async(&BuildFingerprint.fingerprint/0) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert [_one] = Enum.uniq(values)
    end

    test "an unrelated application loaded later does not move it", %{original: original} do
      app = :"kiln_fingerprint_late_#{System.unique_integer([:positive])}"

      spec = [
        description: ~c"test",
        vsn: ~c"0.1.0",
        modules: [],
        registered: [],
        applications: [:kernel, :stdlib]
      ]

      :ok = :application.load({:application, app, spec})
      on_exit(fn -> Application.unload(app) end)

      assert recompute() == original
    end

    test "warm/0 fills it in" do
      BuildFingerprint.reset()
      assert BuildFingerprint.warm() == :ok
      assert :persistent_term.get({BuildFingerprint, :fingerprint}, nil) =~ ~r/^[0-9a-f]{16}$/
    end
  end

  describe "covered_apps/0" do
    test "is :kiln_cms and every loaded application built on it or on the plugin SDK" do
      overlay = :"kiln_fingerprint_overlay_#{System.unique_integer([:positive])}"
      plugin = :"kiln_fingerprint_plugin_#{System.unique_integer([:positive])}"
      unrelated = :"kiln_fingerprint_unrelated_#{System.unique_integer([:positive])}"

      for {app, deps} <- [{overlay, [:kiln_cms]}, {plugin, [:kiln_plugin]}, {unrelated, []}] do
        spec = [
          description: ~c"test",
          vsn: ~c"0.1.0",
          modules: [],
          registered: [],
          applications: [:kernel, :stdlib | deps]
        ]

        :ok = :application.load({:application, app, spec})
        on_exit(fn -> Application.unload(app) end)
      end

      covered = BuildFingerprint.covered_apps()

      assert :kiln_cms in covered
      assert overlay in covered
      assert plugin in covered
      refute unrelated in covered
    end
  end
end
