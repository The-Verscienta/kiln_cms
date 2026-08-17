defmodule KilnCMSWeb.SocketEventBudgetTest do
  @moduledoc """
  The per-connection frame budget's own mechanics (#1305): keyed on the
  transport pid and nothing else, one bucket per socket family, refused when
  spent. `KilnCMSWeb.CollabChannelTest` pins the wiring — that the channel
  actually charges it, and where.

  `config/test.exs` raises `:collab_event` to a million so the collab suite can
  push freely; the tests here lower it back through the same application env
  `RateLimit.limits/0` reads, and restore it after. `async: false` for that.
  """
  use ExUnit.Case, async: false

  alias KilnCMSWeb.RateLimit
  alias KilnCMSWeb.SocketEventBudget

  @bucket :collab_event

  setup do
    previous = Application.get_env(:kiln_cms, RateLimit, [])
    on_exit(fn -> Application.put_env(:kiln_cms, RateLimit, previous) end)
    :ok
  end

  defp put_limit(limit) do
    current = Application.get_env(:kiln_cms, RateLimit, [])

    limits =
      current |> Keyword.get(:limits, %{}) |> Map.put(@bucket, {limit, :timer.minutes(1)})

    Application.put_env(:kiln_cms, RateLimit, Keyword.put(current, :limits, limits))
  end

  # A socket as a channel sees it: the transport pid is the websocket, and it
  # is what the key is built from. Every other field is irrelevant here, and a
  # fresh throwaway pid per "connection" keeps tests from sharing a window.
  defp socket_on(transport_pid), do: %Phoenix.Socket{transport_pid: transport_pid}

  defp fresh_pid, do: spawn(fn -> :ok end)

  test "the key is the transport pid, spelled with its serial" do
    pid = self()
    key = SocketEventBudget.connection_key(pid)

    assert key == "conn:" <> List.to_string(:erlang.pid_to_list(pid))
    assert String.starts_with?(key, "conn:<")
  end

  test "frames are allowed up to the limit and refused past it, per connection" do
    put_limit(2)
    socket = socket_on(fresh_pid())

    assert :ok = SocketEventBudget.charge(@bucket, socket)
    assert :ok = SocketEventBudget.charge(@bucket, socket)
    assert {:deny, retry_after_ms} = SocketEventBudget.charge(@bucket, socket)
    assert is_integer(retry_after_ms) and retry_after_ms >= 0
  end

  test "two connections do not share a budget, even for the same user" do
    # THE property behind the key choice: an office of editors on one NAT (or
    # one editor with two tabs) must not spend each other's frames — the join
    # budgets already key on the address; this one keys on the socket.
    put_limit(1)
    a = socket_on(fresh_pid())
    b = socket_on(fresh_pid())

    assert :ok = SocketEventBudget.charge(@bucket, a)
    assert {:deny, _} = SocketEventBudget.charge(@bucket, a)
    # `b` carries the same assigns a second tab of the same user would; only
    # its transport differs, and that is enough for a fresh budget.
    assert :ok = SocketEventBudget.charge(@bucket, %{b | assigns: a.assigns})
  end

  test "every channel and every rejoin over one connection spends the same budget" do
    # The amplifier this closes: a channel stopped for flooding rejoins over the
    # SAME websocket, so it must land on the same spent key — a fresh channel
    # pid must not mean a fresh budget.
    put_limit(1)
    transport = fresh_pid()
    first_channel = %{socket_on(transport) | channel_pid: fresh_pid(), topic: "collab:page:a"}
    rejoined = %{socket_on(transport) | channel_pid: fresh_pid(), topic: "collab:page:a"}
    other_room = %{socket_on(transport) | channel_pid: fresh_pid(), topic: "collab:page:b"}

    assert :ok = SocketEventBudget.charge(@bucket, first_channel)
    assert {:deny, _} = SocketEventBudget.charge(@bucket, rejoined)
    assert {:deny, _} = SocketEventBudget.charge(@bucket, other_room)
  end

  test "the shipped ceiling is a per-connection flood ceiling, not a usage cap" do
    # The number `docs/threat-model.md` item 10 states. Sized against one human
    # on one tab: a keystroke is two frames and a mouse-drag selection
    # re-announces the caret at the browser's event rate, so a busy minute is a
    # few thousand frames — the ceiling has to clear that with room, and still
    # be something a script reaches in seconds. Pinned to a range, so retuning
    # is a deliberate change here as well as in `RateLimit`.
    assert {limit, scale} = RateLimit.default_limits()[@bucket]
    assert scale == :timer.minutes(1)
    assert limit in 3_000..12_000
  end
end
