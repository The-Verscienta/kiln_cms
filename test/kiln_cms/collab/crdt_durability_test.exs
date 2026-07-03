defmodule KilnCMS.Collab.CrdtDurabilityTest do
  @moduledoc """
  Y.Doc durability: a doc server's CRDT state survives its own shutdown (idle
  stop or deploy) via `collab_doc_states` — restored lazily when the document
  is next opened — and dead sessions are pruned.
  """
  # async: false — flips the (global) persistence config; sync tests also run
  # the SQL sandbox in shared mode, so the DocServer process can query freely.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Collab.Crdt
  alias KilnCMS.Repo

  setup do
    Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: true)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false) end)
    :ok
  end

  defp doc_key, do: "collab:test:dur#{System.unique_integer([:positive])}"

  defp text_of(update) do
    doc = Yex.Doc.new()
    :ok = Yex.apply_update(doc, update)
    doc |> Yex.Doc.get_text("field") |> Yex.Text.to_string()
  end

  defp update_with_text(base_state, text) do
    doc = Yex.Doc.new()
    :ok = Yex.apply_update(doc, base_state)
    doc |> Yex.Doc.get_text("field") |> Yex.Text.insert(0, text)
    {:ok, update} = Yex.encode_state_as_update(doc)
    update
  end

  test "a gracefully stopped doc restores on next open" do
    key = doc_key()

    {:ok, server} = Crdt.ensure_server(key)
    {initial, 1} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, update_with_text(initial, "survives restarts"))

    # Graceful shutdown (idle stop / deploy) persists via terminate.
    :ok = GenServer.stop(server)
    refute Process.alive?(server)

    {:ok, revived} = Crdt.ensure_server(key)
    refute revived == server
    {restored, 1} = Crdt.attach(revived)
    assert text_of(restored) == "survives restarts"
  end

  test "a dirty doc checkpoints without shutting down" do
    key = doc_key()

    {:ok, server} = Crdt.ensure_server(key)
    {initial, 1} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, update_with_text(initial, "checkpointed"))

    # Force the scheduled flush now rather than waiting out the interval.
    send(server, :checkpoint)
    _sync = Crdt.state_update(server)

    %{rows: [[stored]]} =
      Repo.query!("SELECT state FROM collab_doc_states WHERE doc_key = $1", [key])

    assert text_of(stored) == "checkpointed"
  end

  test "stale doc states are pruned when a document is opened" do
    dead_key = doc_key()

    Repo.query!(
      "INSERT INTO collab_doc_states (doc_key, state, updated_at) VALUES ($1, $2, now() - interval '45 days')",
      [dead_key, <<0, 0>>]
    )

    # Opening any document triggers the restore-time prune.
    {:ok, server} = Crdt.ensure_server(doc_key())
    {_state, 1} = Crdt.attach(server)

    assert %{rows: []} =
             Repo.query!("SELECT 1 FROM collab_doc_states WHERE doc_key = $1", [dead_key])
  end

  test "persistence off means no rows and no restore (test-suite default)" do
    Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false)

    key = doc_key()
    {:ok, server} = Crdt.ensure_server(key)
    {initial, 1} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, update_with_text(initial, "ephemeral"))
    :ok = GenServer.stop(server)

    assert %{rows: []} =
             Repo.query!("SELECT 1 FROM collab_doc_states WHERE doc_key = $1", [key])
  end
end
