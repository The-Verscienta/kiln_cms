defmodule KilnCMS.AsyncGlobalStateTest do
  @moduledoc """
  No `async: true` test module may write VM-global state that another test
  reads: `Application.put_env/delete_env/put_all_env` or `:persistent_term`
  (#1067, #2380).

  Application env and persistent terms are shared by every process in the VM.
  An `async: true` module that writes one changes it for every other async
  module running at the same moment, and its `on_exit` puts it back before
  anyone notices. Restoring the value afterwards does not help; the damage is
  done while the test runs.

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
  `KilnCMS.Firing.Cache.clear/0`, or a `Cachex.clear/1` of `KilnCMS.Cache` or
  `KilnCMS.Firing.Cache`, empties them under every async test that warmed an
  entry and is about to read it back (`KilnCMS.Firing.DeliveryTest`'s warm
  reads came back `:unavailable` in a full run). Those calls count as writes
  too. Only the direct calls: a helper that clears on a test's behalf
  (`KilnCMS.Demo.restore/1`, the System page's flush button) is not seen.

  So the rule is checked instead of remembered. `async: false` costs almost
  nothing: ExUnit runs sync modules after the async ones, so the time moves
  phase rather than adding up.

  The check is per module, not per file: a file may hold an `async: true`
  module and a nested `async: false` one that does the writing. A module that
  is not a test case (a fixture module defined inside a test) counts as the
  module around it, since that is where its code runs.

  A static read of the test files, deliberately: the failure this prevents is
  two modules running *concurrently*, which a runtime check cannot observe
  without being the very race it is looking for. It sees direct calls only;
  writes made inside `test/support` helpers or by a library are not covered.
  """
  use ExUnit.Case, async: true

  # Modules that may write while async, by `{module, app, key}`. Each is a key
  # no code reached from another async test reads, so a concurrent test cannot
  # see the change. A key, not a module, so the next write in the same module
  # is checked again; the app too, so `:plugins` under another app is not
  # covered. `:collab_prototype` can never be listed (#1067).
  @allowed %{
    {"Kiln.PluginsTest", ":kiln_cms", ":plugins"} =>
      "read at runtime only by `mix kiln.plugins.doctor`, which no other async test runs; " <>
        "`Kiln.Plugins` reads it with compile_env",
    {"KilnCMS.Collab.CrdtTest", ":kiln_cms", ":collab_max_documents"} =>
      "read once at boot to size the document supervisor, and in a log line no test reaches",
    {"KilnCMS.Governance.Witness.HTTPTest", ":kiln_cms", "HTTP"} =>
      "read only when the witness adapter is HTTP, which only async: false tests select",
    {"Mix.Tasks.Kiln.Gen.ContentTest", ":test", ":ash_domains"} =>
      "the `:test` app is Igniter's fixture project; its other readers are async: false"
  }

  @never_allowed ":collab_prototype"

  test "no async: true module writes VM-global state" do
    offenders =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.flat_map(&writes_in_async_modules/1)
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
           in #{Path.relative_to_cwd(__ENV__.file)} with the reason.
           """
  end

  test "every allowlist entry still names a write" do
    found =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.flat_map(&writes_in_async_modules/1)
      |> MapSet.new(&{&1.module, &1.app, &1.key})

    stale = @allowed |> Map.keys() |> Enum.reject(&(&1 in found))

    assert stale == [],
           "Allowlisted writes no longer found, so drop them from @allowed: #{inspect(stale)}"
  end

  describe "the check can fail" do
    # Otherwise a change to how async-ness or a write is recognised would leave
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

  defp describe(%{file: file, line: line, module: module, call: call, key: key}),
    do: "  - #{file}:#{line} #{module}: #{call}(… #{key} …)"

  defp offenders_in(source) do
    source |> Code.string_to_quoted!() |> writes("fixture.exs")
  end

  defp writes_in_async_modules(path) do
    path |> File.read!() |> Code.string_to_quoted!(file: path) |> writes(path)
  end

  # Every write made in an async module of `ast`, each module judged by its own
  # `use` line (or, for a module that is not a test case, the module around it).
  defp writes(ast, file), do: walk(ast, file, nil, false)

  defp walk({:defmodule, _, [name, [do: body]]}, file, outer, outer_async?) do
    module = module_name(name, outer)
    async? = async?(body, outer_async?)

    own =
      if async? do
        body
        |> without_nested_modules()
        |> calls()
        |> Enum.map(&Map.merge(&1, %{file: file, module: module}))
      else
        []
      end

    own ++ Enum.flat_map(nested_modules(body), &walk(&1, file, module, async?))
  end

  # A `defmodule` of another shape (built in a quote, say) is not a test module.
  defp walk({:defmodule, _, _}, _file, _outer, _outer_async?), do: []

  defp walk(ast, file, outer, outer_async?) do
    ast |> nested_modules() |> Enum.flat_map(&walk(&1, file, outer, outer_async?))
  end

  defp module_name(name, nil), do: Macro.to_string(name)
  defp module_name(name, outer), do: outer <> "." <> Macro.to_string(name)

  # A test case module is async when its `use …Case` says so (ExUnit's own
  # default is false). Anything else inherits the module it is defined in.
  defp async?(body, outer_async?) do
    case body |> without_nested_modules() |> case_opts() do
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

  @app_writes [:put_env, :delete_env, :put_all_env]
  @delivery_caches "delivery caches"
  @term_writes [:put, :erase]

  defp calls(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        # `app |> Application.put_env(key, value)`: the app is the pipe's left
        # side. Recorded here and replaced by its operands, so the call inside
        # is not read again with the key in the app's place.
        {:|>, _, [lhs, {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, args}]}, acc
        when fun in @app_writes ->
          {{:__block__, [], [lhs | args]},
           [write(meta, "Application.#{fun}", app_key(fun, [lhs | args])) | acc]}

        {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, args} = node, acc
        when fun in @app_writes ->
          {node, [write(meta, "Application.#{fun}", app_key(fun, args)) | acc]}

        {{:., _, [:persistent_term, fun]}, meta, [key | _]} = node, acc
        when fun in @term_writes ->
          {node, [write(meta, ":persistent_term.#{fun}", {nil, Macro.to_string(key)}) | acc]}

        {{:., _, [{:__aliases__, _, parts}, fun]}, meta, args} = node, acc ->
          case cache_clear(parts, fun, args) do
            nil -> {node, acc}
            call -> {node, [write(meta, call, {nil, @delivery_caches}) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp app_key(:put_all_env, _args), do: {nil, "*"}
  defp app_key(_fun, [app, key | _]), do: {Macro.to_string(app), Macro.to_string(key)}
  # A shape not recognised (an apply, a variable arg list) is still reported.
  defp app_key(_fun, _args), do: {"?", "?"}

  defp write(meta, call, {app, key}), do: %{line: meta[:line], call: call, app: app, key: key}

  # The delivery caches' clears, recognized by the module's last alias segment
  # so an aliased call (`Cache.clear()` after `alias KilnCMS.Firing.Cache`)
  # counts. `KilnCMS.Cache` has no `clear/0`, so `Cache.clear` is the firing
  # cache's. `Cachex.clear/1` only when its cache is one of the two.
  @delivery_cache_name ~r/(^|\.)Cache\.cache_name\(\)$|^:kiln_cms_(content|firing)_cache$/

  defp cache_clear(parts, :flush_delivery, _args) when parts != [],
    do: if(List.last(parts) == :Cache, do: "#{alias_name(parts)}.flush_delivery")

  defp cache_clear(parts, :broadcast_clear, _args) when parts != [],
    do: if(List.last(parts) == :ClusterBust, do: "#{alias_name(parts)}.broadcast_clear")

  defp cache_clear(parts, :clear, []) when parts != [],
    do: if(List.last(parts) == :Cache, do: "#{alias_name(parts)}.clear")

  defp cache_clear([:Cachex], :clear, [cache | _]) do
    if Macro.to_string(cache) =~ @delivery_cache_name, do: "Cachex.clear"
  end

  defp cache_clear(_parts, _fun, _args), do: nil

  defp alias_name(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)
end
