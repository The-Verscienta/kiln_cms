defmodule KilnCMSWeb.PluginHealthControllerTest do
  @moduledoc """
  `GET /api/security/plugin-health` (#2571): who is refused and how (a site
  administrator included), that a platform administrator reads the cached
  report the same on every site's host, that a cold cache answers
  `not_checked` without asking anything or starting a check, and the admin
  allowlist and rate limit in front of it.

  `async: false`: the health and notices caches are `:persistent_term`, the
  warmer a node-wide registered name, the check's switch application env, and
  the rate-limit case node-wide too. Every test uses a site of its own, so an
  allowlist cannot reach another test.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures
  import KilnCMS.RateLimitHelpers, only: [client_conn: 1, put_limit: 2, restore_limits_on_exit: 0]
  import KilnCMS.Test.Eventually, only: [eventually: 1]

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.Notice
  alias Kiln.SecurityNotices
  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  @path "/api/security/plugin-health"

  setup do
    health = Application.get_env(:kiln_cms, Health, [])
    notices = Application.get_env(:kiln_cms, SecurityNotices, [])
    Health.clear_cache()

    # Opted in the way production is: the check on, the notices feed
    # following the update feed (kilncms.dev's). Anything that asked would
    # reach these stubs, which report every request to the test.
    Application.put_env(:kiln_cms, Health, Keyword.put(health, :enabled, true))
    Application.put_env(:kiln_cms, SecurityNotices, Keyword.put(notices, :url, nil))

    on_exit(fn ->
      Application.put_env(:kiln_cms, Health, health)
      Application.put_env(:kiln_cms, SecurityNotices, notices)
      Health.clear_cache()
    end)

    test = self()

    for name <- [SecurityNotices, Health] do
      Req.Test.stub(name, fn conn ->
        send(test, {:request, conn.host, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)
    end

    %{site: org("phjson")}
  end

  # --- helpers ------------------------------------------------------------------

  defp mint(owner, access) do
    owner.id
    |> Accounts.mint_api_key!(
      "plugin-health-monitor",
      DateTime.add(DateTime.utc_now(), 7, :day),
      %{access: access},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp token(user), do: signed_in(user).__metadata__.token

  defp signed_in(user) do
    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(Accounts.User, :password),
        :sign_in,
        %{"email" => user.email, "password" => TwoFactorFixtures.password()},
        []
      )

    signed_in
  end

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # A `:draft_write` key can only be minted for a viewer-tier owner; its owner
  # is made a platform admin afterwards, so the key is a platform admin's.
  defp platform_admin_draft_write_key do
    owner = user(:viewer)
    key = mint(owner, :draft_write)
    {key, Ash.Seed.update!(owner, %{role: :admin})}
  end

  # A GET on `site`'s host from an address of its own (so the `:api` bucket
  # is this test's), with `credential` as the bearer when given.
  defp req(site, credential \\ nil, conn \\ nil) do
    conn =
      case conn do
        nil -> build_conn() |> unique_ip()
        conn -> conn
      end

    conn = conn |> org_conn(site) |> put_req_header("accept", "application/json")

    conn =
      if credential,
        do: put_req_header(conn, "authorization", "Bearer #{credential}"),
        else: conn

    get(conn, @path)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp code(conn) do
    assert %{"errors" => [%{"code" => code}]} = body(conn)
    code
  end

  defp no_store?(conn), do: get_resp_header(conn, "cache-control") == ["private, no-store"]

  defp site_admin(site), do: user(:viewer) |> member!(site, :admin)

  defp cidr(address), do: KilnCMS.Security.Cidr.client_range(address)

  defp from(site, address) do
    %Plug.Conn{} =
      conn = Plug.Test.put_peer_data(build_conn(), %{address: address, port: 1, ssl_cert: nil})

    org_conn(%Plug.Conn{conn | remote_ip: address}, site)
  end

  defp allow!(site, cidrs, saving_from) do
    CMS.save_site_admin_allowlist!(%{cidrs: cidrs},
      actor: signed_in(site_admin(site)),
      tenant: site.id,
      context: %{client_ip: saving_from}
    )
  end

  # A security notice covering the dependency fixture plugin's 0.1.0.
  @notice %Notice{
    id: "GHSA-test-0000-0001",
    aliases: ["CVE-2026-99999"],
    title: "A title for a person",
    packages: ["kiln_dep_fixture"],
    affected: ">= 0.1.0, < 0.2.0",
    patched: "0.2.0",
    severity: :high,
    url: "https://kilncms.dev/security/GHSA-test-0000-0001",
    source: :kiln
  }

  # As if a check had just fetched: no Hex plugins to ask about, one notice.
  defp warm! do
    Health.put_cache(%{hex: %{}, notices: {:ok, [@notice]}})
    assert Health.cached()
  end

  defp plugin(conn, id), do: Enum.find(body(conn)["plugins"], &(&1["id"] == id))

  # Nothing was asked, nothing is running that would ask, and nothing was
  # cached by a fetch that ran somewhere the stub could not see.
  defp assert_nothing_asked do
    eventually(fn ->
      is_nil(Process.whereis(Health.warmer_name())) and
        is_nil(Process.whereis(SecurityNotices.warmer_name()))
    end)

    refute_received {:request, _host, _path}
    assert SecurityNotices.cached() == nil
    # A disabled check answers a report without fetching; otherwise the
    # health cache is still cold.
    if Health.enabled?(), do: assert(Health.cached() == nil)
  end

  # --- refused callers -------------------------------------------------------------

  describe "is refused to" do
    test "a request with no credential: 401, and no-store", %{site: site} do
      conn = req(site)

      assert conn.status == 401
      assert code(conn) == "unauthenticated"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert no_store?(conn)
    end

    test "a bearer that does not verify: 401 invalid_token, still no-store", %{site: site} do
      conn = req(site, "garbage")

      assert conn.status == 401
      assert code(conn) == "invalid_token"
      assert no_store?(conn)
    end

    test "an unknown or revoked API key", %{site: site} do
      assert req(site, "kiln_nope").status == 401

      owner = user(:admin)
      plaintext = mint(owner, :read)
      [key] = Accounts.list_api_keys!(owner.id, actor: user(:admin))
      Accounts.revoke_api_key!(key, actor: user(:admin))

      assert req(site, plaintext).status == 401
    end

    for role <- [:viewer, :editor, :admin] do
      test "a #{role} of the site (JWT): 403 forbidden", %{site: site} do
        conn = req(site, token(user(:viewer) |> member!(site, unquote(role))))

        assert conn.status == 403
        assert code(conn) == "forbidden"
        assert no_store?(conn)
        refute conn.resp_body =~ "plugins"
      end
    end

    for role <- [:viewer, :editor] do
      test "a platform #{role} (JWT and key)", %{site: site} do
        actor = user(unquote(role))
        assert req(site, token(actor)).status == 403
        assert req(site, mint(actor, :read)).status == 403
      end
    end

    test "a key owned by an editor of the site", %{site: site} do
      editor = user(:viewer) |> member!(site, :editor)
      assert req(site, mint(editor, :read_write)).status == 403
    end

    test "the site's admin with a read key, on their own site's host", %{site: site} do
      conn = req(site, mint(site_admin(site), :read))

      assert conn.status == 403
      assert code(conn) == "forbidden"
    end

    test "an admin of another site, on this site's host", %{site: site} do
      outsider = user(:viewer) |> member!(org("phjson-other"), :admin)
      assert req(site, token(outsider)).status == 403
    end

    test "a draft_write key, even once its owner is made a platform admin", %{site: site} do
      {key, owner} = platform_admin_draft_write_key()
      conn = req(site, key)

      assert conn.status == 403
      assert code(conn) == "forbidden"
      assert no_store?(conn)

      # The same owner's JWT is a platform admin's.
      assert req(site, token(owner)).status == 200
    end

    test "an expired admin grant, through a JWT and through a read key", %{site: site} do
      expired = user(:editor, %{granted_role: :admin, granted_role_expires_at: later(-1)})

      assert req(site, token(expired)).status == 403
      assert req(site, mint(expired, :read)).status == 403
    end
  end

  # --- allowed callers ------------------------------------------------------------

  describe "a platform administrator" do
    test "may use a JWT or a read key", %{site: site} do
      admin = user(:admin)

      for credential <- [token(admin), mint(admin, :read), mint(admin, :read_write)] do
        conn = req(site, credential)
        assert conn.status == 200
        assert no_store?(conn)
      end
    end

    test "by a live admin grant, through a JWT and through a read key", %{site: site} do
      granted = user(:editor, %{granted_role: :admin, granted_role_expires_at: later(3600)})

      assert req(site, token(granted)).status == 200
      assert req(site, mint(granted, :read)).status == 200
    end
  end

  # --- the cached report -------------------------------------------------------------

  describe "with a warm cache" do
    test "answers the cached report, the same on every site's host", %{site: site} do
      warm!()
      jwt = token(user(:admin))

      conn = req(site, jwt)
      assert conn.status == 200
      body = body(conn)

      assert %{"version" => 1, "state" => "fresh", "notices" => "ok"} = body
      assert {:ok, _at, 0} = DateTime.from_iso8601(body["checked_at"])

      assert %{
               "name" => "kiln_dep_fixture",
               "source" => "path",
               "package" => nil,
               "version" => "0.1.0",
               "integrity" => %{"status" => "unverifiable", "reason" => "path"},
               "notices" => %{
                 "complete" => true,
                 "items" => [
                   %{
                     "id" => "GHSA-test-0000-0001",
                     "aliases" => ["CVE-2026-99999"],
                     "severity" => "high",
                     "source" => "kiln",
                     "url" => "https://kilncms.dev/security/GHSA-test-0000-0001"
                   }
                 ]
               }
             } = plugin(conn, "KilnDepFixture.Plugin")

      assert %{"source" => "overlay", "integrity" => %{"status" => "not_applicable"}} =
               plugin(conn, "KilnCMS.FixturePlugin")

      # Display text from the notice is never emitted.
      refute conn.resp_body =~ "A title for a person"
      refute conn.resp_body =~ ">= 0.1.0"

      other = req(org("phjson-b"), jwt)
      assert other.status == 200
      assert body(other) == body

      refute_received {:request, _host, _path}
    end
  end

  describe "with a cold cache" do
    test "answers not_checked, asks nothing and starts no check", %{site: site} do
      conn = req(site, token(user(:admin)))

      assert conn.status == 200
      assert no_store?(conn)
      assert get_resp_header(conn, "retry-after") == []

      assert body(conn) == %{
               "version" => 1,
               "state" => "not_checked",
               "checked_at" => nil,
               "notices" => nil,
               "counts" => %{
                 "fail" => 0,
                 "warn" => 0,
                 "unknown" => 0,
                 "unverifiable" => 0,
                 "not_applicable" => 0,
                 "ok" => 0
               },
               "plugins" => []
             }

      assert_nothing_asked()
    end

    test "a refused request asks nothing either", %{site: site} do
      assert req(site).status == 401
      assert req(site, token(site_admin(site))).status == 403
      {key, _owner} = platform_admin_draft_write_key()
      assert req(site, key).status == 403

      assert_nothing_asked()
    end

    test "a disabled check answers disabled, still asking nothing", %{site: site} do
      Application.put_env(
        :kiln_cms,
        Health,
        Keyword.put(Application.get_env(:kiln_cms, Health, []), :enabled, false)
      )

      conn = req(site, token(user(:admin)))
      assert %{"state" => "disabled", "checked_at" => nil, "plugins" => [_ | _]} = body(conn)

      assert_nothing_asked()
    end
  end

  # --- the admin allowlist -----------------------------------------------------------------

  describe "the admin allowlist" do
    setup %{site: site} do
      inside = {203, 0, 113, 60}
      allow!(site, [cidr(inside)], inside)
      %{inside: inside, outside: {198, 51, 100, 201}}
    end

    test "refuses a valid platform admin's key from outside it", %{site: site, outside: outside} do
      warm!()
      conn = req(site, mint(user(:admin), :read), from(site, outside))

      assert conn.status == 403
      assert code(conn) == "network_not_allowed"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      refute conn.resp_body =~ "plugins"
    end

    test "refuses before authentication: no credential from outside is a 403, not a 401", %{
      site: site,
      outside: outside
    } do
      conn = req(site, nil, from(site, outside))
      assert conn.status == 403
      assert code(conn) == "network_not_allowed"
    end

    test "lets a platform admin from inside it through", %{site: site, inside: inside} do
      assert req(site, token(user(:admin)), from(site, inside)).status == 200
    end

    test "answers 503 when the list cannot be read", %{site: site, inside: inside} do
      jwt = token(user(:admin))

      KilnCMS.OrgSettings.with_actor(nil, fn ->
        conn = req(site, jwt, from(site, inside))

        assert conn.status == 503
        assert code(conn) == "temporarily_unavailable"
        assert get_resp_header(conn, "retry-after") == ["30"]
      end)
    end
  end

  # --- rate limit -------------------------------------------------------------------------

  describe "the rate limit" do
    test "is the :api bucket, after the allowlist and the no-store header" do
      assert Phoenix.Router.route_info(KilnCMSWeb.Router, "GET", @path, "localhost").pipe_through ==
               [:admin_allowlist_api, :no_store, :api]
    end

    test "a spent :api bucket is a 429, still no-store", %{site: site} do
      restore_limits_on_exit()
      put_limit(:api, 1)
      {%Plug.Conn{remote_ip: address}, _key} = client_conn(build_conn())

      assert req(site, nil, from(site, address)).status == 401

      conn = req(site, nil, from(site, address))
      assert conn.status == 429
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end
end
