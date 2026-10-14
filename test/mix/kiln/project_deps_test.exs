defmodule Mix.Kiln.ProjectDepsTest do
  @moduledoc """
  The overlay dependency hook (#1967): `KilnCMS.Config.ProjectDeps`, which
  mix.exs requires from `config/project_deps_hook.exs`, and the lock it keeps,
  `Mix.Kiln.ProjectLock`, which `mix kiln.update` and the doctor read.

  `scripts/ci/check_project_deps.sh` covers the hook end to end against the
  real core; these pin the rules it applies to a dependency list and a lock.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Config.ProjectDeps
  alias Mix.Kiln.ProjectLock

  @moduletag :tmp_dir

  defp hex(app, version),
    do: {:hex, app, version, "inner-#{version}", [:mix], [], "hexpm", "outer-#{version}"}

  defp deps_file!(root, source) do
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/project_deps.exs"), source)
  end

  describe "the dependency list" do
    test "a core checkout without the file adds nothing and keeps mix.lock", %{tmp_dir: root} do
      assert ProjectDeps.deps(root) == []
      assert ProjectDeps.apps(root) == []
      assert ProjectDeps.lockfile(root) == "mix.lock"
      refute File.exists?(Path.join(root, "config/project.lock"))
    end

    test "is read as written, in any of mix.exs's shapes", %{tmp_dir: root} do
      deps_file!(root, """
      [
        {:kiln_ratings, "~> 1.0"},
        {:kiln_images, github: "example/kiln_images", tag: "v0.1.0"},
        {:kiln_local, path: "../kiln_local", only: [:dev, :test]}
      ]
      """)

      assert [{:kiln_ratings, "~> 1.0"}, {:kiln_images, _opts}, {:kiln_local, _}] =
               ProjectDeps.deps(root)

      assert ProjectDeps.apps(root) == [:kiln_ratings, :kiln_images, :kiln_local]
    end

    test "refuses override: true, in either tuple shape" do
      for dep <- [{:jason, "~> 1.0", override: true}, {:jason, path: "x", override: true}] do
        assert_raise Mix.Error, ~r/:jason sets `override: true`/, fn ->
          ProjectDeps.validate!([dep], "config/project_deps.exs")
        end
      end
    end

    test "refuses a file that isn't a list of dependencies" do
      assert_raise Mix.Error, ~r/must evaluate to a list/, fn ->
        ProjectDeps.validate!(%{kiln_ratings: "~> 1.0"}, "f.exs")
      end

      for bad <- [:kiln_ratings, {"kiln_ratings", "~> 1.0"}, {:a, "1", [], :extra}] do
        assert_raise Mix.Error, ~r/is not a dependency/, fn ->
          ProjectDeps.validate!([bad], "f.exs")
        end
      end
    end
  end

  describe "the lockfile" do
    test "switches to config/project.lock, seeded from mix.lock once", %{tmp_dir: root} do
      deps_file!(root, "[]")
      ProjectLock.write!(Path.join(root, "mix.lock"), %{"jason" => hex(:jason, "1.4.4")})

      assert ProjectDeps.lockfile(root) == "config/project.lock"
      assert ProjectLock.read(ProjectLock.lock_path(root)) == %{"jason" => hex(:jason, "1.4.4")}

      # Once it exists it is the overlay's record: never re-copied.
      ProjectLock.write!(ProjectLock.lock_path(root), %{"recase" => hex(:recase, "0.8.1")})
      assert ProjectDeps.lockfile(root) == "config/project.lock"
      assert ProjectLock.read(ProjectLock.lock_path(root)) == %{"recase" => hex(:recase, "0.8.1")}
    end

    test "is written byte for byte as mix deps.get writes it", %{tmp_dir: root} do
      path = Path.join(root, "a.lock")
      lock = %{"telemetry" => hex(:telemetry, "1.3.0"), "jason" => hex(:jason, "1.4.4")}
      ProjectLock.write!(path, lock)

      expected =
        "%{\n" <>
          ~s(  "jason": #{inspect(hex(:jason, "1.4.4"), limit: :infinity)},\n) <>
          ~s(  "telemetry": #{inspect(hex(:telemetry, "1.3.0"), limit: :infinity)},\n) <>
          "}\n"

      assert File.read!(path) == expected
      assert ProjectLock.read(path) == lock
    end

    test "a lock is parsed as data: code in one is refused, never run", %{tmp_dir: root} do
      path = Path.join(root, "evil.lock")
      marker = Path.join(root, "ran")
      File.write!(path, "%{\"x\": File.write!(" <> inspect(marker) <> ", \"1\")}\n")

      assert_raise Mix.Error, ~r/is not a lockfile/, fn -> ProjectLock.read(path) end
      refute File.exists?(marker)
    end

    test "the core's own mix.lock reads back unchanged" do
      core = ProjectLock.read("mix.lock")
      # Mix's own reader, as the reference (`Mix.Dep.Lock` is private API,
      # which is why the code under test doesn't use it).
      assert core ==
               Map.new(Mix.Dep.Lock.read("mix.lock"), fn {app, e} -> {to_string(app), e} end)

      assert map_size(core) > 50
      assert Enum.all?(core, fn {app, entry} -> is_binary(app) and is_tuple(entry) end)
    end

    test "reseed: core entries become the release's, the overlay's carry over" do
      overlay = %{"jason" => hex(:jason, "1.4.0"), "recase" => hex(:recase, "0.8.1")}
      core = %{"jason" => hex(:jason, "1.4.4"), "telemetry" => hex(:telemetry, "1.3.0")}

      assert ProjectLock.reseed(overlay, core) == %{
               "jason" => hex(:jason, "1.4.4"),
               "telemetry" => hex(:telemetry, "1.3.0"),
               "recase" => hex(:recase, "0.8.1")
             }
    end

    test "drift names a core entry the overlay lock moved, and nothing else" do
      core = %{"jason" => hex(:jason, "1.4.4"), "telemetry" => hex(:telemetry, "1.3.0")}

      assert ProjectLock.drift(Map.put(core, "recase", hex(:recase, "0.8.1")), core) == []
      # Missing from the overlay lock is not drift: deps.get adds it back.
      assert ProjectLock.drift(%{}, core) == []

      assert ProjectLock.drift(%{core | "jason" => hex(:jason, "1.5.0")}, core) ==
               [{"jason", hex(:jason, "1.5.0"), hex(:jason, "1.4.4")}]
    end
  end
end
