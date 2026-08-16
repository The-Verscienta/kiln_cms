defmodule KilnCMS.CacheIsolationTest do
  @moduledoc """
  The per-test isolation of the shared content cache
  (`KilnCMS.DataCase.bust_default_org_aggregates/0`).

  `KilnCMS.Cache` is a process-global Cachex that lives outside the SQL sandbox
  and holds entries for minutes, so a value one test resolved from rows that
  were then rolled back stays readable by the tests that follow. For the keys
  whose entire identity is the org id, and for the **one** org whose id is fixed
  for the whole run, that is a single global slot the entire suite shares — the
  shape behind two confirmed load-flaky failures (#1289).

  `async: false`, and not incidentally: these tests deliberately write poison
  into the default org's cache slots, which is precisely the thing that breaks
  other tests. A sync module has the VM to itself.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Cache
  alias KilnCMS.DataCase

  @poison {:poisoned_by, __MODULE__}

  defp poison(keys) do
    for {_name, key} <- keys, do: Cachex.put(Cache.cache_name(), key, @poison)
    keys
  end

  defp cached(key), do: Cachex.get(Cache.cache_name(), key)

  describe "the covered key set" do
    test "reaches every aggregate key the incident named, by its real name" do
      covered =
        Accounts.default_org_id() |> DataCase.org_aggregate_keys() |> Enum.map(&elem(&1, 0))

      # Named individually rather than counted: a count pins nothing useful (it
      # moves whenever a key is added) while a rename of any one of these would
      # drop it out of the reflected set and silently un-fix it. These are the
      # keys the issue asked about by name, plus the one it was reported for.
      for name <- [
            :branding_key,
            :code_injection_key,
            :feed_policy_key,
            :experiments_key,
            :head_generation_key,
            :sitemap_key
          ] do
        assert name in covered,
               "KilnCMS.Cache.#{name}/1 is no longer reached by the per-test cache reset — " <>
                 "a value resolved for the default org under it now outlives the test that " <>
                 "wrote it"
      end
    end

    test "excludes feed_key/3, which is not a bare per-org aggregate" do
      covered =
        Accounts.default_org_id() |> DataCase.org_aggregate_keys() |> Enum.map(&elem(&1, 0))

      refute :feed_key in covered
    end
  end

  describe "bust_default_org_aggregates/0" do
    test "drops a poisoned value under every key it covers" do
      keys = Accounts.default_org_id() |> DataCase.org_aggregate_keys() |> poison()

      # The premise, checked rather than assumed: poisoning has to have worked,
      # or the assertion below passes without the reset doing anything.
      for {name, key} <- keys do
        assert {:ok, @poison} = cached(key), "could not poison #{name} — this test proves nothing"
      end

      DataCase.bust_default_org_aggregates()

      for {name, key} <- keys do
        assert {:ok, nil} = cached(key),
               "KilnCMS.Cache.#{name}/1 survived the per-test reset for the default org"
      end
    end

    test "leaves another org's identically-shaped keys alone" do
      other = Ash.UUID.generate()
      keys = other |> DataCase.org_aggregate_keys() |> poison()

      DataCase.bust_default_org_aggregates()

      # Scoping is the reason this is a targeted delete and not `Cachex.clear/1`:
      # every other org in the suite is seeded per test with a fresh id, so its
      # entries can never be read by a later test — while clearing wholesale
      # would reach into concurrently running async tests and drop entries they
      # are still asserting on.
      for {name, key} <- keys do
        assert {:ok, @poison} = cached(key), "the reset reached beyond the default org (#{name})"
      end
    end
  end
end

defmodule KilnCMS.CacheIsolationEntryTest do
  @moduledoc """
  That the reset is actually *wired into* `setup_sandbox/1`, rather than merely
  being a correct function nobody calls.

  The poison is written in `setup_all`, which runs before the per-test `setup`
  the case template installs — so it stands in for exactly what this defends
  against: an entry already in the cache, from a transaction that is already
  gone, when the test begins. A newly written test inherits that protection
  without doing anything, which is the whole point; note that this module
  carries no `bust_branding/1` call of its own.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Branding
  alias KilnCMS.Cache

  @poisoned_name "Poisoned Co #{System.unique_integer([:positive])}"

  setup_all do
    Cachex.put(
      Cache.cache_name(),
      Cache.branding_key(Accounts.default_org_id()),
      %Branding{site_name: @poisoned_name}
    )

    :ok
  end

  test "branding cached for the default org before the test began is not visible in it" do
    assert {:ok, nil} =
             Cachex.get(Cache.cache_name(), Cache.branding_key(Accounts.default_org_id()))

    # And end-to-end, through the resolver the delivery layout actually calls.
    # Asserted as a `!=` against the sentinel rather than as `== "KilnCMS"`,
    # so this pins the leak and not the (app-env-driven) operator default
    # layer, which is a separate piece of global state with its own discipline.
    refute Branding.for_org(nil).site_name == @poisoned_name
    refute Branding.for_org(Accounts.default_org_id()).site_name == @poisoned_name
  end
end
