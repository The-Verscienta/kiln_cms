defmodule Kiln.Plugins.LockRecordTest do
  @moduledoc """
  The lock coordinates the plugin health check (#2244) compares against
  hex.pm, captured from the build's lockfile at compile time.
  """
  use ExUnit.Case, async: true

  alias Kiln.Plugins.LockRecord

  @jason_outer "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"

  describe "from_lock/1" do
    test "keeps a hex entry with no kiln_plugin dependency, with its outer checksum" do
      lock = %{
        "jason" =>
          {:hex, :jason, "1.4.5",
           "2e3a008590b0b8d7388c20293e9dcc9cf3e5d642fd2a114e4cbbb52e595d940a", [:mix],
           [{:decimal, "~> 1.0 or ~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}],
           "hexpm", @jason_outer}
      }

      assert %{
               "jason" => %{
                 app: "jason",
                 source: :hex,
                 package: "jason",
                 version: "1.4.5",
                 repo: "hexpm",
                 outer_checksum: @jason_outer,
                 sdk_requirement: nil
               }
             } = LockRecord.from_lock(lock)
    end

    test "records a hex plugin's kiln_plugin requirement from its deps list" do
      lock = %{
        "kiln_ratings" =>
          {:hex, :kiln_ratings, "0.3.0", "inner", [:mix],
           [{:kiln_plugin, "~> 1.4", [hex: :kiln_plugin, repo: "hexpm", optional: false]}],
           "hexpm", "outer"}
      }

      assert %{"kiln_ratings" => %{sdk_requirement: "~> 1.4", outer_checksum: "outer"}} =
               LockRecord.from_lock(lock)
    end

    test "a hex package published under another name keeps the package name" do
      lock = %{"my_app" => {:hex, :my_package, "1.0.0", "i", [:mix], [], "hexpm", "o"}}
      assert %{"my_app" => %{app: "my_app", package: "my_package"}} = LockRecord.from_lock(lock)
    end

    test "a private repository is recorded as such" do
      lock = %{"acme" => {:hex, :acme, "1.0.0", "i", [:mix], [], "acme_org", "o"}}
      assert %{"acme" => %{repo: "acme_org"}} = LockRecord.from_lock(lock)
    end

    test "records a git entry's URL and commit" do
      lock = %{
        "kiln_maps" =>
          {:git, "https://github.com/example/kiln_maps.git",
           "0123456789abcdef0123456789abcdef01234567", [branch: "main"]}
      }

      assert %{
               "kiln_maps" => %{
                 source: :git,
                 git_url: "https://github.com/example/kiln_maps.git",
                 git_ref: "0123456789abcdef0123456789abcdef01234567",
                 outer_checksum: nil
               }
             } = LockRecord.from_lock(lock)
    end

    test "the older 6- and 7-element hex shapes have no outer checksum" do
      lock = %{
        "six" => {:hex, :six, "1.0.0", "inner", [:mix], []},
        "seven" => {:hex, :seven, "1.0.0", "inner", [:mix], [], "hexpm"}
      }

      assert %{
               "six" => %{source: :hex, repo: "hexpm", outer_checksum: nil},
               "seven" => %{source: :hex, repo: "hexpm", outer_checksum: nil}
             } = LockRecord.from_lock(lock)
    end

    test "an entry of no known shape is skipped" do
      assert LockRecord.from_lock(%{"odd" => {:svn, "x"}, "bare" => "1.0.0"}) == %{}
    end

    test "an empty lock records nothing" do
      assert LockRecord.from_lock(%{}) == %{}
    end
  end

  describe "from_deps/1" do
    test "maps each dependency that requires kiln_plugin to its requirement" do
      declared = [
        {:kiln_dep_fixture, [{:kiln_plugin, "~> 1.4"}, {:plug, "~> 1.14"}]},
        {:bare_path_plugin, [{:kiln_plugin, nil}]},
        {:jason, [{:decimal, "~> 2.0"}]}
      ]

      assert LockRecord.from_deps({:ok, declared}) == %{
               "kiln_dep_fixture" => "~> 1.4",
               "bare_path_plugin" => nil
             }
    end

    test "an unreadable dependency graph is :unknown, not an empty map" do
      # `%{}` would read as "no plugin declared a requirement", which the
      # health check treats as compatible. Not knowing must stay unknown.
      assert LockRecord.from_deps(:error) == :unknown
    end
  end

  describe "the compiled record" do
    test "holds this build's hex entries" do
      assert %{source: :hex, package: "jason", repo: "hexpm", outer_checksum: outer} =
               LockRecord.fetch(:jason)

      assert byte_size(outer) == 64
    end

    test "has no entry for a path dependency or for an unknown app" do
      assert LockRecord.fetch(:kiln_dep_fixture) == nil
      assert LockRecord.fetch(nil) == nil
    end

    test "records the path fixture plugin's SDK requirement from Mix's graph" do
      assert %{"kiln_dep_fixture" => "~> 1.4"} = LockRecord.sdk_requirements()
    end

    test "a missing lockfile records nothing" do
      missing =
        Path.join(System.tmp_dir!(), "kiln-no-lock-#{System.unique_integer([:positive])}")

      assert missing |> Mix.Kiln.ProjectLock.read() |> LockRecord.from_lock() == %{}
    end
  end
end
