defmodule KilnCMSWeb.SocketEventBudgetTest do
  @moduledoc """
  The per-account frame budget's own mechanics (#1305): keyed on the actor
  the socket authenticated as (falling back to its transport), one bucket per
  socket family, refused when spent, and a refusal that closes the connection
  rather than the channel. `KilnCMSWeb.CollabChannelTest` pins the wiring —
  that the channel actually charges it, and where.

  `config/test.exs` raises `:collab_event` to a million so the collab suite can
  push freely; the tests here lower it back through the same application env
  `RateLimit.limits/0` reads, and restore it after. `async: false` for that.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.RateLimitHelpers
  alias KilnCMSWeb.RateLimit
  alias KilnCMSWeb.SocketEventBudget

  @moduletag :capture_log

  @bucket :collab_event

  setup do
    RateLimitHelpers.restore_limits_on_exit()
  end

  defp put_limit(limit), do: RateLimitHelpers.put_limit(@bucket, limit)

  # A socket as a channel sees it: the actor the connect resolved, and the
  # transport pid the websocket runs in. `topic` only feeds the debug line.
  defp socket_for(actor_id, transport_pid \\ self()) do
    %Phoenix.Socket{
      assigns: %{actor: %{id: actor_id}},
      transport_pid: transport_pid,
      topic: "collab:page:x"
    }
  end

  defp actor_id, do: Ash.UUID.generate()

  defp fresh_pid, do: spawn(fn -> :ok end)

  test "the key is the account; a socket with no actor falls back to its transport" do
    id = actor_id()
    assert SocketEventBudget.key(socket_for(id)) == "actor:" <> id

    anonymous = %Phoenix.Socket{transport_pid: self()}
    assert SocketEventBudget.key(anonymous) =~ ~r/^conn:<\d+\.\d+\.\d+>$/
  end

  test "frames are allowed up to the limit and refused past it" do
    put_limit(2)
    socket = socket_for(actor_id())

    assert :allow = SocketEventBudget.charge(@bucket, socket)
    assert :allow = SocketEventBudget.charge(@bucket, socket)
    assert {:deny, retry_after_ms} = SocketEventBudget.charge(@bucket, socket)
    assert is_integer(retry_after_ms) and retry_after_ms >= 0
  end

  test "two accounts do not share a budget, even over one connection" do
    # An office of editors on one NAT — or, at the transport level, two
    # actors whose sockets happen to run in one process — must not spend each
    # other's frames.
    put_limit(1)
    a = socket_for(actor_id())
    b = socket_for(actor_id())

    assert :allow = SocketEventBudget.charge(@bucket, a)
    assert {:deny, _} = SocketEventBudget.charge(@bucket, a)
    assert :allow = SocketEventBudget.charge(@bucket, b)
  end

  test "a reconnect, a second tab or a second room does not mint a fresh budget" do
    # THE property behind keying on the account and not the connection: the
    # honest recovery from a refusal is a reconnect, and a flooder's cheapest
    # move is one too — a fresh transport pid must land on the same spent key.
    put_limit(1)
    id = actor_id()
    first_tab = socket_for(id, fresh_pid())
    reconnected = socket_for(id, fresh_pid())
    other_room = %{socket_for(id, first_tab.transport_pid) | topic: "collab:page:y"}

    assert :allow = SocketEventBudget.charge(@bucket, first_tab)
    assert {:deny, _} = SocketEventBudget.charge(@bucket, reconnected)
    assert {:deny, _} = SocketEventBudget.charge(@bucket, other_room)
  end

  test "close_connection/1 tells the transport to disconnect, the way eviction does" do
    # The test process stands in for the websocket transport, so the message
    # the transport would act on lands here. Same shape `SessionEviction`
    # broadcasts (#675): `Phoenix.Socket` closes with code 1001 on it, which
    # phoenix.js reconnects from — the only refusal it recovers from.
    socket = socket_for(actor_id(), self())

    assert :ok = SocketEventBudget.close_connection(socket)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 2_000
  end

  test "the shipped ceiling is a per-account flood ceiling, not a usage cap" do
    # The number `docs/threat-model.md` item 10 states. Sized against one human
    # given what the client emits — a Yjs update per keystroke and awareness
    # coalesced to ~10/s (`assets/js/collab.js`), so a furious minute is well
    # under 2,000 frames — and reached by a script in seconds. Pinned to a
    # range, so retuning is a deliberate change here as well as in `RateLimit`.
    assert {limit, scale} = RateLimit.default_limits()[@bucket]
    assert scale == :timer.minutes(1)
    assert limit in 3_000..12_000
  end
end
