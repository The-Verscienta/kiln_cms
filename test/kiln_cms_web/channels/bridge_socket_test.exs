defmodule KilnCMSWeb.BridgeSocketTest do
  @moduledoc """
  The visual-editing live-preview push socket (#355): connect authorization
  (draft visibility follows the preview token, or the API key) and forwarding of
  `{:preview_update, …}` broadcasts as JSON frames.
  """
  # async: false — one test toggles the global `:visual_editing_enabled` config.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewToken
  alias KilnCMSWeb.BridgeSocket
  alias KilnCMSWeb.PreviewLive

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bs-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner) do
    k =
      Accounts.mint_api_key!(
        owner.id,
        "bs",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: :read},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(k, :plaintext_api_key)
  end

  defp draft(admin) do
    KilnCMS.CMS.create_post!(
      %{title: "Draft", slug: "bs-#{System.unique_integer([:positive])}"},
      actor: admin
    )
  end

  # A preview token signed at `signed_at` (unix seconds) — the only way to hold
  # one that is about to lapse, or already has, without waiting 15 minutes. The
  # salt and claim shape are `PreviewToken.sign/1`'s.
  defp token_signed_at(record, signed_at) do
    Phoenix.Token.sign(
      KilnCMSWeb.Endpoint,
      "content preview",
      %{type: ContentTypes.type_name_for(record), id: record.id, org_id: record.org_id},
      signed_at: signed_at
    )
  end

  defp expired_token(record),
    do: token_signed_at(record, System.system_time(:second) - PreviewToken.max_age_seconds() - 1)

  # `victim`'s claims under `signed`'s signature: what an attacker holding a
  # token for one document writes to reach another.
  defp forge(signed, victim) do
    [protected, _payload, signature] = String.split(signed, ".")
    [_, payload, _] = String.split(victim, ".")
    Enum.join([protected, payload, signature], ".")
  end

  defp connect_with_token(type, id, token, extra \\ %{}) do
    BridgeSocket.connect(
      Map.merge(%{params: %{"type" => type, "id" => id, "preview_token" => token}}, extra)
    )
  end

  test "an editor key can connect to a draft and receives forwarded preview updates" do
    admin = user(:admin)
    post = draft(admin)

    assert {:ok, state} =
             BridgeSocket.connect(%{
               params: %{"type" => "post", "id" => post.id, "api_key" => key(admin)}
             })

    # The actor rides along so `init/1` can subscribe to that user's eviction
    # topic — this socket is a raw transport with no `id/1` callback, so it has
    # to listen for its own disconnect (#675) — and the org so the periodic
    # re-check re-reads the document under the tenant it was authorized against
    # (#775).
    assert %{type: "post", id: id, actor: %{id: actor_id}, org: %{}} = state
    assert id == post.id
    assert actor_id == admin.id

    # init subscribes THIS process to the editor's preview topic.
    assert {:ok, ^state} = BridgeSocket.init(state)

    payload = %{title: "New title", excerpt: false, blocks: []}

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      PreviewLive.topic("post", post.id),
      {:preview_update, payload}
    )

    assert_receive {:preview_update, ^payload}, 2_000

    assert {:push, {:text, json}, ^state} =
             BridgeSocket.handle_info({:preview_update, payload}, state)

    assert %{
             "event" => "update",
             "type" => "post",
             "id" => id,
             "title" => "New title",
             "excerpt" => nil
           } =
             Jason.decode!(json)

    assert id == post.id
  end

  test "a dynamic-type entry connects and receives forwarded updates (#355 tail)" do
    admin = user(:admin)

    definition =
      KilnCMS.CMS.create_type_definition!(
        %{name: "bs#{System.unique_integer([:positive])}", label: "BS"},
        actor: admin
      )

    entry =
      KilnCMS.CMS.ContentTypes.create!(
        definition.name,
        %{title: "Entry", slug: "bs-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    # The bridge connects with the dynamic type NAME — the same value the entry
    # editor uses as its `kind`, so the preview topic matches.
    assert {:ok, state} =
             BridgeSocket.connect(%{
               params: %{"type" => definition.name, "id" => entry.id, "api_key" => key(admin)}
             })

    assert {:ok, ^state} = BridgeSocket.init(state)

    payload = %{title: "Edited", excerpt: false, blocks: []}

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      PreviewLive.topic(definition.name, entry.id),
      {:preview_update, payload}
    )

    assert_receive {:preview_update, ^payload}, 2_000

    assert {:push, {:text, json}, ^state} =
             BridgeSocket.handle_info({:preview_update, payload}, state)

    assert %{"event" => "update", "type" => type, "title" => "Edited"} = Jason.decode!(json)
    assert type == definition.name
  end

  test "an anonymous connection is refused for a draft but allowed once published" do
    admin = user(:admin)
    post = draft(admin)

    # No key → anonymous → a draft is not readable → refuse.
    assert :error = BridgeSocket.connect(%{params: %{"type" => "post", "id" => post.id}})

    KilnCMS.CMS.publish_post!(post, %{}, actor: admin)

    assert {:ok, _} = BridgeSocket.connect(%{params: %{"type" => "post", "id" => post.id}})
  end

  test "unknown type or missing params are refused" do
    assert :error =
             BridgeSocket.connect(%{params: %{"type" => "bogus", "id" => Ash.UUID.generate()}})

    assert :error = BridgeSocket.connect(%{params: %{"type" => "post"}})
    assert :error = BridgeSocket.connect(%{params: %{}})
  end

  test "refused when visual editing is disabled" do
    admin = user(:admin)
    post = draft(admin)
    Application.put_env(:kiln_cms, :visual_editing_enabled, false)
    on_exit(fn -> Application.delete_env(:kiln_cms, :visual_editing_enabled) end)

    assert :error =
             BridgeSocket.connect(%{
               params: %{"type" => "post", "id" => post.id, "api_key" => key(admin)}
             })
  end

  describe "preview tokens" do
    test "a token minted for the draft connects with no actor and streams its updates" do
      admin = user(:admin)
      post = draft(admin)

      {:ok, %{token: token}} =
        PreviewToken.mint(:post, post.id, actor: admin, tenant: post.org_id)

      assert {:ok, state} = connect_with_token("post", post.id, token)
      assert %{type: "post", actor: nil, org: %{}} = state
      assert state.id == post.id

      # Kept for the re-check, but never where an inspected or crash-reported
      # state would print it.
      assert is_function(state.preview_token, 0)
      refute inspect(state) =~ token

      assert {:ok, ^state} = BridgeSocket.init(state)

      payload = %{title: "Token-watched", excerpt: false, blocks: []}

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        PreviewLive.topic("post", post.id),
        {:preview_update, payload}
      )

      assert_receive {:preview_update, ^payload}, 2_000

      assert {:push, {:text, json}, ^state} =
               BridgeSocket.handle_info({:preview_update, payload}, state)

      assert %{"event" => "update", "title" => "Token-watched"} = Jason.decode!(json)
    end

    test "a dynamic-type entry's token names its type and connects" do
      admin = user(:admin)

      definition =
        KilnCMS.CMS.create_type_definition!(
          %{name: "bt#{System.unique_integer([:positive])}", label: "BT"},
          actor: admin
        )

      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "Entry", slug: "bt-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      assert {:ok, %{type: type}} =
               connect_with_token(definition.name, entry.id, PreviewToken.sign(entry))

      assert type == definition.name
    end

    test "a token for another document, or another type, is refused" do
      admin = user(:admin)
      post = draft(admin)
      other = draft(admin)
      token = PreviewToken.sign(post)

      assert :error = connect_with_token("post", other.id, token)
      assert :error = connect_with_token("page", post.id, token)

      # The negative control: the same token on its own document.
      assert {:ok, _} = connect_with_token("post", post.id, token)
    end

    test "an expired token is refused" do
      post = draft(user(:admin))

      assert :error = connect_with_token("post", post.id, expired_token(post))
    end

    test "a tampered token is refused" do
      admin = user(:admin)
      mine = draft(admin)
      theirs = draft(admin)

      # A genuine token for `mine` with its claims swapped for `theirs`: the
      # signature no longer covers the payload.
      forged = forge(PreviewToken.sign(mine), PreviewToken.sign(theirs))

      assert :error = connect_with_token("post", theirs.id, forged)
      assert :error = connect_with_token("post", theirs.id, "garbage")
    end

    test "a token is the only credential consulted when present" do
      # A bad token next to a good key is a refusal, not a quiet fall back to
      # the key: a front end whose token lapsed must find out.
      admin = user(:admin)
      post = draft(admin)

      assert :error =
               BridgeSocket.connect(%{
                 params: %{
                   "type" => "post",
                   "id" => post.id,
                   "preview_token" => expired_token(post),
                   "api_key" => key(admin)
                 }
               })

      # Nor to an anonymous read of a document that is public anyway.
      KilnCMS.CMS.publish_post!(post, %{}, actor: admin)
      assert :error = connect_with_token("post", post.id, expired_token(post))
    end

    test "a token minted on another site is refused on this host (#336)" do
      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org BT",
          slug: "bt-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      post =
        KilnCMS.CMS.create_post!(
          %{title: "Other-site", slug: "bt-t-#{System.unique_integer([:positive])}"},
          actor: user(:admin),
          tenant: org
        )

      token = PreviewToken.sign(post)

      # The default host serves the default org, which is not the token's.
      assert :error = connect_with_token("post", post.id, token)

      uri = URI.parse("wss://#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}/ws/bridge")

      assert {:ok, %{org: %{id: org_id}}} =
               connect_with_token("post", post.id, token, %{connect_info: %{uri: uri}})

      assert org_id == org.id
    end
  end

  describe "periodic re-authorization (#775)" do
    setup do
      previous = Application.get_env(:kiln_cms, :socket_reauth_interval_ms)
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 50)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:kiln_cms, :socket_reauth_interval_ms)
          value -> Application.put_env(:kiln_cms, :socket_reauth_interval_ms, value)
        end
      end)

      :ok
    end

    test "init schedules the check, and a still-authorized stream survives it" do
      # A raw transport handles its own messages, so the timer lands here and
      # `handle_info/2` is called directly — the same path the WebSock adapter
      # takes. The negative control first: nothing about this connection has
      # changed, so it keeps streaming.
      admin = user(:admin)
      post = draft(admin)

      assert {:ok, state} =
               BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => post.id, "api_key" => key(admin)}
               })

      assert {:ok, state} = BridgeSocket.init(state)
      assert_receive :reauthorize, 1_000
      assert {:ok, state} = BridgeSocket.handle_info(:reauthorize, state)

      # And it rescheduled, rather than checking once and going quiet.
      assert_receive :reauthorize, 1_000
      assert {:ok, _state} = BridgeSocket.handle_info(:reauthorize, state)
    end

    test "a stream stops when its actor's grant is narrowed, with nothing evicting" do
      # `Ash.Seed.update!` writes the row directly, so no action runs and
      # `SessionEviction` never fires. The demoted account can no longer read a
      # draft, and the stream that was pushing it one stops.
      admin = user(:admin)
      post = draft(admin)

      assert {:ok, state} =
               BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => post.id, "api_key" => key(admin)}
               })

      assert {:ok, state} = BridgeSocket.init(state)

      Ash.Seed.update!(admin, %{role: :viewer})

      assert_receive :reauthorize, 1_000
      assert {:stop, :normal, _state} = BridgeSocket.handle_info(:reauthorize, state)
    end

    test "an ANONYMOUS stream stops when the document stops being public" do
      # The case eviction can never reach: an anonymous watcher holds no grant to
      # revoke, so a document unpublished under an open stream kept being pushed
      # to them until the tab closed. Only the document-side re-read catches it.
      admin = user(:admin)
      post = draft(admin) |> then(&KilnCMS.CMS.publish_post!(&1, %{}, actor: admin))

      assert {:ok, state} = BridgeSocket.connect(%{params: %{"type" => "post", "id" => post.id}})
      assert state.actor == nil

      assert {:ok, state} = BridgeSocket.init(state)

      Ash.Seed.update!(post, %{state: :draft})

      assert_receive :reauthorize, 1_000
      assert {:stop, :normal, _state} = BridgeSocket.handle_info(:reauthorize, state)
    end
  end

  describe "periodic re-authorization of a preview token (#775)" do
    setup do
      previous = Application.get_env(:kiln_cms, :socket_reauth_interval_ms)
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 50)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:kiln_cms, :socket_reauth_interval_ms)
          value -> Application.put_env(:kiln_cms, :socket_reauth_interval_ms, value)
        end
      end)

      :ok
    end

    test "the stream survives the check while its token is live, and closes once it lapses" do
      # A token with two seconds left: it passes the connect and the first
      # re-check, then lapses under the open stream — and the stream stops.
      # Without the re-check a leaked token would stream until the tab closed.
      post = draft(user(:admin))
      signed_at = System.system_time(:second) - PreviewToken.max_age_seconds() + 2
      token = token_signed_at(post, signed_at)

      assert {:ok, state} = connect_with_token("post", post.id, token)
      assert {:ok, state} = BridgeSocket.init(state)

      assert_receive :reauthorize, 1_000
      assert {:ok, state} = BridgeSocket.handle_info(:reauthorize, state)

      lapses_at_ms = (signed_at + PreviewToken.max_age_seconds()) * 1_000
      Process.sleep(max(lapses_at_ms - System.system_time(:millisecond), 0) + 50)

      assert_receive :reauthorize, 1_000
      assert {:stop, :normal, _state} = BridgeSocket.handle_info(:reauthorize, state)
    end

    test "the stream stops when the document it names is gone" do
      admin = user(:admin)
      post = draft(admin)

      assert {:ok, state} = connect_with_token("post", post.id, PreviewToken.sign(post))
      assert {:ok, state} = BridgeSocket.init(state)

      KilnCMS.CMS.destroy_post!(post, actor: admin)

      assert_receive :reauthorize, 1_000
      assert {:stop, :normal, _state} = BridgeSocket.handle_info(:reauthorize, state)
    end
  end

  describe "tenant scoping (#336)" do
    test "connect is scoped to the connecting host's org" do
      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org BS",
          slug: "bs-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      admin = user(:admin)

      post =
        KilnCMS.CMS.create_post!(
          %{title: "Other-site", slug: "bs-t-#{System.unique_integer([:positive])}"},
          actor: admin,
          tenant: org
        )

      k = key(admin)

      # No connect host (or the default host) resolves the default org — the
      # other org's document is invisible, so the socket is refused.
      assert :error =
               BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => post.id, "api_key" => k}
               })

      # The owning org's subdomain host resolves it.
      uri = URI.parse("wss://#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}/ws/bridge")

      assert {:ok, _state} =
               BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => post.id, "api_key" => k},
                 connect_info: %{uri: uri}
               })
    end
  end

  describe "the join budget (threat-model item 10's /ws/* gap)" do
    test "connect/1 charges the bridge_join budget first, refusing an over-budget address before authorization runs" do
      previous = Application.get_env(:kiln_cms, KilnCMSWeb.RateLimit, [])
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMSWeb.RateLimit, previous) end)

      limits =
        previous |> Keyword.get(:limits, %{}) |> Map.put(:bridge_join, {1, :timer.minutes(1)})

      Application.put_env(:kiln_cms, KilnCMSWeb.RateLimit, Keyword.put(previous, :limits, limits))

      admin = user(:admin)
      post = draft(admin)
      k = key(admin)
      address = KilnCMS.RateLimitHelpers.client_address()
      connect_info = %{peer_data: %{address: address, port: 111, ssl_cert: nil}, x_headers: []}

      assert {:ok, _state} =
               BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => post.id, "api_key" => k},
                 connect_info: connect_info
               })

      # Same address, second attempt: over budget, refused before the api_key
      # is even checked (a bogus key here would also refuse — the budget has
      # to be the reason, so the key stays valid).
      assert :error =
               BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => post.id, "api_key" => k},
                 connect_info: connect_info
               })
    end
  end
end
