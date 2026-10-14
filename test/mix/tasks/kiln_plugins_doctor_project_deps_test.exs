defmodule Mix.Tasks.Kiln.Plugins.DoctorProjectDepsTest do
  @moduledoc """
  What `mix kiln.plugins.doctor` says about plugins and an overlay's own
  dependencies (#1967): where each plugin came from, a plugin installed but
  never registered, and a core dependency moved inside `config/project.lock`.
  """
  use ExUnit.Case, async: true

  alias Mix.Kiln.ProjectLock
  alias Mix.Tasks.Kiln.Plugins.Doctor

  @moduletag :tmp_dir

  defp hex(app, version),
    do: {:hex, app, version, "inner-#{version}", [:mix], [], "hexpm", "outer-#{version}"}

  describe "source/2" do
    test "names where each plugin was compiled" do
      assert Doctor.source(KilnCMS.FixturePlugin, []) == "core"
      assert Doctor.source(KilnDepFixture.Plugin, []) == "dependency"
      assert Doctor.source(KilnDepFixture.Plugin, [:kiln_dep_fixture]) == "project_deps"
      assert Doctor.source(NotAModule.Anywhere, []) == "unknown"
    end
  end

  describe "unregistered/2" do
    test "finds an installed plugin missing from :plugins" do
      assert Doctor.unregistered([:kiln_dep_fixture], []) == [KilnDepFixture.Plugin]
      assert Doctor.unregistered([:kiln_dep_fixture], [KilnDepFixture.Plugin]) == []
    end

    test "ignores apps that ship no plugin, or aren't installed" do
      assert Doctor.unregistered([:jason, :no_such_app_1967], []) == []
    end
  end

  describe "project_lock_problems/1" do
    setup %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "config"))
      ProjectLock.write!(ProjectLock.core_lock_path(root), %{"jason" => hex(:jason, "1.4.4")})
      :ok
    end

    test "nothing without an overlay dependency list", %{tmp_dir: root} do
      ProjectLock.write!(ProjectLock.lock_path(root), %{"jason" => hex(:jason, "9.9.9")})
      assert Doctor.project_lock_problems(root) == []
    end

    test "fails a core dependency the overlay lock moved", %{tmp_dir: root} do
      File.write!(Path.join(root, "config/project_deps.exs"), "[]")

      ProjectLock.write!(ProjectLock.lock_path(root), %{
        "jason" => hex(:jason, "1.5.0"),
        "recase" => hex(:recase, "0.8.1")
      })

      assert [problem] = Doctor.project_lock_problems(root)
      assert problem =~ "config/project.lock has jason at 1.5.0"
      assert problem =~ "mix.lock pins 1.4.4"
    end

    test "passes when the core entries agree", %{tmp_dir: root} do
      File.write!(Path.join(root, "config/project_deps.exs"), "[]")

      ProjectLock.write!(ProjectLock.lock_path(root), %{
        "jason" => hex(:jason, "1.4.4"),
        "recase" => hex(:recase, "0.8.1")
      })

      assert Doctor.project_lock_problems(root) == []
    end
  end
end
