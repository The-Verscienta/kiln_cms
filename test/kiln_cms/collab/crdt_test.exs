defmodule KilnCMS.Collab.CrdtTest do
  @moduledoc """
  The BEAM-authoritative Yjs doc server (collab CRDT prototype): clients
  converge through it regardless of arrival order, and concurrent divergent
  edits merge without loss.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Collab.Crdt

  defp doc_key, do: "collab:test:#{System.unique_integer([:positive])}"

  defp text(doc), do: doc |> Yex.Doc.get_text("field") |> Yex.Text.to_string()

  test "ensure_server is idempotent per key" do
    key = doc_key()
    {:ok, a} = Crdt.ensure_server(key)
    {:ok, b} = Crdt.ensure_server(key)
    assert a == b

    {:ok, other} = Crdt.ensure_server(doc_key())
    refute a == other
  end

  test "a late joiner receives everything applied so far" do
    {:ok, server} = Crdt.ensure_server(doc_key())

    {initial, 1} = Crdt.attach(server)

    # First client seeds some text and pushes its update.
    doc_a = Yex.Doc.new()
    :ok = Yex.apply_update(doc_a, initial)
    doc_a |> Yex.Doc.get_text("field") |> Yex.Text.insert(0, "hello collab")
    {:ok, update_a} = Yex.encode_state_as_update(doc_a)
    :ok = Crdt.apply_update(server, update_a)

    # Second client (a different process — attach counts distinct pids).
    {state, 2} = Task.await(Task.async(fn -> Crdt.attach(server) end))
    doc_b = Yex.Doc.new()
    :ok = Yex.apply_update(doc_b, state)

    assert text(doc_b) == "hello collab"
  end

  test "concurrent divergent edits merge conflict-free" do
    {:ok, server} = Crdt.ensure_server(doc_key())
    {initial, 1} = Crdt.attach(server)

    # Two clients start from the same (empty) state…
    doc_a = Yex.Doc.new()
    doc_b = Yex.Doc.new()
    :ok = Yex.apply_update(doc_a, initial)
    :ok = Yex.apply_update(doc_b, initial)

    # …type divergently while "offline"…
    doc_a |> Yex.Doc.get_text("field") |> Yex.Text.insert(0, "from A ")
    doc_b |> Yex.Doc.get_text("field") |> Yex.Text.insert(0, "from B ")

    {:ok, update_a} = Yex.encode_state_as_update(doc_a)
    {:ok, update_b} = Yex.encode_state_as_update(doc_b)

    # …and push in either order: the authoritative doc merges both.
    :ok = Crdt.apply_update(server, update_b)
    :ok = Crdt.apply_update(server, update_a)

    merged = Yex.Doc.new()
    :ok = Yex.apply_update(merged, Crdt.state_update(server))

    assert text(merged) =~ "from A "
    assert text(merged) =~ "from B "

    # Both clients converge to the identical merged text.
    :ok = Yex.apply_update(doc_a, Crdt.state_update(server))
    :ok = Yex.apply_update(doc_b, Crdt.state_update(server))
    assert text(doc_a) == text(doc_b)
    assert text(doc_a) == text(merged)
  end

  test "garbage updates are rejected without crashing the doc" do
    {:ok, server} = Crdt.ensure_server(doc_key())

    assert {:error, _reason} = Crdt.apply_update(server, "not a yjs update")

    # Server is still alive and usable.
    assert {_state, 1} = Crdt.attach(server)
  end
end
