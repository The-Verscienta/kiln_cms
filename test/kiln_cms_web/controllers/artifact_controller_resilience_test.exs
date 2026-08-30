defmodule KilnCMSWeb.ArtifactControllerResilienceTest do
  @moduledoc """
  "Stays up when the database doesn't" — end-to-end delivery resilience (#341).

  The outage is genuine: the request is dispatched from a bare spawned process
  which, in the async (non-shared) sandbox, has no connection allowance, so any
  database access raises exactly as a Postgres outage would. A warm request
  served through that proves delivery never needed the database.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "res-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()
    slug = "res-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Always Up",
          slug: slug,
          blocks: [%{type: :heading, content: "Cached", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    slug
  end

  # Dispatch `fun` from a bare, unallowed process (no sandbox `$callers`): any
  # database access raises, exactly as a Postgres outage would.
  #
  # The property under test — a cold miss degrades to a retryable 503 without
  # Postgres — does not depend on *how fast* that happens, so the deadline
  # below is incidental to what is being asserted rather than part of it. 3s
  # was a budget for a full Phoenix request dispatch measured against an idle
  # machine, and flaked under full-suite scheduler contention (#1145, same
  # shape as the three budget bugs #1125 fixed). The loop returns on the first
  # message, so a generous deadline costs nothing when it passes.
  defp without_db(fun, retries \\ 3) do
    warm_tenant_resolution()

    parent = self()
    spawn(fn -> send(parent, {:without_db, fun.()}) end)

    resp =
      receive do
        {:without_db, result} -> result
      after
        30_000 -> flunk("timed out")
      end

    if host_refused?(resp) and retries > 0 do
      without_db(fun, retries - 1)
    else
      resp
    end
  end

  # `KilnCMSWeb.Plugs.SetTenant` resolves the request's organization from its
  # `Host` in the endpoint, ahead of the router, and that resolution is a
  # database lookup unless `KilnCMS.Cache.Hosts` already holds the answer. A
  # failed read is not a miss (#1124), so during the outage a cold host cache
  # makes `Tenant.fetch_org/1` return `:error` and the request is refused as an
  # unknown host — a plain 404, before the controller is reached at all.
  #
  # That is a property of tenant resolution, not of delivery, and delivery is
  # what this suite is about. So prime the entry here, from the test process,
  # which still has its database connection — as a deployment already serving
  # traffic when Postgres went away would have it primed. It used to be primed
  # only incidentally, by whichever test happened to issue the first request, so
  # the cold-content test below failed whenever it ran first.
  # The primed entry can also be wiped in the instant between priming and
  # reading it back — the same wholesale clears the dispatch-time retry below
  # exists for — so priming re-runs until the read-back sees it, on a deadline
  # rather than a try-count (see ConnCase.eventually/4's docstring for why).
  # `fetch_org/1` must still succeed on every attempt: an `:error` there is not
  # the wipe race, and retrying it away would hide #1124.
  defp warm_tenant_resolution do
    host = build_conn().host
    prime_host_resolution(host, System.monotonic_time(:millisecond) + 5_000)
  end

  defp prime_host_resolution(host, deadline) do
    assert {:ok, _org} = KilnCMSWeb.Tenant.fetch_org(host)

    case Cachex.get(KilnCMS.Cache.Hosts.cache_name(), host) do
      {:ok, nil} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("host resolution for #{host} would not stay cached, so the outage will 404")
        else
          Process.sleep(25)
          prime_host_resolution(host, deadline)
        end

      {:ok, _cached} ->
        :ok
    end
  end

  # The host cache is global and other suites clear it wholesale
  # (`live_host_uri_test`), so the entry warmed above can still be dropped
  # between the warm-up and the dispatch. Matched on the refusal `SetTenant`
  # actually sends rather than on any 404, so a delivery path that genuinely
  # starts answering 404 fails the assertion instead of being retried away.
  defp host_refused?(%Plug.Conn{status: 404} = resp),
    do: resp.resp_body =~ "does not serve the requested host"

  defp host_refused?(_resp), do: false

  # Warm the caches (resolution + fired body) while the DB is up, then dispatch
  # the same GET from a process with no DB access. The content cache is global
  # and other suites bust it WIDE mid-run (media/form/promotion writes call
  # `Cache.bust_published/0`), so a concurrent async test can wipe our warm
  # entry between warm-up and the outage dispatch — when that race hits (503),
  # re-warm and try again. The property under test — a WARM entry is served
  # without Postgres — is unaffected by the retry.
  defp warm_then_get_without_db(path, retries \\ 3) do
    assert json_response(get(build_conn(), path), 200)

    resp = without_db(fn -> get(build_conn(), path) end)

    if resp.status == 503 and retries > 0 do
      warm_then_get_without_db(path, retries - 1)
    else
      resp
    end
  end

  test "serves warm content through a full database outage" do
    slug = published_page()

    # The warm path never touches Postgres, so delivery keeps answering.
    resp = warm_then_get_without_db(~p"/api/content/page/#{slug}")
    assert json_response(resp, 200)["slug"] == slug
  end

  test "serves every warm surface through an outage" do
    slug = published_page()

    for surface <- ["json", "json_ld", "web"] do
      assert json_response(
               get(build_conn(), ~p"/api/content/page/#{slug}?surface=#{surface}"),
               200
             )
    end

    resp = warm_then_get_without_db(~p"/api/content/page/#{slug}?surface=web")
    assert json_response(resp, 200)["html"] =~ "Cached"
  end

  test "serves warm content on a host resolution never cached, so the outage cannot 404 it" do
    slug = published_page()
    path = ~p"/api/content/page/#{slug}"

    # Warm the content cache on the usual host, then ask on one no request in
    # this run has ever resolved — so `KilnCMS.Cache.Hosts` cannot answer for it
    # and tenant resolution has to survive the outage on its own. With strict
    # matching off (the default here, and the default everywhere) an
    # unresolvable host is the default org, which is where the warm entry is.
    #
    # This is the whole #341 promise in one request, and it used to fail: a
    # failed read was reported as "no such org", and `SetTenant` refused in the
    # endpoint — above the router, so above this cache — with "this server does
    # not serve the requested host". Every host did that once its resolution
    # aged out mid-outage (5 min positive TTL, 1 min negative).
    assert json_response(warm_then_get_from_cold_host(path), 200)["slug"] == slug
  end

  # `warm_then_get_without_db/2` for a host whose *resolution* is cold too, with
  # the same retry and for the same reason: a concurrent async test busting the
  # content cache between the warm-up and the dispatch shows up as a 503, which
  # says nothing about the host. Each attempt invents a new host, so no attempt
  # can be answered by the entry a previous one wrote.
  defp warm_then_get_from_cold_host(path, retries \\ 3) do
    assert json_response(get(build_conn(), path), 200)

    host = "outage-e2e-#{System.unique_integer([:positive])}.#{KilnCMSWeb.Tenant.base_host()}"
    resp = without_db(fn -> get(%{build_conn() | host: host}, path) end)

    if resp.status == 503 and retries > 0 do
      warm_then_get_from_cold_host(path, retries - 1)
    else
      resp
    end
  end

  test "degrades to a retryable 503 for cold content during an outage" do
    # No tenant warm-up needed, and that is now guaranteed rather than lucky:
    # with strict matching off, a host whose lookup fails resolves to the default
    # org like any other unresolvable host (#341), so this reaches the controller
    # whether or not anything cached `www.example.com` first. Run alone, before
    # that fix, it 404'd in `SetTenant` every time — a *tenant* refusal wearing
    # the same status as a missing page, which is how it hid.
    cold_slug = "res-cold-#{System.unique_integer([:positive])}"

    resp = without_db(fn -> get(build_conn(), ~p"/api/content/page/#{cold_slug}") end)

    assert %{"errors" => [%{"code" => "temporarily_unavailable", "status" => "503"}]} =
             json_response(resp, 503)

    assert ["2"] = get_resp_header(resp, "retry-after")
  end
end
