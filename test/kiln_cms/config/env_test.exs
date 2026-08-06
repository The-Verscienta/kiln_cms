defmodule KilnCMS.Config.EnvTest do
  @moduledoc """
  Unit tests for the shared boolean env parser (#607).

  `test/config/runtime_env_flags_test.exs` covers the same rules end-to-end
  through `config/runtime.exs`, which is what catches a *call site* drifting
  away from the parser. These pin the parser itself, so the spellings and the
  unrecognized-value rule are stated once, in one place, without a
  `Config.Reader` round trip.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Config.Env

  # The moduledoc's `iex>` examples are the first thing a reader trusts; without
  # this they can rot silently, since `mix docs` does not execute them.
  doctest KilnCMS.Config.Env

  @var "KILN_TEST_ENV_FLAG"

  setup do
    on_exit(fn -> System.delete_env(@var) end)
    :ok
  end

  defp put(nil), do: System.delete_env(@var)
  defp put(value), do: System.put_env(@var, value)

  # Silences the deliberate IO.warn so unrecognized-value tests don't spray stderr.
  defp quietly(fun) do
    parent = self()
    capture_io(:stderr, fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> result
    after
      0 -> flunk("function did not run")
    end
  end

  describe "fetch/1 recognized spellings" do
    test "on-spellings, in any case and with surrounding whitespace" do
      for value <- ["true", "TRUE", "True", " true ", "\ttrue\n", "1", "yes", "YES", "on", "On"] do
        put(value)
        assert Env.fetch(@var) == {:ok, true}, "expected #{inspect(value)} to read as true"
      end
    end

    test "off-spellings, in any case and with surrounding whitespace" do
      for value <- ["false", "FALSE", "False", " off ", "0", "no", "NO", "off", "OFF"] do
        put(value)
        assert Env.fetch(@var) == {:ok, false}, "expected #{inspect(value)} to read as false"
      end
    end
  end

  describe "fetch/1 fail-safe behaviour" do
    test "unset is :unset" do
      put(nil)
      assert Env.fetch(@var) == :unset
    end

    test "blank and whitespace-only read as unset, not as a value" do
      # `FOO=` in a .env file or compose file yields "", which is truthy in
      # Elixir — the reason a bare `System.get_env/1` presence check is wrong.
      for value <- ["", " ", "\t\n"] do
        put(value)
        assert Env.fetch(@var) == :unset, "expected #{inspect(value)} to read as unset"
      end
    end

    test "an unrecognized value is :unrecognized and warns, rather than reading as off" do
      for value <- ["enabled", "y", "t", "True!", ~s("true"), "maybe", "0.0", "of"] do
        put(value)

        stderr = capture_io(:stderr, fn -> assert Env.fetch(@var) == :unrecognized end)

        assert stderr =~ "unrecognized value",
               "#{inspect(value)} should warn rather than be silently swallowed"

        assert stderr =~ @var, "the warning should name the variable"
      end
    end

    test "a recognized value warns about nothing" do
      put("true")
      assert capture_io(:stderr, fn -> Env.fetch(@var) end) == ""
    end

    test "the warning quotes what the operator typed, not the normalized form" do
      # The trimming and downcasing are exactly what caused the mismatch, so
      # echoing "enabled" for a typed " Enabled " hides the only actionable
      # clue: the operator greps their compose file for it and finds nothing.
      put(" Enabled ")

      assert capture_io(:stderr, fn -> Env.fetch(@var) end) =~ ~s(" Enabled ")
    end
  end

  describe "boot-warning replay (#634)" do
    setup do
      Env.clear_warnings()
      on_exit(&Env.clear_warnings/0)
      :ok
    end

    test "an unrecognized value is recorded for later replay, not only written to stderr" do
      put("enabledd")
      quietly(fn -> assert Env.fetch(@var) == :unrecognized end)

      assert {@var, "enabledd"} in Env.warnings()
    end

    test "a recognized or unset value records nothing" do
      put("true")
      assert Env.fetch(@var) == {:ok, true}
      put(nil)
      assert Env.fetch(@var) == :unset

      assert Env.warnings() == []
    end

    test "replay re-emits each through Logger — where the config provider's stderr can't reach — and clears" do
      put(" Enabled ")
      quietly(fn -> Env.fetch(@var) end)
      # The RAW value is kept, spaces and all, so an operator can grep for it.
      assert [{@var, " Enabled "}] = Env.warnings()

      log = ExUnit.CaptureLog.capture_log(fn -> assert Env.replay_warnings() == 1 end)

      assert log =~ @var
      assert log =~ "unrecognized value"
      assert Env.warnings() == [], "replay clears the buffer so a restart doesn't double-report"
    end
  end

  describe "truthy?/1" do
    test "an explicit off-spelling disables, whatever the case or padding" do
      # The only thing this changes from a bare presence check — and the one
      # reading no operator intends.
      for value <- ["false", "False", "FALSE", "0", "no", "off", " OFF "] do
        put(value)
        assert Env.truthy?(@var) == false, "expected #{inspect(value)} to disable"
      end
    end

    test "presence enables, including blank and unrecognized values" do
      # `truthy?/1` exists precisely so nil and "" stay distinguishable: `""` is
      # truthy in Elixir, so a declared-but-empty PHX_SERVER= started the server
      # before, and collapsing it into "unset" would be a silent outage.
      for value <- ["true", "1", "yes", "on", "please", ~s("true"), "", " ", "\t"] do
        put(value)
        assert Env.truthy?(@var) == true, "expected #{inspect(value)} to enable"
      end
    end

    test "only an absent variable disables by absence" do
      put(nil)
      assert Env.truthy?(@var) == false
    end

    test "does not warn on an unrecognized value" do
      # Unlike fetch/1, every non-false value is meaningful here. Matched rather
      # than compared to "": :stderr is a VM-global device.
      put("please")

      refute capture_io(:stderr, fn -> Env.truthy?(@var) end) =~ "unrecognized"
    end
  end

  describe "flag/2" do
    test "a recognized value wins over the default, in both directions" do
      put("On")
      assert Env.flag(@var, false) == true

      put("OFF")
      assert Env.flag(@var, true) == false
    end

    test "unset falls back to the default" do
      put(nil)
      assert Env.flag(@var, true) == true
      assert Env.flag(@var, false) == false
    end

    test "an unrecognized value keeps the default rather than flipping to false" do
      # The #606 shape: a security flag defaulting to on must stay on when the
      # operator's spelling can't be understood.
      put("Trueish")
      assert quietly(fn -> Env.flag(@var, true) end) == true
      assert quietly(fn -> Env.flag(@var, false) end) == false
    end
  end
end
