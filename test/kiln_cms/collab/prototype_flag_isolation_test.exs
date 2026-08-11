defmodule KilnCMS.Collab.PrototypeFlagIsolationTest do
  @moduledoc """
  No `async: true` test module may write `:collab_prototype` (#1067).

  `KilnCMS.Collab.Crdt.enabled?/0` reads
  `Application.get_env(:kiln_cms, :collab_prototype)` — **VM-global**, and
  re-read on every editor mount. `config/test.exs` sets it true at boot. A test
  that flips it off turns collaboration off for every *other* test mounting an
  editor at the same moment, and puts it back before anyone notices.

  What that costs is the reason this file exists rather than a comment. It
  presents as a timing bug and is not one: fails only under load, passes in
  isolation, moves between tests in the same file with the seed. #1067 was filed
  as a presence race — with a suggested fix to the wrong three lines — and the
  real cause (`KilnCMSWeb.CollabSavedRefreshTest` being `async: true`) took a
  separate investigation to find.

  So the rule is checked instead of remembered. `async: false` costs almost
  nothing here — ExUnit runs sync modules after the async ones, so the time
  moves phase rather than adding up.

  A static read of the test files, deliberately: the failure this prevents is
  two modules running *concurrently*, which a runtime check cannot observe
  without being the very race it is looking for.
  """
  use ExUnit.Case, async: true

  @flag ":collab_prototype"

  # This file names both the flag and `put_env`, in the check itself and in the
  # message it prints, so it matches its own rule.
  @self Path.relative_to_cwd(__ENV__.file)

  test "every test that writes :collab_prototype is in an async: false module" do
    offenders =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @self))
      |> Enum.filter(&(writes_flag?(&1) and async?(&1)))

    assert offenders == [],
           """
           These test modules write #{@flag} and run with `async: true`:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           The flag is VM-global and every editor mount re-reads it, so for as
           long as one of these runs, collaboration is off for every concurrent
           test that mounts an editor — and back on before the failure can be
           traced to it. Add `async: false` to the module's `use` line, as
           KilnCMSWeb.CollabSavedRefreshTest and KilnCMSWeb.CollabChannelTest
           have (#1067).
           """
  end

  test "the check can fail" do
    # Otherwise a rename of the flag, or a `put_env` written another way, would
    # leave this passing forever — which is how the original leak survived.
    assert writes_flag?("test/kiln_cms_web/live/collab_saved_refresh_test.exs")
    assert async?(@self)
    # And the exclusion is one file, not a pattern that could grow to cover a
    # real offender.
    assert @self == "test/kiln_cms/collab/prototype_flag_isolation_test.exs"
  end

  defp writes_flag?(path) do
    source = File.read!(path)

    String.contains?(source, "put_env") and String.contains?(source, @flag)
  end

  # `async: true` on the `use` line. `ExUnit.Case`'s own default is `false`, and
  # a module that says nothing is therefore already safe.
  defp async?(path) do
    path |> File.read!() |> String.contains?("async: true")
  end
end
