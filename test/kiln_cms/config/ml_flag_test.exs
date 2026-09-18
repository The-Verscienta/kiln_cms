defmodule KilnCMS.Config.MLFlagTest do
  @moduledoc """
  Unit tests for the standalone `KILN_ML` parser (#1321).

  `config/ml_flag.exs` is not part of `lib/` — `mix.exs` and `config/dev.exs` /
  `config/test.exs` all need the answer before `lib/` compiles. `mix.exs`
  requires the file on every Mix invocation, so `KilnCMS.Config.MLFlag` is
  already loaded by the time this suite runs; no `Code.require_file/2` here.

  `async: false`: the wiring tests set `KILN_ML` in the process environment,
  which is global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Config.Env
  alias KilnCMS.Config.MLFlag
  alias KilnCMS.Config.StrictTestFlag

  @var "KILN_ML"

  setup do
    previous = System.get_env(@var)

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    :ok
  end

  test "the spelling table is the shared one, not a third copy" do
    # `config/ml_flag.exs` reads these from `KilnCMS.Config.StrictTestFlag`
    # rather than restating them, so `strict_test_flag_test.exs`'s sync
    # assertion against `KilnCMS.Config.Env` covers this flag too. This pins
    # that arrangement: a future edit that pastes the table into ml_flag.exs
    # reintroduces exactly the drift #646 was about.
    assert StrictTestFlag.true_values() == Env.true_values()
    assert StrictTestFlag.false_values() == Env.false_values()
  end

  describe "enabled?/1" do
    test "on-spellings enable the stack, in any case and with surrounding whitespace" do
      for value <- ["true", "TRUE", "True", " true ", "1", "yes", "YES", "on", "On"] do
        assert MLFlag.enabled?(value), "expected #{inspect(value)} to enable the ML stack"
      end
    end

    test "off-spellings, unset, blank and unrecognized values all stay lean" do
      for value <- [nil, "", " ", "false", "FALSE", "0", "no", "off"] do
        refute MLFlag.enabled?(value), "expected #{inspect(value)} to stay lean"
      end

      for value <- ["enabled", "maybe"] do
        {enabled?, _warning} = with_io(:stderr, fn -> MLFlag.enabled?(value) end)
        refute enabled?, "expected #{inspect(value)} to stay lean"
      end
    end

    test "and agrees with KilnCMS.Config.Env on every spelling" do
      # The invariant that lets the flag live outside `lib/` at all: whatever
      # `mix.exs` decided at build time is what a runtime reader of the same
      # variable would have decided.
      values = ~w(true 1 yes on TRUE false 0 no off FALSE) ++ [" on ", "", "lm", "ml"]

      for value <- values do
        System.put_env(@var, value)
        {snippet, _} = with_io(:stderr, fn -> MLFlag.enabled?() end)
        {shared, _} = with_io(:stderr, fn -> Env.flag(@var, false) end)

        assert snippet == shared,
               "#{inspect(value)}: config/ml_flag.exs says #{snippet}, " <>
                 "KilnCMS.Config.Env says #{shared}"
      end
    end
  end

  describe "an unrecognized value" do
    test "says so on stderr, quoting what was typed" do
      # Without this the build is silently lean, compiles clean, and the only
      # symptom is semantic search reporting itself unavailable — with nothing
      # for the operator, who believes they asked for it, to grep for.
      output = capture_io(:stderr, fn -> MLFlag.enabled?(" ML ") end)

      assert output =~ @var
      # The operator's own bytes, untrimmed — the trimming is what caused the
      # mismatch, so the normalized form hides the only greppable clue.
      assert output =~ ~s(" ML ")
      assert output =~ "WITHOUT the optional ML stack"
    end

    test "and a recognized value, blank or unset stays quiet" do
      for value <- [nil, "", "true", "1", "yes", "on", "false", "0", "no", "off", " TRUE "] do
        assert capture_io(:stderr, fn -> MLFlag.enabled?(value) end) == "",
               "expected #{inspect(value)} not to warn"
      end
    end
  end

  # The unit tests above prove the parser is right. These prove it is the thing
  # actually deciding the build.
  describe "the wiring" do
    test "mix.exs puts the ML deps in the tree exactly when the flag is on" do
      names = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      ml = MapSet.new([:bumblebee, :nx, :exla])

      if MLFlag.enabled?() do
        assert MapSet.subset?(ml, names)
      else
        assert MapSet.disjoint?(ml, names),
               "expected no ML deps in a lean tree, found " <>
                 inspect(MapSet.to_list(MapSet.intersection(ml, names)))
      end

      # pgvector is the storage half and is never gated: `installed_extensions`
      # needs the `vector` extension whether or not anything embeds.
      assert :pgvector in names
    end

    test "config/test.exs points Nx at EXLA.Backend only when the flag is on" do
      # Evaluates the real config file, so this is the value the compiled build
      # would carry.
      assert read_nx_backend("1") == EXLA.Backend
      assert read_nx_backend("true") == EXLA.Backend
      # Not merely a different backend — the key must be ABSENT, because
      # configuring an app that is not in the tree is what makes Mix warn.
      assert read_nx_backend("0") == nil
      assert read_nx_backend(nil) == nil
    end

    defp read_nx_backend(value) do
      if value, do: System.put_env(@var, value), else: System.delete_env(@var)

      "config/test.exs"
      |> Config.Reader.read!(env: :test)
      |> get_in([:nx, :default_backend])
    end
  end
end
