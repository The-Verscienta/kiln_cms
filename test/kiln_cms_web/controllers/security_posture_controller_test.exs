defmodule KilnCMSWeb.SecurityPostureControllerTest do
  @moduledoc """
  `GET /api/security/posture` (#2521): who is refused and how, what an
  administrator gets (and a platform administrator on top), the response's
  exact shape, that no result's details ever reach it, the 30-second cache
  per site and scope set, and the admin allowlist in front of it.

  `async: false`: the release check answers from `Kiln.Updates`' node-wide
  cache, the extra checks are installed through application env, and the
  rate-limit and telemetry cases are node-wide too. Every test uses a site of
  its own, so a cached snapshot or allowlist cannot reach another test.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures
  import KilnCMS.RateLimitHelpers, only: [client_conn: 1, put_limit: 2, restore_limits_on_exit: 0]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Security
  alias KilnCMS.Security.Posture
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  @path "/api/security/posture"
  @deployment_ids ~w(core.transport core.api_keys core.plugin_health core.security_notices)

  # Config checks (the registry's `checks:` seam). Each tells the listener
  # (the test, registered under `listener/0`) that it ran, and for which site.
  defmodule Listener do
    @moduledoc false
    def name, do: :security_posture_controller_test

    def ran(org_id) do
      if pid = Process.whereis(name()), do: send(pid, {:ran, org_id})
      :ok
    end
  end

  defmodule Counting do
    use Kiln.Security.Check
    def id, do: "test.counting"
    def title, do: "Counting"
    def scope, do: :site

    def run(context) do
      Listener.ran(context.org_id)
      pass("ok")
    end
  end

  defmodule Odd do
    use Kiln.Security.Check
    def id, do: "test.odd"
    def title, do: "Odd"
    def scope, do: :site

    def run(_context) do
      warn("Bad " <> <<0xFF>> <> " bytes.",
        details: ["leak@example.com"],
        fix_path: "/editor/team" <> <<0xFF>>,
        docs_url: "https://example.com/docs" <> <<0xFF>>,
        facts: %{
          :count => 2,
          "ratio" => 0.5,
          :on => true,
          :none => nil,
          "atom" => :x,
          "tuple" => {1, 2},
          "struct" => ~D[2026-01-01],
          "nested" => %{a: 1},
          "bad" => "a" <> <<0xFF>>
        }
      )
    end
  end

  defmodule Raising do
    use Kiln.Security.Check
    def id, do: "test.raising"
    def title, do: "Raising"
    def scope, do: :site
    def run(_context), do: raise("boom")
  end

  setup do
    Kiln.Updates.put_cache({:ok, :current})
    on_exit(&Kiln.Updates.clear_cache/0)

    original = Application.get_env(:kiln_cms, Posture, [])
    on_exit(fn -> Application.put_env(:kiln_cms, Posture, original) end)

    %{site: org("pjson")}
  end

  # --- helpers ------------------------------------------------------------------

  defp checks!(modules), do: Application.put_env(:kiln_cms, Posture, checks: modules)

  defp listen!, do: Process.register(self(), Listener.name())

  defp mint(owner, access) do
    owner.id
    |> Accounts.mint_api_key!(
      "posture-monitor",
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

  defp ids(conn), do: Enum.map(body(conn)["checks"], & &1["id"])

  defp check(conn, id), do: Enum.find(body(conn)["checks"], &(&1["id"] == id))

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

      owner = site_admin(site)
      plaintext = mint(owner, :read)
      [key] = Accounts.list_api_keys!(owner.id, actor: user(:admin))
      Accounts.revoke_api_key!(key, actor: user(:admin))

      assert req(site, plaintext).status == 401
    end

    for role <- [:viewer, :editor] do
      test "a #{role} of the site (JWT): 403 forbidden", %{site: site} do
        conn = req(site, token(user(:viewer) |> member!(site, unquote(role))))

        assert conn.status == 403
        assert code(conn) == "forbidden"
        assert no_store?(conn)
      end
    end

    test "an API key owned by an editor", %{site: site} do
      editor = user(:viewer) |> member!(site, :editor)
      assert req(site, mint(editor, :read_write)).status == 403
    end

    test "an admin of another site, on this site's host", %{site: site} do
      outsider = user(:viewer) |> member!(org("pjson-other"), :admin)
      assert req(site, token(outsider)).status == 403
    end

    test "an admin whose membership is still pending", %{site: site} do
      pending = user(:viewer) |> member!(site, :admin, status: :pending)
      assert req(site, token(pending)).status == 403
    end

    test "a draft_write key, even once its owner is made a site admin", %{site: site} do
      owner = user(:viewer)
      key = mint(owner, :draft_write)
      member!(owner, site, :admin)

      conn = req(site, key)
      assert conn.status == 403
      assert code(conn) == "forbidden"

      # The same owner's JWT is an admin's.
      assert req(site, token(owner)).status == 200
    end
  end

  # --- successful callers ------------------------------------------------------------

  describe "an administrator" do
    test "of the site (JWT) gets the site's checks only", %{site: site} do
      conn = req(site, token(site_admin(site)))

      assert conn.status == 200
      assert no_store?(conn)
      assert %{"scopes" => ["site"], "org_id" => org_id} = body(conn)
      assert org_id == site.id
      assert Enum.all?(body(conn)["checks"], &(&1["scope"] == "site"))
      assert Enum.all?(@deployment_ids, &(&1 not in ids(conn)))
    end

    test "of the platform (JWT) gets the deployment's checks too", %{site: site} do
      conn = req(site, token(user(:admin)))

      assert conn.status == 200
      assert body(conn)["scopes"] == ["site", "deployment"]
      assert "core.transport" in ids(conn)
    end

    test "of the site is not served the deployment checks a platform admin left cached", %{
      site: site
    } do
      assert "core.transport" in ids(req(site, token(user(:admin))))

      conn = req(site, token(site_admin(site)))
      assert body(conn)["scopes"] == ["site"]
      assert Enum.all?(@deployment_ids, &(&1 not in ids(conn)))
    end

    test "may use an API key", %{site: site} do
      assert req(site, mint(site_admin(site), :read)).status == 200

      conn = req(site, mint(user(:admin), :read))
      assert conn.status == 200
      assert "core.transport" in ids(conn)
    end
  end

  # --- response content ----------------------------------------------------------------

  describe "the response" do
    test "has exactly the documented shape", %{site: site} do
      body = body(req(site, token(site_admin(site))))

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(checks counts generated_at org_id scopes status version)

      assert body["version"] == 1
      assert {:ok, _at, 0} = DateTime.from_iso8601(body["generated_at"])
      assert body["status"] in ~w(pass warn fail)

      assert body["counts"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(fail warn error unknown pass n_a))

      assert body["counts"] |> Map.values() |> Enum.sum() == length(body["checks"])

      for check <- body["checks"] do
        assert check |> Map.keys() |> Enum.sort() ==
                 ~w(docs_url error facts fix_path id plugin scope source status summary title)
      end

      ids = Enum.map(body["checks"], & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "never carries a result's details, nor anyone's address", %{site: site} do
      # Neither has a second factor, so `core.second_factor` lists both.
      admin = site_admin(site)
      editor = user(:viewer) |> member!(site, :editor)
      emails = Enum.map([admin, editor], &to_string(&1.email))

      {:ok, ran} = Security.run_posture(%{}, actor: admin, tenant: site)
      second = Enum.find(ran.entries, &(&1.id == "core.second_factor"))
      assert Enum.all?(emails, fn email -> Enum.any?(second.result.details, &(&1 =~ email)) end)

      conn = req(site, token(admin))
      assert conn.status == 200
      for email <- emails, do: refute(conn.resp_body =~ email)

      for check <- body(conn)["checks"] do
        refute Map.has_key?(check, "details")
        refute Map.has_key?(check, "description")
      end

      # The deployment's checks name platform admins and key owners.
      operator = user(:admin)
      mint(operator, :read_write)

      conn = req(site, token(operator))
      assert conn.status == 200
      assert check(conn, "core.operator_second_factor")
      assert check(conn, "core.api_keys")
      refute conn.resp_body =~ to_string(operator.email)
    end

    test "is valid JSON whatever a check answered, with only scalar facts", %{site: site} do
      checks!([Odd])
      conn = req(site, token(site_admin(site)))

      assert conn.status == 200
      odd = check(conn, "test.odd")

      assert odd["facts"] == %{
               "count" => 2,
               "ratio" => 0.5,
               "on" => true,
               "none" => nil,
               "bad" => "a�"
             }

      assert odd["summary"] == "Bad � bytes."
      assert %{"source" => "config", "plugin" => nil, "status" => "warn"} = odd
      # A link with bad bytes is dropped, not repaired.
      assert %{"fix_path" => nil, "docs_url" => nil} = odd
      refute conn.resp_body =~ "leak@example.com"
    end

    test "names a plugin's checks by source and plugin", %{site: site} do
      conn = req(site, token(site_admin(site)))

      assert %{"source" => "plugin", "plugin" => "kiln_dep_fixture"} =
               check(conn, "dep_fixture.build_env")

      assert %{"source" => "core", "plugin" => nil} = check(conn, "core.second_factor")
    end

    test "has a row for a check that crashed", %{site: site} do
      checks!([Raising])
      conn = req(site, token(site_admin(site)))

      assert %{
               "status" => "error",
               "error" => "crashed",
               "summary" => nil,
               "fix_path" => nil,
               "docs_url" => nil,
               "facts" => facts
             } = check(conn, "test.raising")

      assert facts == %{}
      assert body(conn)["status"] in ~w(warn fail)
      assert body(conn)["counts"]["error"] >= 1
    end
  end

  # --- the cache ------------------------------------------------------------------------

  describe "the cache" do
    test "a second request inside the window runs no check", %{site: site} do
      listen!()
      checks!([Counting])
      jwt = token(site_admin(site))
      site_id = site.id

      first = req(site, jwt)
      second = req(site, jwt)

      assert_received {:ran, ^site_id}
      refute_received {:ran, _}
      assert body(first)["generated_at"] == body(second)["generated_at"]
    end

    test "an entry lives at most 30 seconds, and a cleared one is recomputed", %{site: site} do
      listen!()
      checks!([Counting])
      jwt = token(site_admin(site))
      site_id = site.id

      assert req(site, jwt).status == 200
      assert_received {:ran, ^site_id}

      key = KilnCMS.Cache.security_posture_key(site.id, [:site])
      assert {:ok, ms} = Cachex.ttl(KilnCMS.Cache.cache_name(), key)
      assert ms > 0 and ms <= Posture.snapshot_ttl()
      assert Posture.snapshot_ttl() == 30_000

      Cachex.del(KilnCMS.Cache.cache_name(), key)
      assert req(site, jwt).status == 200
      assert_received {:ran, ^site_id}
    end

    test "is per site: a platform admin's warm entry for one site is not another's" do
      listen!()
      checks!([Counting])
      a = org("pjson-a")
      b = org("pjson-b")
      inside = {203, 0, 113, 40}
      allow!(a, [cidr(inside)], inside)
      jwt = token(user(:admin))

      on_a = req(a, jwt, from(a, inside))
      assert on_a.status == 200
      assert body(on_a)["org_id"] == a.id

      assert %{"status" => "pass", "facts" => %{"entries" => 1}} =
               check(on_a, "core.admin_allowlist")

      on_b = req(b, jwt, from(b, inside))
      assert on_b.status == 200
      assert body(on_b)["org_id"] == b.id

      assert %{"status" => "n_a", "facts" => %{"entries" => 0}} =
               check(on_b, "core.admin_allowlist")

      a_id = a.id
      b_id = b.id
      assert_received {:ran, ^a_id}
      assert_received {:ran, ^b_id}
    end

    test "a busy answer is a 503 and is not cached", %{site: site} do
      test = self()

      holders =
        for _ <- 1..Posture.max_per_org() do
          spawn(fn ->
            Registry.register(Posture.slots(), site.id, nil)
            send(test, :held)
            Process.sleep(:infinity)
          end)
        end

      for _ <- holders, do: assert_receive(:held)
      on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)
      jwt = token(site_admin(site))

      conn = req(site, jwt)
      assert conn.status == 503
      assert code(conn) == "temporarily_unavailable"
      assert get_resp_header(conn, "retry-after") == ["5"]
      assert no_store?(conn)

      Enum.each(holders, &Process.exit(&1, :kill))

      KilnCMS.Test.Eventually.eventually(fn ->
        Registry.lookup(Posture.slots(), site.id) == []
      end)

      assert req(site, jwt).status == 200
    end
  end

  # --- the admin allowlist -----------------------------------------------------------------

  describe "the admin allowlist" do
    setup %{site: site} do
      inside = {203, 0, 113, 50}
      allow!(site, [cidr(inside)], inside)
      %{inside: inside, outside: {198, 51, 100, 200}}
    end

    test "refuses a valid platform admin's key from outside it", %{site: site, outside: outside} do
      key = mint(user(:admin), :read)
      conn = req(site, key, from(site, outside))

      assert conn.status == 403
      assert code(conn) == "network_not_allowed"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      refute conn.resp_body =~ "checks"

      events =
        Security.list_events!(actor: user(:admin), tenant: site.id, page: [limit: 100])
        |> then(fn
          %{results: results} -> results
          list -> list
        end)
        |> Enum.filter(&(&1.type == :admin_access_refused))

      assert [event] = events
      assert event.metadata["surface"] == "api"
    end

    test "refuses before authentication: no credential from outside is a 403, not a 401", %{
      site: site,
      outside: outside
    } do
      conn = req(site, nil, from(site, outside))
      assert conn.status == 403
      assert code(conn) == "network_not_allowed"
    end

    test "lets a request from inside it through", %{site: site, inside: inside} do
      assert req(site, token(site_admin(site)), from(site, inside)).status == 200
    end

    test "answers 503 when the list cannot be read", %{site: site, inside: inside} do
      jwt = token(site_admin(site))

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
