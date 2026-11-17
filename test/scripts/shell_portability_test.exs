defmodule KilnCMS.Scripts.ShellPortabilityTest do
  @moduledoc """
  The `backup_scripts_portability` CI job (#2479) runs the `:shell_portability`
  modules with a shim directory first on `PATH`, and is only worth having if
  the scripts really meet the tools the leg is named for. A leg sets
  `KILN_EXPECT_BASH` (a version prefix, e.g. `3.2.57`) or `KILN_EXPECT_TAR`
  (e.g. `bsdtar`), and these tests check what a test's `System.cmd/3` resolves
  `bash` and `tar` to, through the same `PATH` the script tests use. Unset or
  empty, they skip.
  """
  use ExUnit.Case, async: true


  @moduletag :shell_portability

  if System.get_env("KILN_EXPECT_BASH", "") == "",
    do: @tag(skip: "KILN_EXPECT_BASH is not set")

  test "bash on PATH is the version KILN_EXPECT_BASH names" do
    expect = System.get_env("KILN_EXPECT_BASH")
    {version, 0} = System.cmd("bash", ["-c", "echo $BASH_VERSION"])

    assert version =~ ~r/\A#{Regex.escape(expect)}[.(]/,
           "bash on PATH reports #{String.trim(version)}, expected #{expect}"

    bash32 = System.get_env("KILN_BASH32", "")

    if bash32 != "" do
      assert System.find_executable("bash") |> Path.expand() |> resolve() == Path.expand(bash32),
             "the bash on PATH is not KILN_BASH32"

      {version32, 0} = System.cmd(bash32, ["-c", "echo $BASH_VERSION"])
      assert version32 == version, "KILN_BASH32 is not the bash on PATH"
    end
  end

  if System.get_env("KILN_EXPECT_TAR", "") == "",
    do: @tag(skip: "KILN_EXPECT_TAR is not set")

  test "tar on PATH is the one KILN_EXPECT_TAR names" do
    expect = System.get_env("KILN_EXPECT_TAR")
    {out, 0} = System.cmd("tar", ["--version"], stderr_to_stdout: true)
    assert out =~ expect, "tar --version on PATH says: #{out}"
  end

  # Follows a symlink chain (the CI shim links `bash` to KILN_BASH32).
  defp resolve(path) do
    case File.read_link(path) do
      {:ok, target} -> resolve(Path.expand(target, Path.dirname(path)))
      {:error, _} -> path
    end
  end
end
