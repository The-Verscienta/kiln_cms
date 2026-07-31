defmodule KilnCMS.Config.RuntimeAuditFlagTest do
  @moduledoc """
  Pins how `config/runtime.exs` parses `KILN_AUDIT_ANCHOR_EVERY_WRITE` (#356).

  The flag decides whether every versioned write is signed and anchored, so the
  direction it fails in matters: an unrecognized value must NOT read as "off".
  Nothing else in the suite evaluates `runtime.exs`, so without this a refactor
  could make the flag permanently unsettable — `~w(true, 1)` with commas yields
  `["true,", "1,"]` — while the whole CI gate stayed green.

  `read/2` returns `:not_written` when runtime.exs leaves the key alone, which
  is distinct from writing `false`: the former keeps whatever the compiled
  config (or a project overlay) chose, the latter overrides it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @var "KILN_AUDIT_ANCHOR_EVERY_WRITE"
  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  # runtime.exs's :prod branch reads these and raises without them.
  @prod_env %{
    "DATABASE_URL" => "ecto://u:p@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "TOKEN_SIGNING_SECRET" => String.duplicate("y", 64)
  }

  # Evaluate runtime.exs the way a release does; return {written_value, stderr}.
  defp read(value, env \\ :prod) do
    original = System.get_env(@var)
    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    if value, do: System.put_env(@var, value), else: System.delete_env(@var)

    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        config = Config.Reader.read!(@runtime, env: env)

        written =
          case get_in(config, [:kiln_cms, :audit_anchor_every_write]) do
            nil -> :not_written
            bool -> bool
          end

        send(parent, {:written, written})
      end)

    if original, do: System.put_env(@var, original), else: System.delete_env(@var)

    receive do
      {:written, written} -> {written, stderr}
    after
      0 -> flunk("runtime.exs did not evaluate")
    end
  end

  describe "recognized spellings" do
    test "on-spellings enable it, in any case and with surrounding space" do
      for value <- ["true", "TRUE", "True", " true ", "1", "yes", "YES", "on", "On"] do
        assert {true, _} = read(value), "expected #{inspect(value)} to enable the flag"
      end
    end

    test "off-spellings disable it, in any case" do
      for value <- ["false", "FALSE", "False", " off ", "0", "no", "NO", "OFF"] do
        assert {false, _} = read(value), "expected #{inspect(value)} to disable the flag"
      end
    end
  end

  describe "fail-safe behaviour" do
    test "unset writes nothing, leaving the compiled default in force" do
      assert {:not_written, _} = read(nil)
    end

    test "an unrecognized value writes nothing and warns, instead of reading as off" do
      # The regression this pins: a bare `!= ""` guard sent every typo to
      # `false`, silently disabling an audit trail a deployment had enabled.
      for value <- ["enabled", "y", "t", "True!", ~s("true"), "maybe"] do
        {written, stderr} = read(value)

        assert written == :not_written,
               "#{inspect(value)} must not be interpreted — it should keep the default"

        assert stderr =~ "unrecognized value",
               "#{inspect(value)} should warn rather than be silently swallowed"
      end
    end

    test "a recognized value warns about nothing" do
      {_written, stderr} = read("true")
      refute stderr =~ "unrecognized value"
    end
  end

  describe "environment scoping" do
    test "the block is skipped under :test so the suite is deterministic" do
      # The var is advertised in .env.example; a developer exporting it must not
      # change how the governance tests behave.
      assert {:not_written, _} = read("true", :test)
    end
  end
end
