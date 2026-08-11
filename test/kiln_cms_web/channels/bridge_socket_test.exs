defmodule KilnCMSWeb.BridgeSocketTest do
  @moduledoc """
  The visual-editing live-preview push socket (#355): connect authorization
  (draft visibility follows the API key) and forwarding of `{:preview_update, …}`
  broadcasts as JSON frames.
  """
  # async: false — one test toggles the global `:visual_editing_enabled` config.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
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

    assert_receive {:preview_update, ^payload}

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

    assert_receive {:preview_update, ^payload}

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
end
