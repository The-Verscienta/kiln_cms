defmodule KilnCMS.Config.RuntimeEnvFlagsTest do
  @moduledoc """
  Pins how `config/runtime.exs` reads its boolean environment variables (#607),
  and in particular that `DATABASE_SSL=True` encrypts the Postgres connection
  (#606).

  `KilnCMS.Config.EnvTest` covers the parser in isolation; these evaluate the
  real config file, so they also catch a call site that stops using the parser —
  which is exactly how the original defect arose. The `DATABASE_SSL` case is not
  a spelling nicety: matching the raw value sent `True` to `false`, so an
  operator explicitly asking for TLS got credentials and every query in the
  clear, with no warning and no boot failure.

  This file absorbed the former `runtime_audit_flag_test.exs` (#605), which
  covered `KILN_AUDIT_ANCHOR_EVERY_WRITE` alone with its own copy of this
  harness. Everything unique to it — the `:test`-env skip, `:not_written` being
  distinct from a written `false`, and the warning reaching stderr through the
  real config path — is in the `KILN_AUDIT_ANCHOR_EVERY_WRITE` block below.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  # runtime.exs's :prod branch reads these and raises without them.
  @prod_env %{
    "DATABASE_URL" => "ecto://u:p@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "TOKEN_SIGNING_SECRET" => String.duplicate("y", 64)
  }

  # Every var these tests touch, so each case starts from a known-clean slate
  # rather than inheriting the developer's shell or a previous case — and, just
  # as importantly, so the suite that runs after them does too. The file this
  # replaced set @prod_env and never restored it.
  @vars ~w(
            DATABASE_SSL ECTO_IPV6 VISUAL_EDITING_ENABLED KILN_UPDATE_CHECK
            KILN_AUDIT_ANCHOR_EVERY_WRITE
          ) ++ Map.keys(@prod_env)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  # Evaluate runtime.exs the way a release does; return the resulting config.
  # Warnings from deliberately unrecognized values are captured, not printed.
  defp eval(vars, env \\ :prod), do: elem(eval_io(vars, env), 0)

  # As `eval/2`, but also returns whatever runtime.exs wrote to stderr — the
  # only observable difference between "kept the default because unset" and
  # "kept the default because the value made no sense".
  defp eval_io(vars, env) do
    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)

    Enum.each(vars, fn
      {var, nil} -> System.delete_env(var)
      {var, value} -> System.put_env(var, value)
    end)

    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        send(parent, {:config, Config.Reader.read!(@runtime, env: env)})
      end)

    receive do
      {:config, config} -> {config, stderr}
    after
      0 -> flunk("runtime.exs did not evaluate")
    end
  end

  defp repo_ssl(value) do
    %{"DATABASE_SSL" => value} |> eval() |> get_in([:kiln_cms, KilnCMS.Repo, :ssl])
  end

  describe "DATABASE_SSL (#606)" do
    test "unset encrypts — the safe default is unchanged" do
      assert repo_ssl(nil) == true
    end

    test "every on-spelling encrypts, whatever the case or padding" do
      # The regression: `True`, `TRUE` and `" true "` all fell through to
      # `false` and silently downgraded the connection to plaintext.
      for value <- ["true", "True", "TRUE", " true ", "1", "yes", "on", "On"] do
        assert repo_ssl(value) == true,
               "DATABASE_SSL=#{inspect(value)} must not disable Postgres TLS"
      end
    end

    test "an explicit off-spelling still disables it, for providers without TLS" do
      for value <- ["false", "False", "0", "no", "off", "OFF"] do
        assert repo_ssl(value) == false
      end
    end

    test "an unrecognized value keeps TLS on and warns, rather than downgrading" do
      for value <- ["enabled", ~s("true"), "y", "maybe"] do
        assert repo_ssl(value) == true,
               "DATABASE_SSL=#{inspect(value)} must not be read as a request for plaintext"
      end
    end

    test "ssl_opts are attached whenever TLS is on, and omitted when it is off" do
      # Regression guard for the `++ if(database_ssl?, ...)` tail: a mismatch
      # between the `ssl:` flag and `ssl_opts:` would either error at connect
      # or silently drop peer verification.
      on = eval(%{"DATABASE_SSL" => "True"}) |> get_in([:kiln_cms, KilnCMS.Repo])
      assert on[:ssl] == true
      assert on[:ssl_opts] == [verify: :verify_none]

      off = eval(%{"DATABASE_SSL" => "false"}) |> get_in([:kiln_cms, KilnCMS.Repo])
      assert off[:ssl] == false
      refute Keyword.has_key?(off, :ssl_opts)
    end
  end

  describe "ECTO_IPV6" do
    defp socket_options(value) do
      %{"ECTO_IPV6" => value}
      |> eval()
      |> get_in([:kiln_cms, KilnCMS.Repo, :socket_options])
    end

    test "unset stays on IPv4" do
      assert socket_options(nil) == []
    end

    test "on-spellings select inet6 regardless of case" do
      for value <- ["true", "TRUE", " 1 ", "yes", "on"] do
        assert socket_options(value) == [:inet6],
               "ECTO_IPV6=#{inspect(value)} should select inet6"
      end
    end

    test "off-spellings and unrecognized values stay on IPv4" do
      for value <- ["false", "Off", "0", "gibberish"] do
        assert socket_options(value) == []
      end
    end
  end

  describe "VISUAL_EDITING_ENABLED" do
    defp visual_editing(value) do
      %{"VISUAL_EDITING_ENABLED" => value}
      |> eval()
      |> get_in([:kiln_cms, :visual_editing_enabled])
    end

    test "unset writes nothing, leaving the compiled default in force" do
      assert visual_editing(nil) == nil
    end

    test "off-spellings disable the bridge in any case" do
      # `False` used to leave the bridge ON, contradicting
      # docs/environment-variables.md, which documents `false`/`0`/`no`/`off`.
      for value <- ["false", "False", "FALSE", " off ", "0", "no", "OFF"] do
        assert visual_editing(value) == false,
               "VISUAL_EDITING_ENABLED=#{inspect(value)} should disable the bridge"
      end
    end

    test "on-spellings enable it explicitly" do
      for value <- ["true", "True", "1", "yes", "On"] do
        assert visual_editing(value) == true
      end
    end

    test "an unrecognized value writes nothing rather than reading as on" do
      assert visual_editing("enabled") == nil
    end
  end

  describe "KILN_UPDATE_CHECK" do
    defp update_check(value) do
      %{"KILN_UPDATE_CHECK" => value}
      |> eval()
      |> get_in([:kiln_cms, Kiln.Updates])
    end

    test "unset writes nothing, so the compiled default (enabled) stands" do
      updates = update_check(nil)
      assert updates == nil or not Keyword.has_key?(updates, :enabled)
    end

    test "off-spellings disable the outbound check in any case" do
      for value <- ["false", "FALSE", "Off", "0", "no"] do
        assert update_check(value)[:enabled] == false,
               "KILN_UPDATE_CHECK=#{inspect(value)} should stop the outbound request"
      end
    end

    test "on-spellings enable it explicitly, overriding an overlay that turned it off" do
      assert update_check("True")[:enabled] == true
    end

    test "an unrecognized value leaves the setting alone" do
      updates = update_check("nope")
      assert updates == nil or not Keyword.has_key?(updates, :enabled)
    end
  end

  describe "KILN_AUDIT_ANCHOR_EVERY_WRITE (#356/#605)" do
    # The flag decides whether every versioned write is signed and anchored, so
    # the direction it fails in matters. `:not_written` is distinct from a
    # written `false`: the former keeps whatever the compiled config (or a
    # project overlay) chose, the latter overrides it.
    defp anchor_every_write(value, env \\ :prod) do
      {config, stderr} = eval_io(%{"KILN_AUDIT_ANCHOR_EVERY_WRITE" => value}, env)

      written =
        case get_in(config, [:kiln_cms, :audit_anchor_every_write]) do
          nil -> :not_written
          bool -> bool
        end

      {written, stderr}
    end

    test "on-spellings enable it, in any case and with surrounding space" do
      for value <- ["true", "TRUE", "True", " true ", "1", "yes", "YES", "on", "On"] do
        assert {true, _} = anchor_every_write(value), "expected #{inspect(value)} to enable it"
      end
    end

    test "off-spellings disable it, in any case" do
      for value <- ["false", "FALSE", "False", " off ", "0", "no", "NO", "OFF"] do
        assert {false, _} = anchor_every_write(value), "expected #{inspect(value)} to disable it"
      end
    end

    test "unset writes nothing, leaving the compiled default in force" do
      assert {:not_written, _} = anchor_every_write(nil)
    end

    test "an unrecognized value writes nothing and warns, instead of reading as off" do
      # The regression this pins: a bare `!= ""` guard sent every typo to
      # `false`, silently disabling an audit trail a deployment had enabled.
      for value <- ["enabled", "y", "t", "True!", ~s("true"), "maybe"] do
        {written, stderr} = anchor_every_write(value)

        assert written == :not_written,
               "#{inspect(value)} must not be interpreted — it should keep the default"

        # Named, not just "unrecognized value": this evaluates the whole
        # runtime.exs, and the sibling KILN_PROVENANCE_ENABLED block emits the
        # same phrase — so a garbage value exported for that var would otherwise
        # satisfy this assertion, or fail the one below.
        assert stderr =~ "KILN_AUDIT_ANCHOR_EVERY_WRITE is set to an unrecognized value",
               "#{inspect(value)} should warn rather than be silently swallowed"
      end
    end

    test "a recognized value warns about nothing" do
      {_written, stderr} = anchor_every_write("true")
      refute stderr =~ "KILN_AUDIT_ANCHOR_EVERY_WRITE is set to an unrecognized value"
    end

    test "the block is skipped under :test so the suite is deterministic" do
      # The var is advertised in .env.example; a developer exporting it must not
      # change how the governance tests behave.
      assert {:not_written, _} = anchor_every_write("true", :test)
    end
  end
end
