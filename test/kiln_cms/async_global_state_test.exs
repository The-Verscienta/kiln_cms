defmodule KilnCMS.AsyncGlobalStateTest do
  @moduledoc """
  No `async: true` test module may write VM-global state that another test
  reads: `Application.put_env/delete_env/put_all_env`, `System.put_env/delete_env`
  or `:persistent_term` (#1067, #2380, #2559).

  Application env, OS env and persistent terms are shared by every process in
  the VM. An `async: true` module that writes one changes it for every other
  async module running at the same moment, and its `on_exit` puts it back
  before anyone notices. Restoring the value afterwards does not help; the
  damage is done while the test runs.

  What that costs is the reason this file exists rather than a comment. It
  presents as a timing bug and is not one: fails only under load or in a full
  run, passes in isolation, moves with the seed.

    * #1067 was filed as a presence race. The real cause was
      `KilnCMSWeb.CollabSavedRefreshTest` flipping `:collab_prototype` off while
      other tests mounted editors.
    * #2380 was filed as a leftover override. The real cause was
      `KilnCMS.Accounts.DraftWriteKeyTest` lowering
      `:draft_write_key_max_ttl_days` to 3 while
      `KilnCMSWeb.DraftWriteKeyProvenanceReadTest` minted 7-day keys.

  The node-wide delivery caches are the same kind of state (#2504):
  `KilnCMS.Cache.flush_delivery/0`, `KilnCMS.Cache.ClusterBust.broadcast_clear/0`,
  `KilnCMS.Firing.Cache.clear/0`, or a `Cachex.clear/1,2` or `Cachex.clear!/1,2`
  of `KilnCMS.Cache` or `KilnCMS.Firing.Cache` (piped, or through a module
  attribute), empties them under every async test that warmed an entry and is
  about to read it back (`KilnCMS.Firing.DeliveryTest`'s warm reads came back
  `:unavailable` in a full run). Those calls count as writes too.

  Writes made on a test's behalf count as well (#2559):

    * A `test/support` function that writes, directly or through any chain of
      local calls, remote calls or `&fun/arity` captures into other support
      functions (`KilnCMS.SiteSsoFixtures.publish!/1` writes through
      `KilnCMS.Test.StubDNS.put_txt/2`). The set is derived from the support
      sources on every run, not kept by hand, so a new writing helper is
      covered the day it is written. Calls are resolved through `alias`
      (with `as:`) and `import` (honoring `only:`/`except:`), so a bare
      `enable!()` is matched to the module it was imported from.
    * Igniter's `test_project`, `phx_test_project`, `apply_igniter(!)` and
      `Igniter.compose_task`: Igniter evaluates the rewritten project's
      config and applies it with `Application.put_all_env/1`, whatever the
      fixture says (#2380 came from the generator, not the fixture).

  A `use`d support module counts as a call to its `__using__`, so a write in
  the quote it injects is seen. Not seen: a write inside a library other than
  Igniter, and a bare call to a function that a `__using__` quote imports
  (only `import` lines in the test module itself are read).

  So the rule is checked instead of remembered. `async: false` costs almost
  nothing: ExUnit runs sync modules after the async ones, so the time moves
  phase rather than adding up.

  The check is per module, not per file: a file may hold an `async: true`
  module and a nested `async: false` one that does the writing. A module that
  is not a test case (a fixture module defined inside a test) counts as the
  module around it, since that is where its code runs.

  A static read of the test files, deliberately: the failure this prevents is
  two modules running *concurrently*, which a runtime check cannot observe
  without being the very race it is looking for.
  """
  use ExUnit.Case, async: true

  # Modules that may write while async, by `{module, app, key}`. Each is a key
  # no code reached from another async test reads, so a concurrent test cannot
  # see the change. A key, not a module, so the next write in the same module
  # is checked again; the app too, so `:plugins` under another app is not
  # covered. `:collab_prototype` can never be listed (#1067).
  #
  # An OS env name built by interpolation is keyed by its literal prefix and a
  # `*` (`"KILN_TEST_DKIM_*"`), so any name with that prefix in that module is
  # covered: the entry's reason has to hold for the whole prefix.
  @allowed %{
    {"Kiln.PluginsTest", ":kiln_cms", ":plugins"} =>
      "read at runtime only by `mix kiln.plugins.doctor`, which no other async test runs; " <>
        "`Kiln.Plugins` reads it with compile_env",
    {"KilnCMS.Collab.CrdtTest", ":kiln_cms", ":collab_max_documents"} =>
      "read once at boot to size the document supervisor, and in a log line no test reaches",
    {"KilnCMS.Governance.Witness.HTTPTest", ":kiln_cms", "HTTP"} =>
      "read only when the witness adapter is HTTP, which only async: false tests select",
    {"KilnCMS.Governance.Witness.HTTPTest", "System", "KILN_TEST_WITNESS_TOKEN"} =>
      "a name no other test or config uses; read only by the HTTP witness config built " <>
        "in the same test",
    {"KilnCMS.KeysTest", "System", "KILN_TEST_DKIM_*"} =>
      "each test names its variable `KILN_TEST_DKIM_<unique integer>`, so no other test " <>
        "can name it, and the env key provider reads it uncached",
    {"KilnCMS.MailSettingsTest", "System", "KILN_TEST_DKIM_*"} =>
      "each test names its variable `KILN_TEST_DKIM_<unique integer>`, so no other test " <>
        "can name it, and the env key provider reads it uncached"
  }

  # `test/support` functions that write, but whose write no other test can
  # see, so an async module may call them, and a helper that writes only
  # through them does not count as writing either. Keyed by
  # `{module, function}`; the reason is about the key written.
  @safe_writers %{
    {"KilnCMS.SiteSsoFixtures", :publish!} =>
      "writes `{StubDNS, :txt, name}` for the row's own domain, which every caller takes " <>
        "from `unique_domain/1` or a unique integer; only a TXT lookup of that name reads it",
    {"KilnCMS.SiteSsoFixtures", :unpublish!} =>
      "erases `{StubDNS, :txt, name}` for the row's own domain, as `publish!/1` above"
  }

  @never_allowed ":collab_prototype"

  # What a module needs to resolve a call: its aliases (`as:` included), its
  # imports, its attributes and the functions it defines.
  @empty_env %{module: nil, aliases: %{}, imports: [], attrs: %{}, locals: MapSet.new()}

  setup_all do
    sources = support_sources()

    %{
      all_writers: support_writers(sources),
      writers: support_writers(sources, safe_writer_keys())
    }
  end

  test "no async: true module writes VM-global state", %{writers: writers} do
    offenders =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.flat_map(&writes_in_async_modules(&1, writers))
      |> Enum.reject(&allowed?/1)

    assert offenders == [],
           """
           These `async: true` test modules write VM-global state:

           #{Enum.map_join(offenders, "\n", &describe/1)}

           Every other async test sees the new value for as long as the test
           runs, and `on_exit` restores it too late to help. Move the test into
           an `async: false` module, keeping the `on_exit` that restores the
           original value (see KilnCMS.Accounts.DraftWriteKeyConfigTest, #2380).
           If nothing another async test runs reads the key, add it to @allowed
           in #{Path.relative_to_cwd(__ENV__.file)} with the reason (or, for a
           `test/support` helper whose key no other test can see, to
           @safe_writers).
           """
  end

  test "every allowlist entry still names a write", %{writers: writers} do
    found =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.flat_map(&writes_in_async_modules(&1, writers))
      |> MapSet.new(&{&1.module, &1.app, &1.key})

    stale = @allowed |> Map.keys() |> Enum.reject(&(&1 in found))

    assert stale == [],
           "Allowlisted writes no longer found, so drop them from @allowed: #{inspect(stale)}"
  end

  test "every safe-writer entry is still a support writer", %{all_writers: found} do
    stale = safe_writer_keys() |> Enum.reject(&(&1 in found)) |> Enum.sort()

    assert stale == [],
           "These no longer write, so drop them from @safe_writers: #{inspect(stale)}"
  end

  # A sample from the real tree, one per way a helper comes to write, so a
  # wrong glob or a broken resolver cannot leave the derived set quietly empty.
  test "the support scan finds the helpers that write", %{all_writers: found} do
    expected = [
      # direct
      {"KilnCMS.RateLimitHelpers", :put_limit},
      {"KilnCMS.Test.StubDNS", :put_txt},
      # only inside an on_exit callback
      {"KilnCMS.Test.SearchHold", :release_on_exit},
      # through a local capture (`on_exit(&restore_limits/0)`)
      {"KilnCMS.RateLimitHelpers", :restore_limits_on_exit},
      # through another support module
      {"KilnCMS.SiteSsoFixtures", :publish!},
      # through a local call (`enable!` calls `put_config`)
      {"KilnCMS.ExperimentFixtures", :enable!},
      # System env
      {"KilnCMS.ChallengeFixtures", :enable!}
    ]

    assert Enum.reject(expected, &(&1 in found)) == []
    refute {"KilnCMS.Test.StubDNS", :txt} in found
  end

  describe "the check can fail" do
    # Otherwise a change to how async-ness or a write is recognized would leave
    # this passing forever, which is how the original leaks survived.
    test "an async module that writes app env" do
      assert [%{module: "A", key: ":some_key", call: "Application.put_env"}] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: true
                 test "t", do: Application.put_env(:kiln_cms, :some_key, 1)
               end
               """)

      assert [%{call: "Application.delete_env"}] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 setup do
                   on_exit(fn -> Application.delete_env(:kiln_cms, :some_key) end)
                 end
               end
               """)
    end

    test "an async module that writes a persistent term" do
      assert [%{key: "{Mod, :cached}", call: ":persistent_term.put"}] =
               offenders_in("""
               defmodule A do
                 use KilnCMSWeb.ConnCase, async: true
                 test "t", do: :persistent_term.put({Mod, :cached}, false)
               end
               """)
    end

    test "a fixture module inside an async module counts as async" do
      assert [%{module: "A.Fixture"}] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 defmodule Fixture do
                   def go, do: Application.put_env(:kiln_cms, :k, 1)
                 end
               end
               """)
    end

    test "an async module nested in a sync one is still async" do
      assert [%{module: "A.Inner"}] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: false
                 defmodule Inner do
                   use ExUnit.Case, async: true
                   test "t", do: Application.put_env(:kiln_cms, :k, 1)
                 end
               end
               """)
    end

    test "an async module that clears a delivery cache" do
      assert [
               %{call: "KilnCMS.Cache.flush_delivery", key: "delivery caches"},
               %{call: "ClusterBust.broadcast_clear"},
               %{call: "KilnCMS.Firing.Cache.clear"},
               %{call: "Cache.clear"},
               %{call: "Cachex.clear"},
               %{call: "Cachex.clear"},
               %{call: "Cachex.clear"}
             ] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: true
                 test "t" do
                   KilnCMS.Cache.flush_delivery()
                   ClusterBust.broadcast_clear()
                   KilnCMS.Firing.Cache.clear()
                   Cache.clear()
                   Cachex.clear(KilnCMS.Cache.cache_name())
                   Cachex.clear(Firing.Cache.cache_name())
                   Cachex.clear(:kiln_cms_firing_cache)
                 end
               end
               """)
    end

    test "a piped Cachex.clear takes its cache from the pipe" do
      assert [%{call: "Cachex.clear"}, %{call: "Cachex.clear"}] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: true
                 test "t" do
                   KilnCMS.Cache.cache_name() |> Cachex.clear()
                   :kiln_cms_firing_cache |> Cachex.clear(some: :opt)
                 end
               end
               """)

      assert [] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: true
                 test "t", do: VectorCache.cache_name() |> Cachex.clear()
               end
               """)
    end

    test "Cachex.clear! counts as a clear" do
      assert [%{call: "Cachex.clear!"}, %{call: "Cachex.clear!"}] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: true
                 test "t" do
                   Cachex.clear!(KilnCMS.Cache.cache_name())
                   Cachex.clear!(:kiln_cms_content_cache, [])
                 end
               end
               """)
    end

    test "a Cachex.clear of a module attribute reads the attribute" do
      assert [%{call: "Cachex.clear"}, %{call: "Cachex.clear"}] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: true
                 @cache KilnCMS.Cache.cache_name()
                 @firing :kiln_cms_firing_cache
                 @vectors :kiln_cms_vector_cache
                 test "t" do
                   Cachex.clear(@cache)
                   Cachex.clear(@firing)
                   Cachex.clear(@vectors)
                 end
               end
               """)
    end

    test "another cache's clear, or a sync module's, is not a delivery-cache write" do
      assert [] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: true
                 test "t" do
                   Cachex.clear(VectorCache.cache_name())
                   Cachex.clear(PasswordNotice.cache())
                   KilnCMS.Cache.bust(:page, "slug")
                 end
               end
               """)

      assert [] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase, async: false
                 test "t", do: KilnCMS.Cache.flush_delivery()
               end
               """)
    end

    test "an async module that writes OS env" do
      assert [
               %{call: "System.put_env", app: "System", key: "KILN_X"},
               %{call: "System.delete_env", app: "System", key: "KILN_X"},
               %{call: "System.put_env", app: "System", key: "*"}
             ] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 test "t" do
                   System.put_env("KILN_X", "1")
                   on_exit(fn -> System.delete_env("KILN_X") end)
                   System.put_env(%{"KILN_Y" => "1"})
                 end
               end
               """)
    end

    test "a piped OS env write names its variable" do
      assert [
               %{call: "System.put_env", key: "KILN_X"},
               %{call: "System.delete_env", key: "KILN_X"},
               %{call: "System.put_env", key: "*"}
             ] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 test "t" do
                   "KILN_X" |> System.put_env("1")
                   "KILN_X" |> System.delete_env()
                   [{"KILN_Y", "1"}] |> System.put_env()
                 end
               end
               """)
    end

    test "an OS env name is read through a binding or an attribute" do
      assert [
               %{key: "KILN_TEST_DKIM_*"},
               %{key: "KILN_ATTR"},
               %{key: "name"}
             ] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 @var "KILN_ATTR"
                 test "t" do
                   var = "KILN_TEST_DKIM_\#{System.unique_integer()}"
                   System.put_env(var, "pem")
                   System.put_env(@var, "1")
                 end
                 defp put(name), do: System.delete_env(name)
               end
               """)
    end

    test "an OS env write of an unrecognized shape is still reported" do
      assert [%{call: "System.delete_env", app: "?", key: "?"}] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 test "t", do: Enum.each(["KILN_X"], &System.delete_env/1)
               end
               """)
    end

    test "an async module that calls a writing support helper" do
      support = """
      defmodule KilnCMS.Fix do
        def put!(v), do: Application.put_env(:kiln_cms, :k, v)
        def read, do: Application.get_env(:kiln_cms, :k)
      end
      """

      assert [%{call: "KilnCMS.Fix.put!", key: "via KilnCMS.Fix.put!"}] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: true
                   test "t" do
                     KilnCMS.Fix.put!(1)
                     KilnCMS.Fix.read()
                   end
                 end
                 """,
                 [support]
               )

      # An alias, with or without `as:`, a capture, and a pipe of any arity.
      assert [_, _, _, _] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: true
                   alias KilnCMS.Fix
                   alias KilnCMS.Fix, as: F
                   test "t" do
                     Fix.put!(1)
                     F.put!(1)
                     Enum.each([1], &F.put!/1)
                     1 |> F.put!()
                   end
                 end
                 """,
                 [support]
               )

      assert [] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: false
                   test "t", do: KilnCMS.Fix.put!(1)
                 end
                 """,
                 [support]
               )
    end

    test "an imported writing helper is matched to the module it came from" do
      support = """
      defmodule KilnCMS.Writes do
        def enable!, do: Application.put_env(:kiln_cms, :k, true)
      end

      defmodule KilnCMS.Reads do
        def enable!, do: :ok
        def other, do: :ok
      end
      """

      assert [%{call: "KilnCMS.Writes.enable!"}] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: true
                   import KilnCMS.Writes
                   test "t", do: enable!()
                 end
                 """,
                 [support]
               )

      assert [%{call: "KilnCMS.Writes.enable!"}] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: true
                   import KilnCMS.Writes, only: [enable!: 0]
                   test "t", do: :x |> enable!()
                 end
                 """,
                 [support]
               )

      # The same name imported from a module where it does not write, or
      # excluded from the writer's import.
      assert [] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: true
                   import KilnCMS.Reads
                   import KilnCMS.Writes, except: [enable!: 0]
                   test "t", do: enable!()
                 end
                 """,
                 [support]
               )

      assert [] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: true
                   import KilnCMS.Writes, only: [other: 0]
                   test "t", do: enable!()
                 end
                 """,
                 [support]
               )
    end

    test "a helper writes through another support module" do
      support = [
        """
        defmodule KilnCMS.Store do
          def put(k, v), do: :persistent_term.put({__MODULE__, k}, v)
        end
        """,
        """
        defmodule KilnCMS.Fixture do
          alias KilnCMS.Store, as: S
          def publish!(row), do: S.put(row, true)
        end
        """
      ]

      assert MapSet.new([{"KilnCMS.Store", :put}, {"KilnCMS.Fixture", :publish!}]) ==
               support_writers(support) |> MapSet.difference(library_writer_keys())
    end

    test "a helper writes through a capture" do
      support = """
      defmodule KilnCMS.Fixture do
        alias KilnCMS.Other
        def restore_on_exit, do: ExUnit.Callbacks.on_exit(&restore/0)
        def remote_on_exit, do: ExUnit.Callbacks.on_exit(&Other.restore/0)
        def restore, do: Application.put_env(:kiln_cms, :k, 1)
      end

      defmodule KilnCMS.Other do
        def restore, do: System.delete_env("KILN_X")
      end
      """

      found = support_writers([support])
      assert {"KilnCMS.Fixture", :restore_on_exit} in found
      assert {"KilnCMS.Fixture", :remote_on_exit} in found
    end

    test "a helper writes through a private function, which is not itself reported" do
      support = """
      defmodule KilnCMS.Fixture do
        def go!(v) do
          v |> prepare() |> store()
        end

        def harmless, do: prepare(1)

        defp prepare(v), do: v
        defp store(v), do: Cachex.clear!(KilnCMS.Cache.cache_name()) && v
      end
      """

      assert MapSet.new([{"KilnCMS.Fixture", :go!}]) ==
               support_writers([support]) |> MapSet.difference(library_writer_keys())
    end

    test "a safe writer, and a helper reaching a write only through it, do not count" do
      # As in the tree: the safe helper writes through another module.
      support = """
      defmodule KilnCMS.Store do
        def put(name), do: :persistent_term.put({__MODULE__, name}, true)
      end

      defmodule KilnCMS.Fixture do
        def publish!(name), do: KilnCMS.Store.put(name)
        def domain!(name), do: publish!(name)
        def domain_and_flag!(name), do: publish!(name) && Application.put_env(:kiln_cms, :k, 1)
      end
      """

      safe = MapSet.new([{"KilnCMS.Fixture", :publish!}])

      assert MapSet.new([{"KilnCMS.Store", :put}, {"KilnCMS.Fixture", :domain_and_flag!}]) ==
               [support] |> support_writers(safe) |> MapSet.difference(library_writer_keys())

      assert {"KilnCMS.Fixture", :domain!} in support_writers([support])
    end

    test "a module `use`d into an async test writes through its __using__" do
      support = """
      defmodule KilnCMS.SetsEnv do
        defmacro __using__(_opts) do
          quote do
            setup do: Application.put_env(:kiln_cms, :k, 1)
          end
        end
      end
      """

      assert [%{call: "KilnCMS.SetsEnv.__using__"}] =
               offenders_in(
                 """
                 defmodule A do
                   use ExUnit.Case, async: true
                   use KilnCMS.SetsEnv
                 end
                 """,
                 [support]
               )
    end

    test "an async module that runs an Igniter test project" do
      # Igniter applies the rewritten project's evaluated config with
      # `Application.put_all_env/1`, so even an empty config counts.
      assert [
               %{call: "Igniter.Test.test_project"},
               %{call: "Igniter.compose_task"},
               %{call: "Igniter.Test.apply_igniter!"}
             ] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 import Igniter.Test
                 test "t" do
                   test_project(files: %{"config/config.exs" => "import Config\\n"})
                   |> Igniter.compose_task("kiln.gen.content", ["Product"])
                   |> apply_igniter!()
                 end
               end
               """)

      assert [%{call: "Igniter.Test.phx_test_project"}] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 alias Igniter.Test, as: T
                 test "t", do: T.phx_test_project()
               end
               """)

      assert [] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: false
                 import Igniter.Test
                 test "t", do: test_project() |> Igniter.compose_task("x", [])
               end
               """)
    end

    test "the rule decides per module, not per file" do
      assert [] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 test "reads only", do: Application.get_env(:kiln_cms, :k)

                 defmodule Writes do
                   use ExUnit.Case, async: false
                   test "t", do: Application.put_env(:kiln_cms, :k, 1)
                 end
               end
               """)

      assert [] =
               offenders_in("""
               defmodule A do
                 use KilnCMS.DataCase
                 test "t", do: Application.put_env(:kiln_cms, :k, 1)
               end
               """)
    end

    test "an allowlist entry covers its own key and nothing else" do
      source = fn key ->
        """
        defmodule KilnCMS.Collab.CrdtTest do
          use ExUnit.Case, async: true
          test "t", do: Application.put_env(:kiln_cms, #{key}, 1)
        end
        """
      end

      assert [_] = offenders_in(source.(":collab_max_documents"))
      assert [] = source.(":collab_max_documents") |> offenders_in() |> Enum.reject(&allowed?/1)
      assert [_] = source.(":other_key") |> offenders_in() |> Enum.reject(&allowed?/1)
    end

    test "the #1067 flag is refused even for an allowlisted module" do
      write = %{module: "Kiln.PluginsTest", app: ":kiln_cms", key: ":collab_prototype"}

      refute allowed?(write)
      refute Enum.any?(Map.keys(@allowed), fn {_module, _app, key} -> key == @never_allowed end)
    end

    test "an allowlist entry is for its own app" do
      assert [write] =
               offenders_in("""
               defmodule KilnCMS.Collab.CrdtTest do
                 use ExUnit.Case, async: true
                 test "t", do: Application.put_env(:other_app, :collab_max_documents, 1)
               end
               """)

      refute allowed?(write)
    end

    test "a piped write names its app and key" do
      assert [
               %{call: "Application.put_env", app: ":kiln_cms", key: ":k"},
               %{call: "Application.delete_env", app: ":kiln_cms", key: ":k"}
             ] =
               offenders_in("""
               defmodule A do
                 use ExUnit.Case, async: true
                 test "t" do
                   :kiln_cms |> Application.put_env(:k, 1)
                   :kiln_cms |> Application.delete_env(:k)
                 end
               end
               """)
    end
  end

  defp allowed?(%{key: @never_allowed}), do: false

  defp allowed?(%{module: module, app: app, key: key}),
    do: Map.has_key?(@allowed, {module, app, key})

  defp safe_writer_keys, do: @safe_writers |> Map.keys() |> MapSet.new()

  defp describe(%{file: file, line: line, module: module, call: call, key: key}),
    do: "  - #{file}:#{line} #{module}: #{call}(… #{key} …)"

  # `support` is the source of each fixture `test/support` file the module
  # may call into.
  defp offenders_in(source, support \\ []) do
    source |> Code.string_to_quoted!() |> writes("fixture.exs", support_writers(support))
  end

  defp writes_in_async_modules(path, writers) do
    path |> File.read!() |> Code.string_to_quoted!(file: path) |> writes(path, writers)
  end

  # Every write made in an async module of `ast`, each module judged by its own
  # `use` line (or, for a module that is not a test case, the module around it).
  defp writes(ast, file, writers),
    do: walk(ast, %{file: file, outer: nil, async?: false, env: @empty_env, writers: writers})

  defp walk({:defmodule, _, [name, [do: body]]}, ctx) do
    module = module_name(name, ctx.outer)
    own = without_nested_modules(body)
    async? = async?(own, ctx.async?)
    env = module_env(own, module, ctx.env)

    found =
      if async? do
        (calls(own, env.attrs) ++ helper_calls(own, env, ctx.writers))
        |> Enum.sort_by(& &1.line)
        |> Enum.map(&Map.merge(&1, %{file: ctx.file, module: module}))
      else
        []
      end

    nested = %{ctx | outer: module, async?: async?, env: env}
    found ++ Enum.flat_map(nested_modules(body), &walk(&1, nested))
  end

  # A `defmodule` of another shape (built in a quote, say) is not a test module.
  defp walk({:defmodule, _, _}, _ctx), do: []

  defp walk(ast, ctx), do: ast |> nested_modules() |> Enum.flat_map(&walk(&1, ctx))

  defp module_name(name, nil), do: Macro.to_string(name)
  defp module_name(name, outer), do: outer <> "." <> Macro.to_string(name)

  # A test case module is async when its `use …Case` says so (ExUnit's own
  # default is false). Anything else inherits the module it is defined in.
  defp async?(body, outer_async?) do
    case case_opts(body) do
      nil -> outer_async?
      opts -> Keyword.get(opts, :async, false) != false
    end
  end

  defp case_opts(body) do
    {_, found} =
      Macro.prewalk(body, nil, fn
        {:use, _, [{:__aliases__, _, parts} | rest]} = node, nil ->
          if parts |> List.last() |> Atom.to_string() |> String.ends_with?("Case") do
            {node, opts(rest)}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp opts([opts]) when is_list(opts), do: opts
  defp opts(_), do: []

  defp without_nested_modules(body) do
    Macro.prewalk(body, fn
      {:defmodule, _, _} -> nil
      node -> node
    end)
  end

  defp nested_modules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, _} = node, acc -> {nil, [node | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(found)
  end

  ## Direct writes

  @app_writes [:put_env, :delete_env, :put_all_env]
  @system_writes [:put_env, :delete_env]
  @cachex_clears [:clear, :clear!]
  @delivery_caches "delivery caches"
  @term_writes [:put, :erase]

  # The direct writes in `ast`. `attrs` are the module's attributes, so a write
  # through `@var` reads the attribute. Variable bindings are tracked as the
  # walk meets them, so an OS env name bound just above its write is read
  # through the variable (the nearest earlier binding in source order).
  defp calls(ast, attrs) do
    {_, {found, _bindings}} =
      Macro.prewalk(ast, {[], %{}}, fn
        {:=, _, [{var, _, context}, rhs]} = node, {acc, bindings}
        when is_atom(var) and is_atom(context) ->
          {node, {acc, Map.put(bindings, var, rhs)}}

        # `app |> Application.put_env(key, value)`: the app is the pipe's left
        # side. Recorded here and replaced by its operands, so the call inside
        # is not read again with the key in the app's place. The same for
        # `System` and `Cachex`.
        {:|>, _, [lhs, {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, args}]},
        {acc, bindings}
        when fun in @app_writes ->
          write = write(meta, "Application.#{fun}", app_key(fun, [lhs | args]))
          {{:__block__, [], [lhs | args]}, {[write | acc], bindings}}

        {:|>, _, [lhs, {{:., _, [{:__aliases__, _, [:System]}, fun]}, meta, args}]},
        {acc, bindings}
        when fun in @system_writes ->
          write = write(meta, "System.#{fun}", system_key(fun, [lhs | args], attrs, bindings))
          {{:__block__, [], [lhs | args]}, {[write | acc], bindings}}

        {:|>, _, [lhs, {{:., _, [{:__aliases__, _, [:Cachex]}, fun]}, meta, args}]},
        {acc, bindings}
        when fun in @cachex_clears ->
          acc =
            if delivery_cache?(lhs, attrs),
              do: [write(meta, "Cachex.#{fun}", {nil, @delivery_caches}) | acc],
              else: acc

          {{:__block__, [], [lhs | args]}, {acc, bindings}}

        {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, args} = node, {acc, bindings}
        when fun in @app_writes ->
          {node, {[write(meta, "Application.#{fun}", app_key(fun, args)) | acc], bindings}}

        {{:., _, [{:__aliases__, _, [:System]}, fun]}, meta, args} = node, {acc, bindings}
        when fun in @system_writes ->
          write = write(meta, "System.#{fun}", system_key(fun, args, attrs, bindings))
          {node, {[write | acc], bindings}}

        {{:., _, [:persistent_term, fun]}, meta, [key | _]} = node, {acc, bindings}
        when fun in @term_writes ->
          write = write(meta, ":persistent_term.#{fun}", {nil, Macro.to_string(key)})
          {node, {[write | acc], bindings}}

        {{:., _, [{:__aliases__, _, parts}, fun]}, meta, args} = node, {acc, bindings} ->
          case cache_clear(parts, fun, args, attrs) do
            nil -> {node, {acc, bindings}}
            call -> {node, {[write(meta, call, {nil, @delivery_caches}) | acc], bindings}}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp app_key(:put_all_env, _args), do: {nil, "*"}
  defp app_key(_fun, [app, key | _]), do: {Macro.to_string(app), Macro.to_string(key)}
  # A shape not recognized (an apply, a variable arg list) is still reported.
  defp app_key(_fun, _args), do: {"?", "?"}

  # `System.put_env/1` takes a whole enumerable of names.
  defp system_key(:put_env, [_enumerable], _attrs, _bindings), do: {"System", "*"}

  defp system_key(_fun, [name | _], attrs, bindings),
    do: {"System", env_name(name, attrs, bindings, 3)}

  # A capture (`&System.delete_env/1`) has no arguments to read.
  defp system_key(_fun, _args, _attrs, _bindings), do: {"?", "?"}

  # The variable's name as far as the source says it: a literal, the literal
  # prefix of an interpolation plus `*`, or else the expression itself.
  defp env_name(name, _attrs, _bindings, _depth) when is_binary(name), do: name

  defp env_name({:<<>>, _, parts}, _attrs, _bindings, _depth),
    do: (parts |> Enum.take_while(&is_binary/1) |> Enum.join()) <> "*"

  defp env_name({:@, _, [{attr, _, context}]} = name, attrs, bindings, depth)
       when is_atom(context) and depth > 0 do
    case Map.fetch(attrs, attr) do
      {:ok, value} -> env_name(value, attrs, bindings, depth - 1)
      :error -> Macro.to_string(name)
    end
  end

  defp env_name({var, _, context} = name, attrs, bindings, depth)
       when is_atom(var) and is_atom(context) and depth > 0 do
    case Map.fetch(bindings, var) do
      {:ok, value} -> env_name(value, attrs, bindings, depth - 1)
      :error -> Macro.to_string(name)
    end
  end

  defp env_name(name, _attrs, _bindings, _depth), do: Macro.to_string(name)

  defp write(meta, call, {app, key}), do: %{line: meta[:line], call: call, app: app, key: key}

  # The delivery caches' clears, recognized by the module's last alias segment
  # so an aliased call (`Cache.clear()` after `alias KilnCMS.Firing.Cache`)
  # counts. `KilnCMS.Cache` has no `clear/0`, so `Cache.clear` is the firing
  # cache's. `Cachex.clear/1,2` and `clear!/1,2` only when their cache is one
  # of the two.
  @delivery_cache_name ~r/(^|\.)Cache\.cache_name\(\)$|^:kiln_cms_(content|firing)_cache$/

  defp cache_clear(parts, :flush_delivery, _args, _attrs) when parts != [],
    do: if(List.last(parts) == :Cache, do: "#{alias_name(parts)}.flush_delivery")

  defp cache_clear(parts, :broadcast_clear, _args, _attrs) when parts != [],
    do: if(List.last(parts) == :ClusterBust, do: "#{alias_name(parts)}.broadcast_clear")

  defp cache_clear(parts, :clear, [], _attrs) when parts != [],
    do: if(List.last(parts) == :Cache, do: "#{alias_name(parts)}.clear")

  defp cache_clear([:Cachex], fun, [cache | _], attrs) when fun in @cachex_clears,
    do: if(delivery_cache?(cache, attrs), do: "Cachex.#{fun}")

  defp cache_clear(_parts, _fun, _args, _attrs), do: nil

  defp delivery_cache?({:@, _, [{attr, _, context}]} = cache, attrs) when is_atom(context),
    do: attrs |> Map.get(attr, cache) |> Macro.to_string() =~ @delivery_cache_name

  defp delivery_cache?(cache, _attrs), do: Macro.to_string(cache) =~ @delivery_cache_name

  defp alias_name(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  ## Writes made on the module's behalf

  # Library functions that write global state when called. Igniter evaluates
  # the rewritten project's config and applies it with `put_all_env`.
  @library_writes [
    {"Igniter.Test", :test_project},
    {"Igniter.Test", :phx_test_project},
    {"Igniter.Test", :apply_igniter},
    {"Igniter.Test", :apply_igniter!},
    {"Igniter", :compose_task}
  ]

  defp library_writer_keys, do: MapSet.new(@library_writes)

  defp helper_calls(ast, env, writers) do
    for {module, fun, meta} <- call_targets(ast, env), {module, fun} in writers do
      write(meta, "#{module}.#{fun}", {nil, "via #{module}.#{fun}"})
    end
  end

  # Aliases and imports carry into a nested module, as they do lexically.
  defp module_env(body, module, outer) do
    start = %{outer | module: module, attrs: %{}, locals: MapSet.new()}

    {_, env} =
      Macro.prewalk(body, start, fn
        {:alias, _, [target | rest]} = node, env ->
          {node, %{env | aliases: Map.merge(env.aliases, aliases(target, opts(rest), env))}}

        {:import, _, [{:__aliases__, _, parts} | rest]} = node, env ->
          opts = opts(rest)
          import = {resolve(parts, env), names(opts[:only]), names(opts[:except]) || []}
          {node, %{env | imports: [import | env.imports]}}

        {:@, _, [{attr, _, [value]}]} = node, env when is_atom(attr) ->
          {node, %{env | attrs: Map.put(env.attrs, attr, value)}}

        {kind, _, [head | _]} = node, env when kind in [:def, :defp, :defmacro, :defmacrop] ->
          case def_name(head) do
            nil -> {node, env}
            name -> {node, %{env | locals: MapSet.put(env.locals, name)}}
          end

        node, env ->
          {node, env}
      end)

    env
  end

  defp aliases({:__aliases__, _, parts}, opts, env) do
    as =
      case opts[:as] do
        {:__aliases__, _, [as]} -> as
        _ -> List.last(parts)
      end

    %{as => resolve(parts, env)}
  end

  # `alias KilnCMS.{A, B}`
  defp aliases({{:., _, [{:__aliases__, _, base}, :{}]}, _, children}, _opts, env) do
    for {:__aliases__, _, parts} <- children, into: %{} do
      {List.last(parts), resolve(base ++ parts, env)}
    end
  end

  defp aliases(_target, _opts, _env), do: %{}

  # `only:`/`except:` as a list of names (arity is not kept: a name imported
  # at any arity counts). `nil` when absent; `:functions` and the like mean all.
  defp names(list) when is_list(list), do: Keyword.keys(list)
  defp names(_), do: nil

  defp resolve([{:__MODULE__, _, _} | rest], env),
    do: Enum.join([env.module | Enum.map(rest, &Atom.to_string/1)], ".")

  defp resolve([first | rest] = parts, env) when is_atom(first) do
    case Map.fetch(env.aliases, first) do
      {:ok, full} -> Enum.join([full | Enum.map(rest, &Atom.to_string/1)], ".")
      :error -> alias_name(parts)
    end
  end

  defp resolve(parts, _env), do: Macro.to_string({:__aliases__, [], parts})

  defp def_name({:when, _, [call | _]}), do: def_name(call)
  defp def_name({name, _, args}) when is_atom(name) and (is_list(args) or is_atom(args)), do: name
  defp def_name(_), do: nil

  # Every `{module, function, meta}` that `ast` calls, captures or `use`s, by
  # name and whatever the arity. A bare call is the module's own function when
  # it defines one by that name, else whichever import provides that name.
  defp call_targets(ast, env) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:use, meta, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [{resolve(parts, env), :__using__, meta} | acc]}

        {:&, _, [{:/, _, [{fun, meta, context}, arity]}]} = node, acc
        when is_atom(fun) and is_atom(context) and is_integer(arity) ->
          {node, bare_targets(fun, meta, env) ++ acc}

        {{:., _, [{:__aliases__, _, parts}, fun]}, meta, _args} = node, acc when is_atom(fun) ->
          {node, [{resolve(parts, env), fun, meta} | acc]}

        {{:., _, [{:__MODULE__, _, _}, fun]}, meta, _args} = node, acc when is_atom(fun) ->
          {node, [{env.module, fun, meta} | acc]}

        {fun, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, bare_targets(fun, meta, env) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp bare_targets(fun, meta, env) do
    if fun in env.locals do
      [{env.module, fun, meta}]
    else
      for {module, only, except} <- env.imports,
          only == nil or fun in only,
          fun not in except,
          do: {module, fun, meta}
    end
  end

  ## The support writers

  defp support_sources do
    for path <- Path.wildcard("test/support/**/*.ex"), do: {path, File.read!(path)}
  end

  # Every public `{module, function}` in `sources` that writes global state,
  # directly or through any chain of support functions it calls or captures,
  # plus the library writers. A `safe` function is taken not to write, so
  # neither are the ones that reach a write only through it.
  defp support_writers(sources, safe \\ MapSet.new()) do
    graph =
      sources
      |> Enum.flat_map(fn
        {path, source} -> source |> Code.string_to_quoted!(file: path) |> functions(@empty_env)
        source -> source |> Code.string_to_quoted!() |> functions(@empty_env)
      end)
      |> Enum.reduce(%{}, fn {key, function}, graph ->
        Map.update(graph, key, function, &merge_clauses(&1, function))
      end)

    seeds =
      for {key, %{direct?: true}} <- graph, key not in safe, into: library_writer_keys(), do: key

    writers = close(seeds, Map.drop(graph, Enum.to_list(safe)))

    for {key, %{public?: true}} <- graph, key in writers, into: library_writer_keys(), do: key
  end

  defp merge_clauses(a, b) do
    %{
      public?: a.public? or b.public?,
      direct?: a.direct? or b.direct?,
      targets: MapSet.union(a.targets, b.targets)
    }
  end

  defp close(writers, graph) do
    more =
      for {key, function} <- graph,
          key not in writers,
          Enum.any?(function.targets, &(&1 in writers)),
          into: writers,
          do: key

    if MapSet.size(more) == MapSet.size(writers), do: writers, else: close(more, graph)
  end

  defp functions({:defmodule, _, [module_alias, [do: body]]}, outer) do
    module = module_name(module_alias, outer.module)
    own = without_nested_modules(body)
    env = module_env(own, module, outer)

    own_functions =
      for {kind, _, [head | rest]} <- definitions(own),
          name when name != nil <- [def_name(head)] do
        {{module, name},
         %{
           public?: kind in [:def, :defmacro],
           direct?: calls(rest, env.attrs) != [],
           targets: rest |> call_targets(env) |> MapSet.new(fn {m, f, _meta} -> {m, f} end)
         }}
      end

    own_functions ++ Enum.flat_map(nested_modules(body), &functions(&1, env))
  end

  defp functions({:defmodule, _, _}, _outer), do: []

  defp functions(ast, outer),
    do: ast |> nested_modules() |> Enum.flat_map(&functions(&1, outer))

  defp definitions(body) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {kind, _, [_ | _]} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          {nil, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end
end
