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
