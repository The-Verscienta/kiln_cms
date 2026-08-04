defmodule KilnCMS.Config.StrictTestFlagTest do
  @moduledoc """
  Unit tests for the standalone `KILN_STRICT_TEST` parser (#646).

  `config/strict_test_flag.exs` is not part of `lib/` — it exists only because
  `config/test.exs` cannot reach `KilnCMS.Config.Env` at the point it runs (see
  that module's moduledoc). `test/test_helper.exs` requires the same file
  before `ExUnit.start/1`, so `KilnCMS.Config.StrictTestFlag` is already loaded
  by the time this suite runs — no `Code.require_file/2` needed here.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Config.Env
  alias KilnCMS.Config.StrictTestFlag

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
      for value <- [nil, "", " ", "false", "FALSE", "0", "no", "off", "enabled", "maybe"] do
        refute StrictTestFlag.strict?(value), "expected #{inspect(value)} to stay non-strict"
      end
    end
  end
end
