defmodule KilnCMSWeb.DraftWriteKeySocketsTest do
  @moduledoc """
  The `:draft_write` API-key scope (#2273) on the two long-lived socket
  surfaces.

  **Bridge** (`/ws/bridge`, `api_key=`): the only socket a key can reach. It is
  read-only, so the bound is the `Content` read policy: the key streams
  published documents and the drafts it authored, nothing else, and the scope
  survives the periodic re-check's actor reload.

  **Collab** (`/ws/collab`): not reachable with a key at all. Its socket takes a
  `Phoenix.Token` the editor LiveView signs for a signed-in session, and joins
  as that account with NO key metadata, so the key's allowlist is never in
  play; the account's own role decides, and a viewer-tier service account
  joins nothing.
  """
  # async: false — the join test flips the global collab flag, and the
  # re-check test the reauth interval.
  use KilnCMS.DataCase, async: false

  import Phoenix.ChannelTest

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMSWeb.BridgeSocket
  alias KilnCMSWeb.CollabSocket

  @endpoint KilnCMSWeb.Endpoint
  @schema_vsn 3

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dw-sock-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "svc",
      DateTime.add(DateTime.utc_now(), 7, :day),
      %{access: :draft_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp post!(attrs) do
    Ash.Seed.seed!(
      CMS.Post,
      Map.merge(%{title: "P", slug: "dw-sock-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp bridge(post, key),
    do: BridgeSocket.connect(%{params: %{"type" => "post", "id" => post.id, "api_key" => key}})

  setup do
    owner = user(:viewer)
    %{owner: owner, key: mint(owner)}
  end

  describe "bridge" do
    test "streams the key's own draft and published documents", ctx do
      own = post!(%{state: :draft, author_id: ctx.owner.id})
      live = post!(%{state: :published})

      assert {:ok, %{actor: %{id: id}}} = bridge(own, ctx.key)
      assert id == ctx.owner.id
      assert {:ok, _} = bridge(live, ctx.key)
    end

    test "refuses another author's draft, and an in-review document of its own", ctx do
      theirs = post!(%{state: :draft, author_id: user(:editor).id})
      reviewed = post!(%{state: :in_review, author_id: ctx.owner.id})

      assert :error = bridge(theirs, ctx.key)
      assert :error = bridge(reviewed, ctx.key)
    end

    test "the scope survives the periodic re-check, which closes the stream once the draft moves on",
         ctx do
      previous = Application.get_env(:kiln_cms, :socket_reauth_interval_ms)
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 50)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :socket_reauth_interval_ms, previous),
          else: Application.delete_env(:kiln_cms, :socket_reauth_interval_ms)
      end)

      own = post!(%{state: :draft, author_id: ctx.owner.id})
      {:ok, state} = bridge(own, ctx.key)
      {:ok, state} = BridgeSocket.init(state)

      # The reload carries the key metadata across, so the own-draft rule still
      # applies (a bare viewer would be refused here and the stream would stop).
      assert_receive :reauthorize, 1_000
      assert {:ok, state} = BridgeSocket.handle_info(:reauthorize, state)

      Ash.Seed.update!(own, %{state: :in_review})
      assert_receive :reauthorize, 1_000
      assert {:stop, :normal, _} = BridgeSocket.handle_info(:reauthorize, state)
    end
  end

  describe "collab" do
    setup do
      previous = Application.get_env(:kiln_cms, :collab_prototype)
      Application.put_env(:kiln_cms, :collab_prototype, true)
      on_exit(fn -> Application.put_env(:kiln_cms, :collab_prototype, previous) end)
      :ok
    end

    test "a key is not a credential for the socket", ctx do
      assert :error = connect(CollabSocket, %{"token" => ctx.key})
      assert :error = connect(CollabSocket, %{"api_key" => ctx.key})
    end

    test "the key owner's own account cannot join the room of its own draft", ctx do
      own = post!(%{state: :draft, author_id: ctx.owner.id})
      token = Phoenix.Token.sign(@endpoint, "collab", ctx.owner.id)
      {:ok, socket} = connect(CollabSocket, %{"token" => token})

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket, "collab:post:#{own.id}", %{"vsn" => @schema_vsn})
    end
  end
end
