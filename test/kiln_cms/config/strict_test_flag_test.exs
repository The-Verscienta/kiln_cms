defmodule KilnCMS.Config.StrictTestFlagTest do
  @moduledoc """
  Unit tests for the standalone `KILN_STRICT_TEST` parser (#646).

  `config/strict_test_flag.exs` is not part of `lib/` — it exists only because
  `config/test.exs` cannot reach `KilnCMS.Config.Env` at the point it runs (see
  that module's moduledoc). `test/test_helper.exs` requires the same file
  before `ExUnit.start/1`, so `KilnCMS.Config.StrictTestFlag` is already loaded
  by the time this suite runs — no `Code.require_file/2` needed here.

  `async: false`: the wiring tests below set `KILN_STRICT_TEST` in the process
  environment, which is global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Config.Env
  alias KilnCMS.Config.StrictTestFlag

  @var "KILN_STRICT_TEST"

  setup do
    previous = System.get_env(@var)

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    :ok
  end

  test "the spelling tables stay in sync with KilnCMS.Config.Env" do
    # config/strict_test_flag.exs carries a LITERAL COPY of these — it cannot
    # `alias`/call KilnCMS.Config.Env (that's the whole reason it exists). This
    # is what stops the copy silently drifting from the original.
    assert StrictTestFlag.true_values() == Env.true_values()
    assert StrictTestFlag.false_values() == Env.false_values()
  end

  describe "strict?/1" do
    test "on-spellings select strict, in any case and with surrounding whitespace" do
      for value <- ["true", "TRUE", "True", " true ", "1", "yes", "YES", "on", "On"] do
        assert StrictTestFlag.strict?(value), "expected #{inspect(value)} to select strict"
      end
    end

    test "off-spellings, unset, blank and unrecognized values all stay non-strict" do
      for value <- [nil, "", " ", "false", "FALSE", "0", "no", "off"] do
        refute StrictTestFlag.strict?(value), "expected #{inspect(value)} to stay non-strict"
      end

      # Unrecognized values stay non-strict too, but they now warn — asserted in
      # its own block below, where the output is captured rather than leaked.
      for value <- ["enabled", "maybe"] do
        {strict?, _warning} = with_io(:stderr, fn -> StrictTestFlag.strict?(value) end)
        refute strict?, "expected #{inspect(value)} to stay non-strict"
      end
    end
  end

  describe "an unrecognized value" do
    test "says so on stderr, quoting what was typed" do
      # Without this the strict leg runs zero tests and exits 0, which looks
      # exactly like not having invoked it — and no test can fail, because the
      # strict-tagged file is excluded. A silent misparse here has no symptom.
      output = capture_io(:stderr, fn -> StrictTestFlag.strict?(" Strict ") end)

      assert output =~ "KILN_STRICT_TEST"
      # The operator's own bytes, untrimmed: the trimming is what caused the
      # mismatch, so echoing the normalized form hides the only greppable clue.
      assert output =~ ~s(" Strict ")
      assert output =~ "WITHOUT strict tenancy"
    end

    test "and a recognized value, blank or unset stays quiet" do
      for value <- [nil, "", "true", "1", "yes", "on", "false", "0", "no", "off", " TRUE "] do
        assert capture_io(:stderr, fn -> StrictTestFlag.strict?(value) end) == "",
               "expected #{inspect(value)} not to warn"
      end
    end
  end

  # The unit tests above prove the parser is right. These prove it is actually
  # the thing being *used* — a revert of either call site to the old `== "1"`
  # would leave every test above green.
  describe "the wiring" do
    defp compiled_strict_tenancy?(value) do
      if value, do: System.put_env(@var, value), else: System.delete_env(@var)

      "config/test.exs"
      |> Config.Reader.read!(env: :test)
      |> get_in([:kiln_cms, :strict_tenancy])
    end

    test "config/test.exs resolves :strict_tenancy through this parser" do
      # Evaluates the real config file, so this is the value
      # `Application.compile_env/3` hands the ~45 multitenant resources.
      assert compiled_strict_tenancy?("true")
      assert compiled_strict_tenancy?("1")
      refute compiled_strict_tenancy?("false")
      refute compiled_strict_tenancy?(nil)
    end

    test "and agrees with KilnCMS.Config.Env on every spelling" do
      # The invariant that lets `config/strict_test_flag.exs` keep a copy of the
      # table at all — checked as behaviour, so it holds even for the blank and
      # unparseable cases, where "both fall back to the default" is as much a
      # behaviour as the recognized spellings.
      values = ~w(true 1 yes on TRUE false 0 no off FALSE) ++ [" on ", "", "ture", "strict"]

      for value <- values do
        # Both sides warn on the unparseable entries; `with_io/2` hands back the
        # result and swallows the noise.
        {compiled, _} = with_io(:stderr, fn -> compiled_strict_tenancy?(value) end)
        {shared, _} = with_io(:stderr, fn -> Env.flag(@var, false) end)

        assert compiled == shared,
               "#{inspect(value)}: config/test.exs says #{compiled}, " <>
                 "KilnCMS.Config.Env says #{shared}"
      end
    end
  end
end
