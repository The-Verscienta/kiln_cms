defmodule KilnCMS.Security.ApiKeyTripTest do
  @moduledoc """
  An API key over a rate limit (#2245): only a key this node verified on an
  allowed request is recorded, as one sampled `api_key_rate_limited` event
  per key and bucket per window, in the owner's site, raising the platform's
  alert. Anything else (a forged, unknown, revoked or expired key, a JWT, a
  key this node has not seen) costs no database read or write.

  `async: false`: alerts are turned on, the alert window and the rate limits
  are lowered (`Application.put_env`), and the verified-key cache is one
  named ETS table.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  import KilnCMS.RateLimitHelpers,
    only: [client_address: 0, put_limit: 3, restore_limits_on_exit: 0]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.ApiKeyTrip
  alias KilnCMS.Test.SecurityAlerts
  alias KilnCMSWeb.GraphqlSocket

  @moduletag :capture_log

  @trip [:kiln_cms, :security, :api_key_trip]

  setup do
    SecurityAlerts.enable()
    restore_limits_on_exit()
    Application.put_env(:kiln_cms, :security_alert_window_ms, window())
    on_exit(fn -> Application.delete_env(:kiln_cms, :security_alert_window_ms) end)

    ref = :telemetry_test.attach_event_handlers(self(), [@trip])
    platform = user(:admin)

    %{platform: platform, telemetry: ref}
  end

  defp window, do: KilnCMS.Test.BudgetWindow.fresh_window_ms()
  defp uniq, do: System.unique_integer([:positive])
  defp days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  # One per test: lower `bucket` to `limit` for a window no clock boundary
  # can fall inside.
  defp limit(bucket, limit), do: put_limit(bucket, limit, window())

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "trip-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp member!(user, org_id, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: role
    })

    user
  end

  # A key and its secret. Minting raises `new_api_key`; that dispatch is
  # cleared so each test sees only its own trips.
  defp mint(ctx, owner, access \\ :read_write) do
    key =
      Accounts.mint_api_key!(owner.id, "svc-#{uniq()}", days(7), %{access: access},
        actor: ctx.platform
      )

    Repo.query!("DELETE FROM security_alert_dispatches")
    {key, Ash.Resource.get_metadata(key, :plaintext_api_key)}
  end

  defp jwt(owner) do
    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(Accounts.User, :password),
        :sign_in,
        %{"email" => to_string(owner.email), "password" => "password123456"},
        []
      )

    signed_in.__metadata__.token
  end

  # The same key id, another secret, with a CRC that checks out: it decodes
  # like a real key and fails only on the hash.
  defp wrong_secret(plaintext) do
    [prefix, middle, _crc] = String.split(plaintext, "_", parts: 3)

    {:ok, <<_random::binary-size(32), id::binary-size(16)>>} =
      AshAuthentication.Base.bindecode62(middle)

    token = :crypto.strong_rand_bytes(32) <> id

    "#{prefix}_#{AshAuthentication.Base.encode62(token)}_" <>
      AshAuthentication.Base.encode62(:erlang.crc32(token))
  end

  defp forged, do: "kiln_" <> Base.encode32(:crypto.strong_rand_bytes(40), padding: false)

  defp request(ip, credential, host \\ nil) do
    conn =
      build_conn()
      |> Map.put(:remote_ip, ip)
      |> put_req_header("accept", "application/json")
      |> put_req_header("user-agent", "Trip/1.0")

    conn =
      if credential,
        do: put_req_header(conn, "authorization", "Bearer " <> credential),
        else: conn

    if host, do: org_conn(conn, host), else: conn
  end

  defp json_api(ip, credential, host \\ nil),
    do: ip |> request(credential, host) |> get("/api/json/pages")

  defp gql(ip, credential, body) do
    ip
    |> request(credential)
    |> put_req_header("content-type", "application/json")
    |> post("/gql", Jason.encode!(body))
  end

  defp mcp(ip, credential) do
    ip
    |> request(credential)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}}))
  end

  defp trip_events do
    %{rows: rows} =
      Repo.query!(
        "SELECT org_id, target_id, actor_id, metadata FROM security_events " <>
          "WHERE type = 'api_key_rate_limited'"
      )

    Enum.map(rows, fn [org_id, target_id, actor_id, metadata] ->
      %{
        org_id: Ecto.UUID.load!(org_id),
        target_id: Ecto.UUID.load!(target_id),
        actor_id: actor_id,
        metadata: metadata
      }
    end)
  end

  defp events_in(org_id) do
    # authorize?: false — reading the log back in a test.
    Security.list_events!(tenant: org_id, authorize?: false)
    |> Enum.filter(&(&1.type == :api_key_rate_limited))
  end

  defp alerts,
    do: Enum.filter(SecurityAlerts.dispatches(), &(&1["kind"] == "api_key_rate_limited"))

  defp sample_rows do
    %{rows: [[rows]]} =
      Repo.query!(
        "SELECT count(*) FROM throttle_counters WHERE bucket = 'security_api_key_rate_limited'"
      )

    rows
  end

  defp results(ref) do
    receive do
      {@trip, ^ref, %{count: 1}, %{result: result, bucket: bucket}} ->
        [{result, bucket} | results(ref)]
    after
      0 -> []
    end
  end

  defp bells_for(user),
    do: Notification |> Repo.all() |> Enum.filter(&(&1.user_id == user.id))

  defp mails do
    Oban.drain_queue(queue: :mail, with_recursion: true)
    collect([])
  end

  defp collect(acc) do
    receive do
      {:email, mail} -> collect([mail | acc])
    after
      0 -> acc
    end
  end

  defp recipients(mails), do: mails |> Enum.flat_map(& &1.to) |> Enum.map(&elem(&1, 1))

  defp deliveries,
    do:
      CMS.WebhookDelivery
      |> Repo.all()
      |> Enum.filter(&String.starts_with?(&1.event, "security."))

  describe "a verified key over the :api limit" do
    test "on JSON:API: one event in the owner's one site, to the platform admins only", ctx do
      site = org("trip-owner")
      spoofed = org("trip-spoofed")
      owner = member!(user(:editor), site.id, :editor)
      site_admin = member!(user(:viewer), site.id, :admin)
      muted = user(:admin, %{notify_on_security_alert: false})

      # Every webhook event a site can subscribe to: a platform alert has none.
      CMS.create_webhook_endpoint!(
        %{url: "https://hooks.example.com/#{uniq()}", events: Alerts.webhook_events()},
        actor: site_admin,
        tenant: site.id
      )

      {key, secret} = mint(ctx, owner)
      limit(:api, 1)
      ip = client_address()

      assert json_api(ip, secret, spoofed).status != 429
      # The Host names another site; it does not choose where this goes.
      assert json_api(ip, secret, spoofed).status == 429

      assert [event] = events_in(site.id)
      assert event.target_type == "api_key"
      assert event.target_id == key.id
      assert event.actor_id == nil
      assert event.metadata == %{"name" => key.name, "bucket" => "api"}
      assert event.ip == :inet.ntoa(ip) |> to_string()
      assert events_in(spoofed.id) == []
      assert [_alert] = alerts()
      assert results(ctx.telemetry) == [{:noted, :api}]

      SecurityAlerts.deliver()

      assert [bell] = bells_for(ctx.platform)
      assert bell.excerpt =~ "An API key hit a rate limit"
      assert [_bell] = bells_for(muted)
      assert bells_for(site_admin) == []
      assert bells_for(owner) == []

      sent = recipients(mails())
      assert to_string(muted.email) in sent
      refute to_string(site_admin.email) in sent
      assert deliveries() == []
    end

    test "an owner with no site, or several, is recorded in the default org", ctx do
      for owner <- [
            user(:editor),
            user(:editor)
            |> member!(org("trip-a").id, :editor)
            |> member!(org("trip-b").id, :editor)
          ] do
        {_key, secret} = mint(ctx, owner)
        limit(:api, 1)
        ip = client_address()

        json_api(ip, secret)
        assert json_api(ip, secret).status == 429
      end

      assert [_, _] = events_in(Accounts.default_org_id())
      assert length(trip_events()) == 2
    end

    test "a flood is one event and one alert; a second bucket adds an event and the summary counts both",
         ctx do
      {key, secret} = mint(ctx, user(:editor))
      limit(:api, 1)
      limit(:gql, 1)
      ip = client_address()

      json_api(ip, secret)
      for _ <- 1..1_000, do: assert(json_api(ip, secret).status == 429)

      assert [_event] = trip_events()
      assert sample_rows() == 1
      assert [alert] = alerts()

      trips = results(ctx.telemetry)
      assert Enum.frequencies(trips) == %{{:noted, :api} => 1, {:debounced, :api} => 999}

      gql(ip, secret, %{query: "{ __typename }"})
      assert gql(ip, secret, %{query: "{ __typename }"}).status == 429

      assert [%{"bucket" => "api"}, %{"bucket" => "gql"}] =
               trip_events() |> Enum.map(& &1.metadata) |> Enum.sort_by(& &1["bucket"])

      assert Enum.all?(trip_events(), &(&1.target_id == key.id))
      assert [^alert] = alerts()

      SecurityAlerts.deliver()
      SecurityAlerts.close_window(alert["id"])
      SecurityAlerts.backdate_events()
      SecurityAlerts.deliver()

      excerpts = ctx.platform |> bells_for() |> Enum.map(& &1.excerpt) |> Enum.sort()

      # A platform alert always masks the address.
      network = ip |> :inet.ntoa() |> to_string() |> KilnCMS.Security.Cidr.truncate()

      assert excerpts == [
               "An API key hit a rate limit (from #{network})",
               "An API key hit a rate limit: 2 in this alert window"
             ]
    end

    test "two keys from one address are two events and one alert", ctx do
      {_a, secret_a} = mint(ctx, user(:editor))
      {_b, secret_b} = mint(ctx, user(:editor))
      limit(:api, 2)
      ip = client_address()

      json_api(ip, secret_a)
      json_api(ip, secret_b)
      assert json_api(ip, secret_a).status == 429
      assert json_api(ip, secret_b).status == 429

      assert [_, _] = trip_events()
      assert [_alert] = alerts()
    end
  end

  describe "never recorded" do
    setup ctx do
      owner = user(:editor)
      {key, secret} = mint(ctx, owner)
      %{owner: owner, key: key, secret: secret}
    end

    defp refused_unverified(ctx, credential) do
      limit(:api, 1)
      ip = client_address()

      # An allowed request first: the one place a key could be remembered.
      json_api(ip, credential)
      assert json_api(ip, credential).status == 429

      assert results(ctx.telemetry) == [{:unverified, :api}]
      assert trip_events() == []
      assert sample_rows() == 0
      assert alerts() == []
    end

    test("a forged kiln_ string", ctx, do: refused_unverified(ctx, forged()))

    test("a real key id with the wrong secret", ctx,
      do: refused_unverified(ctx, wrong_secret(ctx.secret))
    )

    test "a revoked key", ctx do
      {:ok, _} = Accounts.revoke_api_key(ctx.key, authorize?: false)
      refused_unverified(ctx, ctx.secret)
    end

    test "an expired key", ctx do
      Repo.query!(
        "UPDATE api_keys SET expires_at = now() - interval '1 minute' WHERE id = $1",
        [Ecto.UUID.dump!(ctx.key.id)]
      )

      refused_unverified(ctx, ctx.secret)
    end

    test("a JWT", ctx, do: refused_unverified(ctx, jwt(ctx.owner)))

    test "a valid key this node has not seen on an allowed request", ctx do
      limit(:api, 1)
      ip = client_address()

      json_api(ip, ctx.secret)
      ApiKeyTrip.clear()
      assert json_api(ip, ctx.secret).status == 429

      assert results(ctx.telemetry) == [{:unverified, :api}]
      assert trip_events() == []
    end

    test "a secret remembered against another key's actor is not remembered", ctx do
      {_other, other_secret} = mint(ctx, user(:editor))
      {:ok, actor} = Accounts.actor_from_api_key(ctx.secret)
      ApiKeyTrip.remember(other_secret, actor)

      limit(:api, 1)
      ip = client_address()
      json_api(ip, nil)
      assert json_api(ip, other_secret).status == 429

      assert results(ctx.telemetry) == [{:unverified, :api}]
      assert trip_events() == []
    end

    test "a request with no credential emits nothing", ctx do
      limit(:api, 1)
      ip = client_address()

      json_api(ip, nil)
      assert json_api(ip, nil).status == 429
      assert results(ctx.telemetry) == []
    end

    test "a key revoked after it was remembered records nothing", ctx do
      limit(:api, 1)
      ip = client_address()

      json_api(ip, ctx.secret)
      {:ok, _} = Accounts.revoke_api_key(ctx.key, authorize?: false)
      assert json_api(ip, ctx.secret).status == 429

      # It passed the in-memory gate; the reload refused it.
      assert results(ctx.telemetry) == [{:noted, :api}]
      assert trip_events() == []
      assert alerts() == []
    end

    test "forged keys sent after the trip do not use up the real key's alert", ctx do
      limit(:api, 1)
      ip = client_address()

      json_api(ip, ctx.secret)
      for _ <- 1..20, do: assert(json_api(ip, forged()).status == 429)
      for _ <- 1..5, do: assert(json_api(ip, wrong_secret(ctx.secret)).status == 429)
      assert json_api(ip, ctx.secret).status == 429

      assert [event] = trip_events()
      assert event.target_id == ctx.key.id
      assert [_alert] = alerts()
    end
  end

  describe "each surface" do
    setup ctx do
      {key, secret} = mint(ctx, user(:editor))
      %{key: key, secret: secret}
    end

    defp tripped(bucket) do
      assert [%{metadata: %{"bucket" => ^bucket}}] = trip_events()
      assert [_alert] = alerts()
    end

    test "/gql, one document", ctx do
      limit(:gql, 1)
      ip = client_address()

      gql(ip, ctx.secret, %{query: "{ __typename }"})
      assert gql(ip, ctx.secret, %{query: "{ __typename }"}).status == 429
      tripped("gql")
    end

    test "/gql, a batch refused by its per-operation charge", ctx do
      limit(:gql, 2)
      ip = client_address()

      gql(ip, ctx.secret, %{query: "{ __typename }"})
      # The rate-limit plug lets this request through (2 of 2); the batch's
      # second operation is the one over the limit.
      batch = %{_json: [%{query: "{ __typename }"}, %{query: "{ __typename }"}]}
      assert gql(ip, ctx.secret, batch).status == 429
      tripped("gql")
    end

    test "/mcp", ctx do
      limit(:api, 1)
      ip = client_address()

      assert mcp(ip, ctx.secret).status == 200
      assert mcp(ip, ctx.secret).status == 429
      tripped("api")
    end

    test "/api/media, where the key is already the actor", ctx do
      limit(:media_upload, 1)
      ip = client_address()

      ip |> request(ctx.secret) |> post("/api/media/import-url", %{})
      # `:media_upload` refuses after `:api` authenticated the key.
      assert (ip |> request(ctx.secret) |> post("/api/media/import-url", %{})).status == 429
      tripped("media_upload")
    end

    test "/media/:id/t, with a key verified on the API", ctx do
      limit(:media_transform, 1)
      ip = client_address()
      path = "/media/#{Ecto.UUID.generate()}/t/w_256"

      json_api(ip, ctx.secret)
      ip |> request(ctx.secret) |> get(path)
      assert (ip |> request(ctx.secret) |> get(path)).status == 429
      tripped("media_transform")
    end

    test "a plugin plug route, with a key verified on the API", ctx do
      limit(:plugin_endpoint, 1)
      ip = client_address()

      json_api(ip, ctx.secret)
      assert (ip |> request(ctx.secret) |> get("/fixture-hooks/ping")).status == 200
      assert (ip |> request(ctx.secret) |> get("/fixture-hooks/ping")).status == 429
      tripped("plugin_endpoint")
    end

    test "a bucket outside the list is not noted", ctx do
      ip = client_address()

      json_api(ip, ctx.secret)
      _ = ctx.telemetry |> results()
      assert ApiKeyTrip.note(request(ip, ctx.secret), :docs) == :ok
      assert results(ctx.telemetry) == []
      assert trip_events() == []
    end

    test "/ws/gql cannot carry a key: a kiln_ token connects as anonymous", ctx do
      assert {:ok, socket} =
               GraphqlSocket.connect(%{"token" => ctx.secret}, %Phoenix.Socket{}, %{})

      assert socket.assigns.absinthe.opts[:context].actor == nil
    end
  end
end
