defmodule KilnCMSWeb.TenantDefaultOrgCacheTest do
  @moduledoc """
  A request whose `Host` resolves to no organization costs no `organizations`
  read once the default org is cached.

  With strict matching off, such a host is served the default org — a health
  check by IP, a platform's internal hostname when `PHX_HOST` is a custom
  domain, any unrecognised `Host`. The host's own miss was cached in
  `KilnCMS.Cache.Hosts`, but the default-org fallback behind it was a fresh
  database read on every request, in `KilnCMSWeb.Plugs.SetTenant` — the
  endpoint, above the router and every rate limiter. Under delivery load that
  read queued on the pool behind view-tracking writes and was most of the
  endpoint's p95.

  `async: false`, because the setup evicts the canonical host's entry to make
  the first request a real miss. `KilnCMS.Cache.Hosts` is process-global, and
  ExUnit runs sync modules alone, after the async ones, so no other test can be
  relying on that entry while it is gone.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Cache.Hosts
  alias KilnCMSWeb.Tenant

  setup do
    previous = Application.get_env(:kiln_cms, :tenant_strict_host)
    Application.put_env(:kiln_cms, :tenant_strict_host, false)
    on_exit(fn -> Application.put_env(:kiln_cms, :tenant_strict_host, previous) end)

    # The default org is what the canonical host resolves to, and the fallback
    # shares that entry — so evicting it is what makes the first request cold.
    Cachex.del(Hosts.cache_name(), Tenant.base_host())
    :ok
  end

  # A host nothing has resolved before, and that no org can claim: not under
  # the base host (so no slug lookup could match) and not anyone's custom
  # domain. Unique so no earlier resolution can answer for it.
  defp stray_host, do: "stray-#{System.unique_integer([:positive])}.invalid"

  # How many `organizations` queries `fun` issues from this process. Telemetry
  # handlers run in the process that ran the query, which for a `ConnTest`
  # request is this one — so filtering on `self()` keeps out background work
  # (Oban, the async view-tracking writes) that has nothing to do with tenant
  # resolution.
  defp organizations_queries(fun) do
    handler = "tenant-default-org-#{System.unique_integer([:positive])}"
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test_pid and meta[:source] == "organizations", do: send(test_pid, ref)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    count(ref, 0)
  end

  defp count(ref, n) do
    receive do
      ^ref -> count(ref, n + 1)
    after
      0 -> n
    end
  end

  defp get_on(host, path), do: get(%{build_conn() | host: host}, path)

  test "a second request on a non-canonical host issues no organizations query" do
    host = stray_host()

    first = organizations_queries(fn -> assert get_on(host, ~p"/api/locales").status == 200 end)
    second = organizations_queries(fn -> assert get_on(host, ~p"/api/locales").status == 200 end)

    # The first request is cold on both entries: the host's own lookup and the
    # default org behind it. Asserting it saw queries at all is what keeps the
    # zero below from passing on a handler that never fires.
    assert first > 0

    assert second == 0,
           "expected the default-org fallback to be served from KilnCMS.Cache.Hosts, " <>
             "got #{second} organizations queries on a warm host"
  end

  test "distinct stray hosts share the one cached default org" do
    # The flood case: every request carrying a different unrecognised `Host`.
    # Each still pays its own host lookup (that miss is per host, and bounded by
    # `Cache.Hosts`'s size), but not a default-org read on top of it.
    _warm = organizations_queries(fn -> get_on(stray_host(), ~p"/api/locales") end)

    cold_host_only = organizations_queries(fn -> get_on(stray_host(), ~p"/api/locales") end)
    Cachex.del(Hosts.cache_name(), Tenant.base_host())
    both_cold = organizations_queries(fn -> get_on(stray_host(), ~p"/api/locales") end)

    assert cold_host_only == both_cold - 1
  end

  test "the served org is the default org, with its row's fields, not the id-only stand-in" do
    conn = get_on(stray_host(), ~p"/api/locales")
    org = conn.assigns.current_org

    assert org.id == KilnCMS.Accounts.default_org_id()
    assert is_binary(org.slug)
  end
end
