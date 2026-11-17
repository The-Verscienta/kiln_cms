defmodule KilnCMS.Test.ShellTools do
  @moduledoc """
  The shells and tars the script tests run under besides the defaults (#2479).

  On a developer's machine these tests skip, with the reason, when the tool is
  not installed: `/bin/bash` is 3.2 only on macOS, and busybox is rarely
  installed. CI's `backup_scripts_portability` job sets the variables below,
  and a variable that is set makes the tool REQUIRED: a gated test then runs
  and fails if the tool is missing, rather than skipping green.

    * `KILN_BASH32` — the path of a bash 3.2 (the job builds 3.2.57 with
      `scripts/ci/build_bash32.sh`).
    * `KILN_REQUIRE_BUSYBOX=1` — busybox must be on `PATH`.
  """

  @doc """
  The bash 3.2 to run a script under: `KILN_BASH32` when set, else `/bin/bash`
  when it is 3.x (macOS), else `nil`. A set `KILN_BASH32` is returned as is,
  so a wrong path fails the test that runs it instead of skipping it.
  """
  @spec bash32() :: String.t() | nil
  def bash32 do
    case System.get_env("KILN_BASH32", "") do
      "" -> if bash_major("/bin/bash") == "3", do: "/bin/bash"
      path -> path
    end
  end

  @doc "Whether `KILN_REQUIRE_BUSYBOX=1` makes busybox required."
  @spec busybox_required?() :: boolean()
  def busybox_required?, do: System.get_env("KILN_REQUIRE_BUSYBOX") == "1"

  @doc "Whether the busybox tests should run: busybox is on `PATH`, or required."
  @spec busybox?() :: boolean()
  def busybox?, do: busybox_required?() or System.find_executable("busybox") != nil

  @doc "busybox's path, raising when it is not on `PATH`."
  @spec busybox!() :: String.t()
  def busybox! do
    System.find_executable("busybox") ||
      raise "busybox is not on PATH" <>
              if(busybox_required?(), do: " (KILN_REQUIRE_BUSYBOX=1 requires it)", else: "")
  end

  defp bash_major(bash) do
    with true <- File.exists?(bash),
         {major, 0} <-
           System.cmd(bash, ["-c", "echo ${BASH_VERSINFO[0]}"], stderr_to_stdout: true) do
      String.trim(major)
    else
      _ -> nil
    end
  end
end
