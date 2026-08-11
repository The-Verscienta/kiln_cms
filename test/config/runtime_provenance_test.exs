defmodule KilnCMS.Config.RuntimeProvenanceTest do
  @moduledoc """
  Pins what `config/runtime.exs` writes for `KilnCMS.Provenance` (#608).

  Sibling of `KilnCMS.Config.RuntimeAuditFlagTest`, for the same reason: nothing
  else in the suite evaluates `runtime.exs`, so the block is invisible to every
  other test and to the whole CI gate. Two mistakes it would otherwise hide are
  specific and severe:

    * writing `:retired_keys` instead of `:retired_key_files`. Both are lists of
      `{:file, %{…}}`-shaped things to the eye, but a list of provider tuples IS
      a keyword list, so `Config` would `Keyword.merge` the runtime value into a
      source-configured `:retired_keys` and silently delete its `:file` entries —
      losing verification keys, which is the exact failure the registry exists
      to prevent.

    * a `~w(true, 1)` comma typo in the `KILN_PROVENANCE_ENABLED` cond, which
      makes the switch permanently unsettable and leaves `/api/provenance/*`
      404ing on every released image.

  `read/3` returns `:not_written` when runtime.exs leaves a key alone, which is
  distinct from writing a value: the former keeps the compiled default.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @vars ~w(KILN_PROVENANCE_ENABLED KILN_PROVENANCE_KEY_FILE KILN_PROVENANCE_RETIRED_KEY_FILES
           KILN_PROVENANCE_SIGNER KILN_PROVENANCE_ORIGIN KILN_PROVENANCE_AI_DISCLOSURE)

  # runtime.exs's :prod branch reads these and raises without them.
  @prod_env %{
    "DATABASE_URL" => "ecto://u:p@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "TOKEN_SIGNING_SECRET" => String.duplicate("y", 64)
  }

  setup do
    original = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  # Evaluate runtime.exs the way a release does; return {provenance_key, stderr}.
  # `env` overrides the provenance vars for this read; anything not named is
  # cleared, so a developer's exported value can't leak into the assertion.
  defp read(key, env, config_env \\ :prod) do
    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)

    Enum.each(@vars, fn var ->
      case Map.get(env, var) do
        nil -> System.delete_env(var)
        value -> System.put_env(var, value)
      end
    end)

    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        written =
          Config.Reader.read!(@runtime, env: config_env)
          |> get_in([:kiln_cms, KilnCMS.Provenance])
          |> case do
            nil -> :not_written
            provenance -> Keyword.get(provenance, key, :not_written)
          end

        send(parent, {:written, written})
      end)

    receive do
      {:written, written} -> {written, stderr}
    after
      0 -> flunk("runtime.exs did not evaluate")
    end
  end

  # What runtime.exs hands to `:kiln_cms, :config_warnings` for
  # `KilnCMS.Application` to replay through `Logger`/Sentry once observability
  # is attached (#634). The provenance block's own reads are the two here that
  # reach it through `Env.record_unrecognized/3` rather than a parser (#912).
  # The collected entry for one variable, or nil. Scoped to the variable rather
  # than asserting on the whole list: this file only clears the provenance vars,
  # so a developer with `DATABASE_SSL=enabled` exported would otherwise fail a
  # `== []` assertion for a reason that has nothing to do with provenance.
  defp collected_for(env, var),
    do: env |> config_warnings() |> Enum.find(&match?({^var, _raw, _expected}, &1))

  defp config_warnings(env, config_env \\ :prod) do
    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)

    Enum.each(@vars, fn var ->
      case Map.get(env, var) do
        nil -> System.delete_env(var)
        value -> System.put_env(var, value)
      end
    end)

    parent = self()

    capture_io(:stderr, fn ->
      send(parent, {:warnings, Config.Reader.read!(@runtime, env: config_env)})
    end)

    receive do
      {:warnings, config} -> get_in(config, [:kiln_cms, :config_warnings])
    after
      0 -> flunk("runtime.exs did not evaluate")
    end
  end

  describe "KILN_PROVENANCE_ENABLED" do
    test "on-spellings enable it, in any case and with surrounding space" do
      for value <- ["true", "TRUE", "True", " true ", "1", "yes", "YES", "on", "On"] do
        assert {true, _} = read(:enabled, %{"KILN_PROVENANCE_ENABLED" => value}),
               "expected #{inspect(value)} to enable provenance"
      end
    end

    test "off-spellings disable it, in any case" do
      for value <- ["false", "FALSE", "False", " off ", "0", "no", "NO", "OFF"] do
        assert {false, _} = read(:enabled, %{"KILN_PROVENANCE_ENABLED" => value}),
               "expected #{inspect(value)} to disable provenance"
      end
    end

    test "unset writes nothing, leaving the compiled default in force" do
      assert {:not_written, _} = read(:enabled, %{})
    end

    test "an unrecognized value writes nothing and warns" do
      for value <- ["enabled", "y", "t", "True!", ~s("true"), "maybe"] do
        {written, stderr} = read(:enabled, %{"KILN_PROVENANCE_ENABLED" => value})

        assert written == :not_written,
               "#{inspect(value)} must not be interpreted — it should keep the default"

        assert stderr =~ "KILN_PROVENANCE_ENABLED is set to an unrecognized value",
               "#{inspect(value)} should warn rather than be silently swallowed"
      end
    end
  end

  describe "KILN_PROVENANCE_KEY_FILE" do
    test "sets the :file provider tuple, replacing the compiled :env binding" do
      assert {{:file, %{"path" => "/run/secrets/kiln.pem"}}, _} =
               read(:signing_key, %{"KILN_PROVENANCE_KEY_FILE" => " /run/secrets/kiln.pem "})
    end

    test "unset writes nothing, leaving the compiled :env binding in force" do
      assert {:not_written, _} = read(:signing_key, %{})
    end
  end

  describe "KILN_PROVENANCE_RETIRED_KEY_FILES" do
    test "writes bare paths under :retired_key_files, never :retired_keys" do
      env = %{
        "KILN_PROVENANCE_RETIRED_KEY_FILES" => "/etc/kiln/2025.pub.pem,/etc/kiln/2024.pub.pem"
      }

      assert {["/etc/kiln/2025.pub.pem", "/etc/kiln/2024.pub.pem"], _} =
               read(:retired_key_files, env)

      # The whole point of the separate key: runtime.exs must never write
      # :retired_keys, so Config cannot Keyword.merge over a source-configured one.
      assert {:not_written, _} = read(:retired_keys, env)
    end

    test "the written value is not a keyword list, so Config replaces it cleanly" do
      {paths, _} = read(:retired_key_files, %{"KILN_PROVENANCE_RETIRED_KEY_FILES" => "/a.pem"})
      refute Keyword.keyword?(paths)
    end

    test "a value with no paths in it warns and writes nothing" do
      # `KILN_PROVENANCE_RETIRED_KEY_FILES=,` — or a shell expanding an unset
      # variable into a bare separator — must not clear the configured list.
      for value <- [",", " , ", ",,,"] do
        {written, stderr} =
          read(:retired_key_files, %{"KILN_PROVENANCE_RETIRED_KEY_FILES" => value})

        assert written == :not_written,
               "#{inspect(value)} must not deregister the configured retired keys"

        assert stderr =~ "KILN_PROVENANCE_RETIRED_KEY_FILES"
      end
    end

    test "unset writes nothing" do
      assert {:not_written, _} = read(:retired_key_files, %{})
    end
  end

  describe "environment scoping" do
    test "the whole block is skipped under :test so the suite is deterministic" do
      env = %{
        "KILN_PROVENANCE_ENABLED" => "true",
        "KILN_PROVENANCE_KEY_FILE" => "/run/secrets/kiln.pem",
        "KILN_PROVENANCE_RETIRED_KEY_FILES" => "/etc/kiln/2025.pub.pem"
      }

      assert {:not_written, _} = read(:enabled, env, :test)
      assert {:not_written, _} = read(:retired_key_files, env, :test)
      assert {:not_written, _} = read(:signing_key, env, :test)
    end
  end

  describe "merged against the compiled config" do
    # `read/3` reads runtime.exs alone. These merge it with config/config.exs
    # the way a release's config provider does, which is where the deep-merge
    # hazard actually lives — a key written correctly in isolation can still
    # destroy the compiled value once merged.
    @compiled Path.expand("../../config/config.exs", __DIR__)

    defp merged(env) do
      Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)

      Enum.each(@vars, fn var ->
        case Map.get(env, var) do
          nil -> System.delete_env(var)
          value -> System.put_env(var, value)
        end
      end)

      capture_io(:stderr, fn ->
        compiled = Config.Reader.read!(@compiled, env: :prod)
        runtime = Config.Reader.read!(@runtime, env: :prod)
        send(self(), {:merged, Config.Reader.merge(compiled, runtime)})
      end)

      receive do: ({:merged, config} -> get_in(config, [:kiln_cms, KilnCMS.Provenance]))
    end

    test "the retired-key var adds to, and never removes from, :retired_keys" do
      provenance = merged(%{"KILN_PROVENANCE_RETIRED_KEY_FILES" => "/etc/kiln/2025.pub.pem"})

      # If runtime.exs wrote :retired_keys instead, Config would Keyword.merge
      # the two lists and any `{:file, …}` entry compiled in would be deleted.
      assert Keyword.fetch!(provenance, :retired_keys) == []
      assert Keyword.fetch!(provenance, :retired_key_files) == ["/etc/kiln/2025.pub.pem"]
    end

    test "the key-file var replaces the compiled :env binding rather than merging with it" do
      provenance = merged(%{"KILN_PROVENANCE_KEY_FILE" => "/run/secrets/kiln.pem"})

      assert Keyword.fetch!(provenance, :signing_key) ==
               {:file, %{"path" => "/run/secrets/kiln.pem"}}
    end

    test "enabling leaves the rest of the compiled claim config intact" do
      provenance = merged(%{"KILN_PROVENANCE_ENABLED" => "true"})

      assert Keyword.fetch!(provenance, :enabled) == true

      assert Keyword.fetch!(provenance, :signing_key) ==
               {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}

      assert Keyword.fetch!(provenance, :ai_disclosure) == :human
    end

    test "with nothing exported the compiled defaults survive untouched" do
      provenance = merged(%{})

      assert Keyword.fetch!(provenance, :enabled) == false

      assert Keyword.fetch!(provenance, :signing_key) ==
               {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}

      assert Keyword.fetch!(provenance, :retired_keys) == []
    end
  end

  describe "KILN_PROVENANCE_SIGNER / KILN_PROVENANCE_ORIGIN (#644)" do
    test "the signer identity is written when set, nothing when unset or blank" do
      assert {"Acme Editorial", _} =
               read(:signer, %{"KILN_PROVENANCE_SIGNER" => "Acme Editorial"})

      # Unset and blank both keep the compiled default (which falls back to the
      # site name), so the `nil`-means-fall-back semantics survive.
      assert {:not_written, _} = read(:signer, %{})
      assert {:not_written, _} = read(:signer, %{"KILN_PROVENANCE_SIGNER" => "   "})
    end

    test "the origin URL is written when set, nothing when unset" do
      assert {"https://acme.com", _} =
               read(:origin, %{"KILN_PROVENANCE_ORIGIN" => "https://acme.com"})

      assert {:not_written, _} = read(:origin, %{})
    end
  end

  describe "KILN_PROVENANCE_AI_DISCLOSURE (#644)" do
    test "a valid disclosure is written, case- and whitespace-insensitively" do
      for value <- ["human", "AI_ASSISTED", " ai_generated "] do
        {written, _} = read(:ai_disclosure, %{"KILN_PROVENANCE_AI_DISCLOSURE" => value})

        assert written == value |> String.trim() |> String.downcase(),
               "#{inspect(value)} should be normalized and written"
      end
    end

    test "unset writes nothing, keeping the compiled default" do
      assert {:not_written, _} = read(:ai_disclosure, %{})
    end

    test "an unrecognized value warns and writes nothing, rather than coercing into a signed claim" do
      {written, stderr} =
        read(:ai_disclosure, %{"KILN_PROVENANCE_AI_DISCLOSURE" => "sometimes"})

      assert written == :not_written
      assert stderr =~ "KILN_PROVENANCE_AI_DISCLOSURE is set to an unrecognized value"
      # "Use one of:", the same phrasing every other spelling-list warning in
      # this module uses — the point of routing this through `Env.one_of/2` is
      # that the operator sees one sentence shape whatever the variable is.
      assert stderr =~ "Use one of: #{Enum.join(KilnCMS.Provenance.disclosures(), "/")}."
    end

    # #912. The stderr line above is the only signal this block used to produce,
    # and in a release stderr is container stdout and nothing else — no Sentry,
    # no log sink. That is the failure #634 exists to close, and it lands harder
    # here than on a flag: the value rides into a SIGNED claim, so an operator
    # who misspells it ships the compiled default in every manifest a consumer
    # verifies, and hears about it once, at boot, in a scrolling deploy log.
    test "the unrecognized value is collected, so the replay reaches Sentry" do
      assert {"KILN_PROVENANCE_AI_DISCLOSURE", "sometimes", expected} =
               collected_for(
                 %{"KILN_PROVENANCE_AI_DISCLOSURE" => "sometimes"},
                 "KILN_PROVENANCE_AI_DISCLOSURE"
               )

      # The allowed list itself, not a rendered sentence: `replay_collected/0`
      # generates the advice from it, so the operator's "use one of…" can never
      # drift from the list the value was actually checked against.
      assert expected == {:one_of, KilnCMS.Provenance.disclosures()}
    end

    test "the collected value is what the operator typed, not the normalized form" do
      assert {_var, " Sometimes ", _expected} =
               collected_for(
                 %{"KILN_PROVENANCE_AI_DISCLOSURE" => " Sometimes "},
                 "KILN_PROVENANCE_AI_DISCLOSURE"
               )
    end

    test "a recognized value collects nothing" do
      refute collected_for(
               %{"KILN_PROVENANCE_AI_DISCLOSURE" => "ai_assisted"},
               "KILN_PROVENANCE_AI_DISCLOSURE"
             )
    end
  end

  # The same class as the disclosure above: a value that parses to no paths
  # would deregister every retired verification key, which is the failure the
  # variable exists to prevent — so its warning has to reach Sentry too (#912).
  describe "KILN_PROVENANCE_RETIRED_KEY_FILES collection (#912)" do
    test "a value with no paths in it is collected, not warned about on stderr only" do
      assert {"KILN_PROVENANCE_RETIRED_KEY_FILES", ",,,", expected} =
               collected_for(
                 %{"KILN_PROVENANCE_RETIRED_KEY_FILES" => ",,,"},
                 "KILN_PROVENANCE_RETIRED_KEY_FILES"
               )

      assert expected == {:expected, "a comma-separated list of PEM file paths"}
    end

    test "a real list collects nothing" do
      refute collected_for(
               %{"KILN_PROVENANCE_RETIRED_KEY_FILES" => "/a.pem,/b.pem"},
               "KILN_PROVENANCE_RETIRED_KEY_FILES"
             )
    end
  end
end
