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

  # #634: the stderr line is the only signal an operator gets that a flag did not
  # take effect, and in a release it reaches container stdout and nothing else.
  # `collected/0` is what lets `KilnCMS.Application` replay it through `Logger`.
  describe "collected/0" do
    setup do
      # No `on_exit` drain: `on_exit` callbacks run in a separate process from
      # the test, so they would drain the runner's (empty) dictionary, never
      # this one. Each test already gets a fresh process; this is the only
      # clearing that can do anything, and it is here for the doctest's sake.
      Env.take_collected()
      :ok
    end

    test "an unrecognized read is recorded, with what the operator typed" do
      put(" Enabled ")
      quietly(fn -> Env.fetch(@var) end)

      # The raw value, for the same reason the stderr line quotes it: the
      # trimming and downcasing are what caused the mismatch, so the normalized
      # form is the one string that isn't in their compose file.
      assert Env.collected() == [{@var, " Enabled "}]
    end

    test "recognized values, blanks and unset reads record nothing" do
      for value <- ["true", "OFF", "1", "", " ", nil] do
        put(value)
        quietly(fn -> Env.fetch(@var) end)
      end

      assert Env.collected() == []
    end

    test "several unrecognized reads are kept in the order they happened" do
      # A boot reads a dozen flags; an operator who fat-fingered two wants both,
      # in the order `runtime.exs` reached them.
      for value <- ["ture", "yess", "of"] do
        put(value)
        quietly(fn -> Env.fetch(@var) end)
      end

      assert Env.collected() == [{@var, "ture"}, {@var, "yess"}, {@var, "of"}]
    end

    test "flag/2 records too — it is the form most call sites use" do
      put("ture")
      assert quietly(fn -> Env.flag(@var, false) end) == false
      assert Env.collected() == [{@var, "ture"}]
    end

    test "truthy?/1 records nothing, because it warns about nothing" do
      # Every non-false value is meaningful for PHX_SERVER, so there is no
      # unrecognized case to report.
      put("please")
      assert Env.truthy?(@var)
      assert Env.collected() == []
    end
  end

  describe "replay_collected/0" do
    setup do
      previous = Application.get_env(:kiln_cms, :config_warnings)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:kiln_cms, :config_warnings)
          list -> Application.put_env(:kiln_cms, :config_warnings, list)
        end
      end)
    end

    defp replay(warnings) do
      Application.put_env(:kiln_cms, :config_warnings, warnings)
      ExUnit.CaptureLog.capture_log(fn -> assert Env.replay_collected() == :ok end)
    end

    test "each collected warning is re-emitted through Logger" do
      # The point of #634: `Logger` is what reaches Sentry and every other sink.
      # The stderr line `fetch/1` writes never leaves container stdout.
      log = replay([{"DATABASE_SSL", "enabled"}, {"KILN_AUDIT_ANCHOR_EVERY_WRITE", "ture"}])

      assert log =~ "DATABASE_SSL is set to an unrecognized value"
      assert log =~ ~s("enabled")
      assert log =~ "KILN_AUDIT_ANCHOR_EVERY_WRITE is set to an unrecognized value"
      assert log =~ ~s("ture")
    end

    test "it says the variable had no effect, and what to write instead" do
      # The operator's actual question is "did my flag apply?", and the answer
      # has to be in the line itself — they are reading it in Sentry, detached
      # from the config file that produced it.
      log = replay([{"DATABASE_SSL", "enabled"}])

      assert log =~ "had no effect"
      assert log =~ "true/1/yes/on"
      assert log =~ "false/0/no/off"
    end

    test "it warns, not infos — this is a misconfiguration" do
      assert replay([{"DATABASE_SSL", "enabled"}]) =~ "[warning]"
    end

    # `Sentry.Test`'s collector needs `test_mode: true` in the :sentry app config,
    # which is a global change this file has no business making. Instead: give
    # Sentry a DSN (so it will run user callbacks at all) and a `before_send`
    # that captures the event and returns nil. `before_send` runs BEFORE the DSN
    # is used in `Sentry.Client.send_event/2`, and returning nil drops the event
    # — so nothing is ever sent anywhere.
    defp capturing_sentry(fun) do
      test_pid = self()
      previous_dsn = Sentry.Config.dsn()
      previous_hook = Sentry.Config.before_send()

      on_exit(fn ->
        Sentry.Config.persist(dsn: previous_dsn, before_send: previous_hook)
      end)

      Sentry.Config.persist(
        dsn: "https://public@example.invalid/1",
        before_send: fn event ->
          send(test_pid, {:sentry_event, event})
          nil
        end
      )

      fun.()
    end

    test "it also reports to Sentry, which a Logger.warning alone does not reach" do
      # The point of the whole change, and the one part `Logger` cannot deliver:
      # `Sentry.LoggerHandler` is attached with the library's defaults
      # (`level: :error`, `capture_log_messages: false`), so a `:warning` with a
      # bare string is dropped at its first filter, and a bare string log with no
      # `:crash_reason` metadata is ignored even above that level. Without an
      # explicit `capture_message/2` this is inert for Sentry — the exact state
      # #634 was filed to end.
      capturing_sentry(fn -> replay([{"DATABASE_SSL", "enabled"}]) end)

      assert_receive {:sentry_event, event}
      assert event.message.formatted =~ "DATABASE_SSL is set to an unrecognized value"
      assert event.message.formatted =~ ~s("enabled")
      assert event.level == :warning
      # Grouped per variable, so a flag that stays wrong is one issue rather
      # than a new one on every restart.
      assert event.fingerprint == ["kiln-config-warning", "DATABASE_SSL"]
      assert event.extra[:value] == "enabled"
      assert event.extra[:variable] == "DATABASE_SSL"
    end

    test "a clean boot reports nothing to Sentry" do
      capturing_sentry(fn -> replay([]) end)
      refute_receive {:sentry_event, _}, 50
    end

    test "an empty or absent list logs nothing" do
      # `refute =~`, not `== ""`: `capture_log/1` captures every process's log
      # events, so any `warning` the running application emits in this window
      # would fail an exact-equality assertion for reasons unrelated to this.
      refute replay([]) =~ "unrecognized value"

      Application.delete_env(:kiln_cms, :config_warnings)

      refute ExUnit.CaptureLog.capture_log(fn -> Env.replay_collected() end) =~
               "unrecognized value"
    end
  end

  describe "the runtime.exs handoff (#634)" do
    @runtime_exs Path.join([__DIR__, "..", "..", "..", "config", "runtime.exs"])

    test "runtime.exs hands the collected list to :config_warnings" do
      assert File.read!(@runtime_exs) =~
               "config :kiln_cms, :config_warnings, Env.take_collected()"
    end

    test "nothing reads a flag after the handoff line" do
      # Ordering is the whole correctness argument: a variable read below the
      # handoff is warned about on stderr and nowhere else, which is exactly the
      # failure #634 exists to close. Cheap to state here, invisible otherwise —
      # a new flag appended to the bottom of runtime.exs is the natural mistake.
      source = File.read!(@runtime_exs)

      [_before, after_handoff] =
        String.split(source, "config :kiln_cms, :config_warnings", parts: 2)

      refute after_handoff =~ ~r/\bEnv\.(flag|fetch|truthy\?)\(/,
             """
             config/runtime.exs reads an environment flag below the \
             `:config_warnings` handoff. Move the read above it, or that \
             variable's unrecognized-value warning reaches stderr only (#634).\
             """
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
