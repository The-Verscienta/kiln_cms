defmodule KilnCMS.Firing.CacheTest do
  @moduledoc false
  # async: false — exercises a named, app-wide Cachex instance.
  use ExUnit.Case, async: false

  alias KilnCMS.Firing.Cache

  setup_all do
    # Start the named Cachex instance once if the application isn't already
    # supervising it (isolated unit run vs. full `mix test`).
    unless Process.whereis(Cache.cache_name()) do
      {:ok, _} = Application.ensure_all_started(:cachex)
      {:ok, _pid} = Cachex.start_link(Cache.cache_name())
    end

    :ok
  end

  setup do
    Cachex.clear(Cache.cache_name())
    %{org: KilnCMS.Accounts.default_org_id()}
  end

  test "put/4 stores a body and serves it back", %{org: org} do
    Cache.put(org, :page, "id-1", :web, %{"html" => "hi"})
    assert {:ok, %{"html" => "hi"}} = Cache.get(org, :page, "id-1", :web)
  end

  test "put/4 sets a TTL on the entry (uses :expire, not the ignored :ttl)", %{org: org} do
    Cache.put(org, :post, "id-2", :json, %{"x" => 1})

    # Cachex.ttl returns the remaining lifetime; {:ok, nil} means no expiry was
    # set — which is exactly the bug (:ttl is silently dropped, :expire isn't).
    assert {:ok, ms} = Cachex.ttl(Cache.cache_name(), {org, :post, "id-2", :json})
    assert is_integer(ms) and ms > 0
  end

  test "evict/2 drops every surface for a document", %{org: org} do
    for surface <- [:web, :json, :json_ld], do: Cache.put(org, :page, "id-3", surface, %{})
    Cache.evict(org, :page, "id-3")

    for surface <- [:web, :json, :json_ld],
        do: assert(:miss = Cache.get(org, :page, "id-3", surface))
  end
end
