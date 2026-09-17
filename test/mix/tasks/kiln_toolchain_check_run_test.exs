defmodule Mix.Tasks.Kiln.Toolchain.CheckRunTest do
  @moduledoc """
  `mix kiln.toolchain.check` as a gate (#600), rather than as a parser.

  `kiln_toolchain_check_test.exs` covers `parse_tool_versions/1` and asserts
  that *this* repo's three declarations agree. What had never run is the gate
  itself: the comparisons, the messages naming which file is stale, and the
  raise that makes it a gate rather than a report. A check that printed a
  mismatch and exited 0 would be worse than no check, because CI would go
  green on precisely the Dockerfile that cannot build the project.

  Each case runs in a fixture directory holding its own `.tool-versions` and
  `Dockerfile` — the two files the task reads relative to the working
  directory. The `elixir:` requirement it compares against is this project's
  real one, since `Mix.Project.config/0` does not move with the cwd.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kiln.Toolchain.Check

  @moduletag :tmp_dir

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    # The pinned Elixir this repo actually declares: the happy path has to use
    # a version that satisfies mix.exs, and hard-coding one would rot at the
    # next toolchain bump.
    {elixir, erlang} =
      ".tool-versions" |> File.read!() |> Check.parse_tool_versions()

    %{elixir: elixir, erlang: erlang}
  end

  defp fixture(dir, tool_versions, dockerfile) do
    if tool_versions, do: File.write!(Path.join(dir, ".tool-versions"), tool_versions)
    if dockerfile, do: File.write!(Path.join(dir, "Dockerfile"), dockerfile)
    dir
  end

  defp dockerfile(elixir, erlang) do
    """
    # syntax=docker/dockerfile:1
    ARG ELIXIR_VERSION=#{elixir}
    ARG OTP_VERSION=#{erlang}
    ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian"
    """
  end

  defp tool_versions(elixir, erlang), do: "elixir #{elixir}\nerlang #{erlang}\n"

  defp base(version), do: version |> String.split("-") |> hd()

  defp run(dir), do: File.cd!(dir, fn -> Check.run([]) end)

  defp output do
    collect([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
      {:mix_shell, :error, [line]} -> collect([line | acc])
    after
      0 -> acc
    end
  end

  describe "when the declarations agree" do
    test "it says so, naming both versions", ctx do
      dir =
        fixture(
          ctx.tmp_dir,
          tool_versions(ctx.elixir, ctx.erlang),
          dockerfile(base(ctx.elixir), base(ctx.erlang))
        )

      run(dir)

      assert output() =~
               "Toolchain: .tool-versions, mix.exs and Dockerfile agree " <>
                 "(elixir #{ctx.elixir}, erlang #{ctx.erlang})."
    end

    test "the `-otp-` suffix is not part of the image tag", ctx do
      # `.tool-versions` spells Elixir as `1.19.5-otp-27`; the Dockerfile tag is
      # the bare version. Comparing them literally would fail every repo.
      elixir = base(ctx.elixir) <> "-otp-27"

      dir =
        fixture(
          ctx.tmp_dir,
          tool_versions(elixir, ctx.erlang),
          dockerfile(base(ctx.elixir), base(ctx.erlang))
        )

      run(dir)

      assert output() =~ "agree"
    end
  end

  describe "when they disagree" do
    test "a stale Dockerfile pin is named, with both versions and a non-zero exit", ctx do
      dir =
        fixture(
          ctx.tmp_dir,
          tool_versions(ctx.elixir, ctx.erlang),
          dockerfile("1.18.4", base(ctx.erlang))
        )

      assert_raise Mix.Error, ~r/1 toolchain mismatch\(es\)/, fn -> run(dir) end

      assert output() =~
               "Dockerfile pins ELIXIR_VERSION=1.18.4, but .tool-versions says #{base(ctx.elixir)}."
    end

    test "a stale OTP pin is named too", ctx do
      dir =
        fixture(
          ctx.tmp_dir,
          tool_versions(ctx.elixir, ctx.erlang),
          dockerfile(base(ctx.elixir), "25.0")
        )

      assert_raise Mix.Error, ~r/1 toolchain mismatch\(es\)/, fn -> run(dir) end
      assert output() =~ "Dockerfile pins OTP_VERSION=25.0"
    end

    test "an Elixir mix.exs cannot accept is reported against mix.exs, not the image", ctx do
      dir =
        fixture(ctx.tmp_dir, tool_versions("1.10.0", ctx.erlang), dockerfile("1.11.0", "25.0"))

      assert_raise Mix.Error, ~r/3 toolchain mismatch\(es\)/, fn -> run(dir) end
      out = output()

      assert out =~
               ~r/mix.exs requires elixir .*, which 1.10.0 \(.tool-versions\) does not satisfy/

      # All three are reported in one run: a gate that stopped at the first
      # would send someone round the loop once per file.
      assert out =~ "Dockerfile pins ELIXIR_VERSION=1.11.0"
      assert out =~ "Dockerfile pins OTP_VERSION=25.0"
    end

    test "a missing ARG is a mismatch, not a pass", ctx do
      dir =
        fixture(
          ctx.tmp_dir,
          tool_versions(ctx.elixir, ctx.erlang),
          "ARG ELIXIR_VERSION=#{base(ctx.elixir)}\n"
        )

      assert_raise Mix.Error, ~r/1 toolchain mismatch/, fn -> run(dir) end
      assert output() =~ "Dockerfile declares no `ARG OTP_VERSION`."
    end

    test "an ARG mentioned only inside another value is not read as the pin", ctx do
      # Anchored to the line start, so the interpolation in BUILDER_IMAGE (and
      # a commented-out ARG) must not satisfy the check.
      contents = """
      # ARG ELIXIR_VERSION=#{base(ctx.elixir)}
      ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang"
      ARG OTP_VERSION=#{base(ctx.erlang)}
      """

      dir = fixture(ctx.tmp_dir, tool_versions(ctx.elixir, ctx.erlang), contents)

      assert_raise Mix.Error, ~r/1 toolchain mismatch/, fn -> run(dir) end
      assert output() =~ "Dockerfile declares no `ARG ELIXIR_VERSION`."
    end
  end

  describe "when a declaration is missing altogether" do
    test "no .tool-versions is refused before anything is compared", ctx do
      dir = fixture(ctx.tmp_dir, nil, dockerfile("1.18.4", "25.0"))

      assert_raise Mix.Error, ~r/\.tool-versions is missing — it is the source of truth/, fn ->
        run(dir)
      end
    end

    test "a .tool-versions with no elixir line is refused by name", ctx do
      dir = fixture(ctx.tmp_dir, "erlang #{ctx.erlang}\n", dockerfile("1.18.4", "25.0"))

      assert_raise Mix.Error, ~r/declares no `elixir` version/, fn -> run(dir) end
    end

    test "a .tool-versions with no erlang line is refused by name", ctx do
      dir = fixture(ctx.tmp_dir, "elixir #{ctx.elixir}\n", dockerfile("1.18.4", "25.0"))

      assert_raise Mix.Error, ~r/declares no `erlang` version/, fn -> run(dir) end
    end

    test "no Dockerfile is refused", ctx do
      dir = fixture(ctx.tmp_dir, tool_versions(ctx.elixir, ctx.erlang), nil)

      assert_raise Mix.Error, ~r/Dockerfile is missing/, fn -> run(dir) end
    end
  end
end
