defmodule Mix.Tasks.Kiln.Toolchain.CheckTest do
  @moduledoc """
  The toolchain agreement gate.

  This gate exists because the failure it catches is invisible everywhere else:
  CI never builds the release image, so a Dockerfile that cannot compile the
  project is green on every job until a deploy fails (#600). A gate that only
  ever passes proves nothing, so the drift cases are asserted directly — the
  parse in particular, since a parse that silently returns `nil` would make the
  whole check pass on a genuine mismatch.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kiln.Toolchain.Check

  describe "parse_tool_versions/1" do
    test "reads the versions the repo's own file declares" do
      assert {"1.19.5-otp-27", "27.3.4.15"} =
               Check.parse_tool_versions("""
               elixir 1.19.5-otp-27
               erlang 27.3.4.15
               """)
    end

    test "ignores comments and blank lines" do
      assert {"1.19.5-otp-27", "27.3.4.15"} =
               Check.parse_tool_versions("""
               # the toolchain, in one place

               elixir 1.19.5-otp-27

               # erlang 26.0.0 — an old pin left in a comment
               erlang 27.3.4.15
               """)
    end

    test "tolerates extra tools and irregular spacing" do
      assert {"1.19.5-otp-27", "27.3.4.15"} =
               Check.parse_tool_versions("""
               nodejs 22.11.0
               elixir    1.19.5-otp-27
               \terlang\t27.3.4.15
               """)
    end

    # A missing tool must read as nil so the task can fail loudly. Returning a
    # default here would let the gate pass on a file that declares nothing.
    test "reports a missing tool as nil rather than guessing" do
      assert {nil, "27.3.4.15"} = Check.parse_tool_versions("erlang 27.3.4.15\n")
      assert {"1.19.5-otp-27", nil} = Check.parse_tool_versions("elixir 1.19.5-otp-27\n")
      assert {nil, nil} = Check.parse_tool_versions("")
    end

    # `elixirc` / `erlang-ls` must not be mistaken for `elixir` / `erlang`.
    test "matches the tool name exactly" do
      assert {nil, nil} =
               Check.parse_tool_versions("""
               elixirc 1.19.5
               erlang-ls 0.30.0
               """)
    end
  end

  describe "the repo's own declarations" do
    test "the pinned Elixir satisfies mix.exs's requirement" do
      {elixir, _erlang} = Check.parse_tool_versions(File.read!(".tool-versions"))
      version = elixir |> String.split("-") |> hd()

      requirement = Mix.Project.config()[:elixir]

      assert Version.match?(version, requirement),
             "#{version} (.tool-versions) does not satisfy mix.exs's #{requirement}"
    end

    # The exact failure that shipped: #573 raised the requirement and updated
    # CI, leaving the Dockerfile selecting a builder image that cannot compile
    # this project.
    test "the Dockerfile ARGs mirror .tool-versions" do
      {elixir, erlang} = Check.parse_tool_versions(File.read!(".tool-versions"))
      dockerfile = File.read!("Dockerfile")

      assert [_, elixir_arg] = Regex.run(~r/^ARG\s+ELIXIR_VERSION=(\S+)/m, dockerfile)
      assert [_, otp_arg] = Regex.run(~r/^ARG\s+OTP_VERSION=(\S+)/m, dockerfile)

      assert elixir_arg == elixir |> String.split("-") |> hd()
      assert otp_arg == erlang
    end

    # setup-beam reads .tool-versions directly; restating a version in the
    # workflow is what let CI's toolchain drift from the Dockerfile's.
    test "CI reads the file instead of restating the versions" do
      ci = File.read!(".github/workflows/ci.yml")

      refute ci =~ "env.ELIXIR_VERSION"
      refute ci =~ "env.OTP_VERSION"
      assert ci =~ "version-file: .tool-versions"
      assert ci =~ "mix kiln.toolchain.check"
    end
  end
end
