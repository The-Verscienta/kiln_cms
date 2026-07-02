defmodule KilnCMS.ApplicationTest do
  @moduledoc """
  Smoke test that the supervision tree boots with the DoS-hardening config — the
  bounded `KilnCMS.Cache` child and the self-cleaning `KilnCMSWeb.RateLimit`
  child. A malformed child spec or option here would fail application start, so
  the suite booting at all already exercises these; the explicit assertions
  document the contract.
  """
  # async: false — the cache round-trip below races concurrent media-write
  # tests, whose BustMediaCache change clears the entire shared content cache
  # (Cache.bust_published/0) between this test's put and get.
  use ExUnit.Case, async: false

  alias KilnCMS.Cache

  test "the top-level supervisor is running" do
    assert is_pid(Process.whereis(KilnCMS.Supervisor))
  end

  test "the bounded content cache is started and operational" do
    # The cache is supervised via `KilnCMS.Cache.child_spec/1`, which adds the
    # LRW size-limit hook. If that spec failed to start, the named process would
    # be absent and this round-trip would raise.
    assert is_pid(Process.whereis(Cache.cache_name()))

    key = "boot-smoke-#{System.unique_integer([:positive])}"
    assert {:ok, true} = Cachex.put(Cache.cache_name(), key, :ok)
    assert {:ok, :ok} = Cachex.get(Cache.cache_name(), key)
  end

  test "the self-cleaning rate limiter is started and operational" do
    # Started with `clean_period`/`key_older_than` opts; a bad option would crash
    # the child on boot. The Hammer ETS backend names its bucket *table* (the
    # owning GenServer is anonymous), so assert the table exists and a check
    # returning `:allow` proves the backend is up.
    assert :ets.whereis(KilnCMSWeb.RateLimit) != :undefined
    assert :allow = KilnCMSWeb.RateLimit.check(:api, "203.0.113.#{:rand.uniform(254)}")
  end
end
