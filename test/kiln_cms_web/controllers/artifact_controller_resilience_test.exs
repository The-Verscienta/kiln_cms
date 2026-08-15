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
  defp warm_tenant_resolution do
    host = build_conn().host

    assert {:ok, _org} = KilnCMSWeb.Tenant.fetch_org(host)
    assert {:ok, cached} = Cachex.get(KilnCMS.Cache.Hosts.cache_name(), host)
    refute is_nil(cached), "host resolution for #{host} was not cached, so the outage will 404"
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

  test "degrades to a retryable 503 for cold content during an outage" do
    cold_slug = "res-cold-#{System.unique_integer([:positive])}"

    resp = without_db(fn -> get(build_conn(), ~p"/api/content/page/#{cold_slug}") end)

    assert %{"errors" => [%{"code" => "temporarily_unavailable", "status" => "503"}]} =
             json_response(resp, 503)

    assert ["2"] = get_resp_header(resp, "retry-after")
  end
end
