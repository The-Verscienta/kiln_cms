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

    assert state == %{type: "post", id: post.id}

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
end
