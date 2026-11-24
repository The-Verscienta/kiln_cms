defmodule KilnCMSWeb.TenantHostCacheKeysTest do
  @moduledoc """
  `KilnCMSWeb.Tenant.host_cache_keys/1` (#3194) names every key
  `KilnCMS.Cache.Hosts` holds an org under, so `BustSiteUrls` can drop them
  when the org's slug or custom domain changes.

  Each case resolves real hosts through `Tenant.fetch_org/1` and compares what
  landed in the cache with the helper's list, so the test follows the cache's
  actual keying rather than a copy of it.

  `async: false`: it writes `:console_host` with `Application.put_env/3` and
  clears the node-wide host cache.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Cache.Hosts
  alias KilnCMSWeb.Tenant

  setup do
    previous = Application.get_env(:kiln_cms, :console_host)
    Application.delete_env(:kiln_cms, :console_host)
    Hosts.clear()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :console_host, previous),
        else: Application.delete_env(:kiln_cms, :console_host)

      Hosts.clear()
    end)

    :ok
  end

  # The keys resolving `hosts` leaves in the host cache.
  defp cached_after_resolving(hosts) do
    Hosts.clear()
    Enum.each(hosts, &Tenant.fetch_org/1)
    {:ok, keys} = Cachex.keys(Hosts.cache_name())
    Enum.sort(keys)
  end

  test "an org's subdomain, in every spelling a browser may send" do
    o = org("keys")
    host = "#{o.slug}.#{Tenant.base_host()}"

    assert Tenant.host_cache_keys(o) == [host]

    assert cached_after_resolving([host, String.upcase(host), host <> "."]) == [host]
  end

  test "a custom domain is a key beside the subdomain" do
    o = org("vanity", custom_domain: "www.vanity-#{System.unique_integer([:positive])}.example")
    subdomain = "#{o.slug}.#{Tenant.base_host()}"
    expected = Enum.sort([o.custom_domain, subdomain])

    assert Enum.sort(Tenant.host_cache_keys(o)) == expected

    assert cached_after_resolving([String.upcase(o.custom_domain) <> ".", subdomain]) ==
             expected
  end

  test "a custom domain stored in capitals is keyed as a request host is, downcased" do
    o = org("caps", custom_domain: "WWW.Caps-#{System.unique_integer([:positive])}.example")

    assert String.downcase(o.custom_domain) in Tenant.host_cache_keys(o)
  end

  test "an org's console host is a key once a console host is set" do
    console = "console#{System.unique_integer([:positive])}.#{Tenant.base_host()}"
    Application.put_env(:kiln_cms, :console_host, console)
    o = org("con")
    console_key = "#{o.slug}.#{console}"

    assert console_key in Tenant.host_cache_keys(o)
    assert cached_after_resolving([console_key]) == [console_key]
  end

  test "the default org adds the base host and the console host" do
    console = "console#{System.unique_integer([:positive])}.#{Tenant.base_host()}"
    Application.put_env(:kiln_cms, :console_host, console)
    default = Accounts.default_org()
    keys = Tenant.host_cache_keys(default)

    assert Tenant.base_host() in keys
    assert console in keys

    # An unmatched host falls back to the default org through the base host's
    # entry, which is in the list; the host's own miss is no resolution of it.
    assert Tenant.base_host() in cached_after_resolving(["unknown.example", console])
    assert cached_after_resolving([Tenant.base_host(), console]) -- keys == []
  end

  test "another org never lists the base or console host" do
    console = "console#{System.unique_integer([:positive])}.#{Tenant.base_host()}"
    Application.put_env(:kiln_cms, :console_host, console)
    keys = Tenant.host_cache_keys(org("other"))

    refute Tenant.base_host() in keys
    refute console in keys
  end
end
