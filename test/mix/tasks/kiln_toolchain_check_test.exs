defmodule Mix.Tasks.Kiln.Toolchain.CheckTest do
  @moduledoc """
  The toolchain agreement gate.

  This gate names, in a second, a failure CI's `image` job takes a whole
  dependency compile to reach: a Dockerfile that cannot compile the project
  (#600). A gate that only ever passes proves nothing, so the drift cases are
  asserted directly — the parse in particular, since a parse that silently
  returns `nil` would make the whole check pass on a genuine mismatch.
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

  describe "setup_node_version/1 (setup-node's parse)" do
    test "a bare `#` line above nodejs wins, as it did in CI" do
      assert Check.setup_node_version("# Node:\n#\nelixir 1.20.4-otp-29\nnodejs 22.23.3\n") == "#"
    end

    test "comment lines with spaces, blank lines and other tools are skipped" do
      contents = "# a comment\n\nelixir 1.20.4-otp-29\nerlang 29.1.1\nnodejs 22.23.3\n"
      assert Check.setup_node_version(contents) == "22.23.3"
    end

    test "a leading v is dropped, as setup-node drops it" do
      assert Check.setup_node_version("nodejs v22.23.3\n") == "22.23.3"
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

    # CI's setup-node reads this file with its own one-line pattern, not as
    # asdf does. A bare `#` comment line once made it ask for Node "#".
    test "setup-node reads the nodejs line from this repo's .tool-versions" do
      contents = File.read!(".tool-versions")
      assert Check.setup_node_version(contents) == Check.parse_node_version(contents)
    end

    test "the Dockerfile's NODE_VERSION mirrors .tool-versions" do
      node = Check.parse_node_version(File.read!(".tool-versions"))

      assert node, ".tool-versions declares no nodejs version"
      assert [_, ^node] = Regex.run(~r/^ARG\s+NODE_VERSION=(\S+)/m, File.read!("Dockerfile"))
    end

    # setup-beam reads .tool-versions directly; restating a version in the
    # workflow is what let CI's toolchain drift from the Dockerfile's.
    test "CI reads the file instead of restating the versions" do
      ci = File.read!(".github/workflows/ci.yml")

      refute ci =~ "env.ELIXIR_VERSION"
      refute ci =~ "env.OTP_VERSION"
      assert ci =~ "version-file: .tool-versions"
      assert ci =~ "node-version-file: .tool-versions"
      refute ci =~ ~r/node-version:\s/
      assert ci =~ "mix kiln.toolchain.check"
    end
  end
end
