defmodule KilnCMSWeb.CollabChannelTest do
  @moduledoc """
  The collab CRDT relay end-to-end at the channel layer: token-gated socket,
  join replies with the authoritative state + peer count, updates relay to the
  other clients, and the whole surface is inert when the flag is off.
  """
  # async: false — the flag test flips global application env.
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias KilnCMSWeb.CollabSocket

  @endpoint KilnCMSWeb.Endpoint

  defp token, do: Phoenix.Token.sign(@endpoint, "collab", Ash.UUID.generate())

  defp topic, do: "collab:page:#{System.unique_integer([:positive])}"

  defp join!(topic) do
    {:ok, socket} = connect(CollabSocket, %{"token" => token()})
    {:ok, reply, joined} = subscribe_and_join(socket, topic, %{})
    {reply, joined}
  end

  test "sockets demand a valid token" do
    assert :error = connect(CollabSocket, %{"token" => "forged"})
    assert :error = connect(CollabSocket, %{})
  end

  test "clients converge through the channel; late joiners get full state" do
    topic = topic()

    {%{"state" => _empty, "peers" => 1}, sock_a} = join!(topic)
    {%{"peers" => 2}, _sock_b} = join!(topic)

    # A types locally and pushes the binary Yjs update.
    doc_a = Yex.Doc.new()
    doc_a |> Yex.Doc.get_text("block-0") |> Yex.Text.insert(0, "synced!")
    {:ok, update} = Yex.encode_state_as_update(doc_a)

    ref = push(sock_a, "update", %{"update" => Base.encode64(update)})
    assert_reply ref, :ok

    # The other client receives the relay (sender excluded by broadcast_from).
    assert_push "update", %{"update" => relayed}
    assert Base.decode64!(relayed) == update

    # A third client joining later converges from the join reply alone.
    {%{"state" => state, "peers" => 3}, _sock_c} = join!(topic)
    doc_c = Yex.Doc.new()
    :ok = Yex.apply_update(doc_c, Base.decode64!(state))
    assert doc_c |> Yex.Doc.get_text("block-0") |> Yex.Text.to_string() == "synced!"
  end

  test "malformed updates are refused" do
    {_reply, socket} = join!(topic())

    ref = push(socket, "update", %{"update" => "!!! not base64 !!!"})
    assert_reply ref, :error, %{reason: "bad update"}

    ref = push(socket, "update", %{"update" => Base.encode64("not yjs")})
    assert_reply ref, :error, %{reason: "bad update"}
  end

  test "awareness payloads relay verbatim to the other clients" do
    topic = topic()
    {_reply, sock_a} = join!(topic)
    {_reply2, _sock_b} = join!(topic)

    push(sock_a, "awareness", %{"cursor" => %{"anchor" => 3}, "name" => "A"})
    assert_push "awareness", %{"cursor" => %{"anchor" => 3}, "name" => "A"}
  end

  test "a newcomer's awareness_request is relayed so peers re-announce" do
    topic = topic()
    {_reply, _sock_a} = join!(topic)
    {_reply2, sock_b} = join!(topic)

    push(sock_b, "awareness_request", %{})
    assert_push "awareness_request", %{}
  end

  test "joins are refused while the prototype flag is off" do
    Application.put_env(:kiln_cms, :collab_prototype, false)
    on_exit(fn -> Application.put_env(:kiln_cms, :collab_prototype, true) end)

    {:ok, socket} = connect(CollabSocket, %{"token" => token()})
    assert {:error, %{reason: "collab disabled"}} = subscribe_and_join(socket, topic(), %{})
  end
end
