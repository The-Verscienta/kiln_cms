defmodule KilnCMS.Scripts.BackupOverlayTest do
  @moduledoc """
  `rel/overlays/bin/backup` (#2234): the release's backup command line. It
  must route each command to `eval` or `rpc`, never put what the operator
  typed inside the Elixir expression, refuse an argument holding a line
  break, and pass the exit status through.

  The release binary is a stub `kiln_cms` beside a copy of the script, which
  records its mode and expression and exits with `$STUB_EXIT`. Runs under
  dash where it is installed (the runner image's `/bin/sh`), else `sh`.

  `async: false`: it spawns processes; nothing global is touched, but the
  stub's files share the tmp namespace with the other script tests.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../../rel/overlays/bin/backup", __DIR__)
  @shell System.find_executable("dash") || "sh"

  tools = ["sh", "base64", "tr"]
  missing = Enum.reject(tools, &System.find_executable/1)
  if missing != [], do: @moduletag(skip: "needs #{Enum.join(missing, ", ")} on PATH")

  @expr ~r/\AKilnCMS\.Release\.backup\("([A-Za-z0-9+\/=]*)"\)\z/

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "kiln_backup_overlay_#{System.unique_integer([:positive])}")

    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    File.cp!(@script, Path.join(bin, "backup"))

    stub = Path.join(bin, "kiln_cms")

    File.write!(stub, """
    #!/bin/sh
    dir="$(dirname "$0")"
    echo call >> "$dir/calls"
    printf '%s' "$1" > "$dir/mode"
    printf '%s' "$2" > "$dir/expr"
    exit "${STUB_EXIT:-0}"
    """)

    File.chmod!(stub, 0o755)
    %{tmp: tmp, bin: bin}
  end

  defp backup(ctx, args, stub_exit \\ "0") do
    System.cmd(@shell, [Path.join(ctx.bin, "backup") | args],
      cd: ctx.tmp,
      env: [{"STUB_EXIT", stub_exit}],
      stderr_to_stdout: true
    )
  end

  defp calls(ctx) do
    case File.read(Path.join(ctx.bin, "calls")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  defp mode(ctx), do: File.read!(Path.join(ctx.bin, "mode"))

  # The argv the release would decode from the recorded expression.
  defp decoded(ctx) do
    expr = File.read!(Path.join(ctx.bin, "expr"))
    assert [_, encoded] = Regex.run(@expr, expr), "not a bare base64 literal: #{expr}"
    assert {:ok, argv} = KilnCMS.Release.decode_backup_argv(encoded)
    argv
  end

  test "run, rescan and prune go through rpc, one call each", ctx do
    for command <- ~w(run rescan prune) do
      File.rm(Path.join(ctx.bin, "calls"))
      assert {_out, 0} = backup(ctx, [command, "--json"])
      assert calls(ctx) == 1
      assert mode(ctx) == "rpc"
      assert decoded(ctx) == [command, "--json"]
    end
  end

  test "list, verify, help, no arguments and an unknown command go through eval", ctx do
    for args <- [["list"], ["verify", "x"], ["help"], [], ["bogus"], ["--json", "run"]] do
      File.rm(Path.join(ctx.bin, "calls"))
      assert {_out, 0} = backup(ctx, args)
      assert calls(ctx) == 1
      assert mode(ctx) == "eval"
      assert decoded(ctx) == args
    end
  end

  test "nothing typed reaches the expression; every argument round-trips", ctx do
    args = [
      "verify",
      "it's",
      "a b",
      "$(touch pwned)",
      "`touch pwned2`",
      "\#{System.halt()}",
      "\"); System.halt(); (\"",
      "\\",
      "",
      "--json",
      "é"
    ]

    assert {_out, 0} = backup(ctx, args)
    assert decoded(ctx) == args

    for dir <- [ctx.tmp, ctx.bin], name <- ["pwned", "pwned2"] do
      refute File.exists?(Path.join(dir, name))
    end
  end

  test "an argument with a line break exits 2 and calls nothing", ctx do
    assert {out, 2} = backup(ctx, ["verify", "a\nb"])
    assert out =~ "holds a line break"
    assert calls(ctx) == 0
  end

  test "the release's exit status passes through", ctx do
    for status <- ["0", "1", "2"] do
      assert {_out, code} = backup(ctx, ["list"], status)
      assert Integer.to_string(code) == status

      assert {_out, code} = backup(ctx, ["run"], status)
      assert Integer.to_string(code) == status
    end
  end

  test "the script parses and is executable" do
    assert {_out, 0} = System.cmd(@shell, ["-n", @script])

    case System.cmd("git", ["ls-files", "-s", @script], stderr_to_stdout: true) do
      {"100755 " <> _, 0} -> :ok
      {"", 0} -> assert Bitwise.band(File.stat!(@script).mode, 0o111) != 0
      {other, _} -> flunk("unexpected git mode: #{other}")
    end
  end
end
