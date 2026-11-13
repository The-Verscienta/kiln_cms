defmodule KilnCMS.Scripts.RetryDownloadTest do
  @moduledoc """
  `rel/docker/retry_download.sh` (#2462): the image build's wrapper that
  re-runs a step which failed on a GitHub release-asset download, and only
  then.

  The wrapped command is a stub that prints a scripted output per attempt and
  exits with a scripted status, counting its runs in a file. The positive
  cases print the messages the real fetchers print (elixir_make's "couldn't
  fetch NIF from", tailwind's "Couldn't fetch https://", vix's MatchError on an
  httpc 504 tuple); the negative ones are compile failures whose output holds
  a 504-looking number, a `:closed`, or a real 504 far above the last 40 lines.

  Runs under dash where it is installed (the builder's `/bin/sh`, which has no
  `pipefail`), else `sh`. `KILN_FETCH_BACKOFF=0` keeps the retries instant.

  `async: false`: it spawns processes; nothing global is touched, but the
  stub's counter files share the tmp namespace with the other script tests.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../../rel/docker/retry_download.sh", __DIR__)
  @shell System.find_executable("dash") || "sh"

  tools = ["sh", "tee", "tail", "grep", "mktemp"]
  missing = Enum.reject(tools, &System.find_executable/1)
  if missing != [], do: @moduletag(skip: "needs #{Enum.join(missing, ", ")} on PATH")

  @yex_504 """
  ==> y_ex
  Compiling 6 files (.ex)

  21:04:17.112 [error] Failed to download https://github.com/satoren/y_ex/releases/download/v0.10.5/libyex-v0.10.5-nif-2.17-x86_64-unknown-linux-gnu.so.tar.gz
  ** (RuntimeError) Error while downloading precompiled NIF: couldn't fetch NIF from https://github.com/satoren/y_ex/releases/download/v0.10.5/libyex-v0.10.5-nif-2.17-x86_64-unknown-linux-gnu.so.tar.gz: {:error, {:http_error, 504}}.

  You can force the project to build from scratch with:

      config :rustler_precompiled, :force_build, yex: true
  """

  @tailwind_504 """
  ** (RuntimeError) Couldn't fetch https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.3/tailwindcss-linux-x64: {:ok, {{~c"HTTP/1.1", 504, ~c"Gateway Time-out"}, [], ~c""}}

  This typically means we cannot reach the source or you are behind a proxy.
      (tailwind 0.5.2) lib/tailwind.ex:496: Tailwind.fetch_body!/2
  """

  @vix_504 """
  ==> vix
  Downloading https://github.com/akash-akya/sharp-libvips/releases/download/v8.17.3/libvips-8.17.3-linux-x64.tar.gz
  ** (MatchError) no match of right hand side value: {:ok, {{~c"HTTP/1.1", 504, ~c"Gateway Time-out"}, [], []}}
      build_scripts/precompiler.exs:142: Vix.LibvipsPrecompiled.fetch!/2
  make: *** [Makefile:58: priv/precompiled_libvips] Error 1
  could not compile dependency :vix, "mix compile" failed.
  """

  @compile_error """
  ==> kiln_cms
  Compiling 1 file (.ex)
  ** (CompileError) lib/x.ex:504: undefined function foo/0 (expected KilnCMS.X to define such a function)
  could not compile dependency :x, "mix compile" failed.
  """

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "kiln_retry_download_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    stub = Path.join(tmp, "fetch")

    File.write!(stub, """
    #!/bin/sh
    dir="$(dirname "$0")"
    n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$dir/count"
    out="$dir/out.$n"; [ -f "$out" ] || out="$dir/out.default"
    st="$dir/status.$n"; [ -f "$st" ] || st="$dir/status.default"
    cat "$out"
    exit "$(cat "$st")"
    """)

    File.chmod!(stub, 0o755)

    %{tmp: tmp, stub: stub}
  end

  describe "a download failure" do
    test "is retried until the command succeeds", ctx do
      script!(ctx, 1, @yex_504, 1)
      script!(ctx, 2, @yex_504, 1)
      script!(ctx, :default, "Generated y_ex app\n", 0)

      assert {out, 0} = run(ctx)
      assert attempts(ctx) == 3
      assert out =~ "attempt 1 of 5 failed on a download (exit 1); retrying in 0s"
      assert out =~ "attempt 2 of 5"
      assert out =~ "Generated y_ex app"
    end

    test "is recognized in tailwind's message", ctx do
      script!(ctx, 1, @tailwind_504, 1)
      script!(ctx, :default, "", 0)

      assert {_out, 0} = run(ctx)
      assert attempts(ctx) == 2
    end

    test "is recognized in vix's MatchError on the libvips tarball", ctx do
      script!(ctx, 1, @vix_504, 1)
      script!(ctx, :default, "", 0)

      assert {_out, 0} = run(ctx)
      assert attempts(ctx) == 2
    end

    test "that never clears gives up after KILN_FETCH_ATTEMPTS, with the command's status",
         ctx do
      script!(ctx, :default, @yex_504, 3)

      assert {out, 3} = run(ctx, [{"KILN_FETCH_ATTEMPTS", "3"}])
      assert attempts(ctx) == 3
      assert out =~ "attempt 3 of 3 failed on a download (exit 3); giving up"
    end
  end

  describe "any other failure" do
    test "fails after one attempt with the command's status", ctx do
      script!(ctx, :default, @compile_error, 7)

      assert {out, 7} = run(ctx)
      assert attempts(ctx) == 1
      refute out =~ "retrying"
    end

    test "is not mistaken for one by a `:closed`, a `:504:` line number or a 504 early in the log",
         ctx do
      early =
        """
        ==> lazy_html
        warning: Mint.HTTP1 connection {:error, :closed}, retrying
        lib/x.ex:504: warning: variable "y" is unused
        """

      script!(ctx, :default, early <> filler(10) <> @compile_error, 1)

      assert {_out, 1} = run(ctx)
      assert attempts(ctx) == 1
    end

    test "is not mistaken for one by rustler_precompiled's wrapper around a checksum error",
         ctx do
      checksum = """
      ** (RuntimeError) Error while downloading precompiled NIF: the precompiled NIF file does not exist in the checksum file. Please consider run: `mix rustler_precompiled.download YEx --only-local` to generate the checksum file.
      """

      script!(ctx, :default, checksum, 1)

      assert {_out, 1} = run(ctx)
      assert attempts(ctx) == 1
    end

    test "is not mistaken for one by a download error more than 40 lines above the end",
         ctx do
      script!(ctx, :default, @yex_504 <> filler(45) <> @compile_error, 1)

      assert {_out, 1} = run(ctx)
      assert attempts(ctx) == 1
    end
  end

  test "a command that succeeds first time runs once", ctx do
    script!(ctx, :default, "ok\n", 0)

    assert {"ok\n", 0} = run(ctx)
    assert attempts(ctx) == 1
  end

  test "a non-numeric knob is refused before anything runs", ctx do
    script!(ctx, :default, "ok\n", 0)

    assert {out, 2} = run(ctx, [{"KILN_FETCH_ATTEMPTS", "five"}])
    assert out =~ "must be whole numbers"
    assert attempts(ctx) == 0
  end

  defp script!(ctx, n, out, status) do
    File.write!(Path.join(ctx.tmp, "out.#{n}"), out)
    File.write!(Path.join(ctx.tmp, "status.#{n}"), "#{status}\n")
  end

  defp attempts(ctx) do
    case File.read(Path.join(ctx.tmp, "count")) do
      {:ok, n} -> n |> String.trim() |> String.to_integer()
      {:error, :enoent} -> 0
    end
  end

  defp filler(lines), do: Enum.map_join(1..lines, &"  compiling module #{&1}\n")

  defp run(ctx, env \\ []) do
    System.cmd(@shell, [@script, ctx.stub, "deps.compile"],
      env: [{"KILN_FETCH_BACKOFF", "0"} | env],
      stderr_to_stdout: true
    )
  end
end
