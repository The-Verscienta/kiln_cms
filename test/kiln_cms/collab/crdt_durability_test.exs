defmodule KilnCMS.Collab.CrdtDurabilityTest do
  @moduledoc """
  Y.Doc durability: a doc server's CRDT state survives its own shutdown (idle
  stop or deploy) via `collab_doc_states` — restored lazily when the document
  is next opened — and dead sessions are pruned.
  """
  # async: false — flips the (global) persistence config; sync tests also run
  # the SQL sandbox in shared mode, so the DocServer process can query freely.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Collab.Crdt
  alias KilnCMS.Collab.Crdt.DocServer
  alias KilnCMS.Repo

  # Decodes to an error, not a doc; the precondition is asserted below.
  @corrupt <<0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 1, 2, 3>>

  setup do
    # Both keys, so materialize stays off here and goes back to the test
    # config's value after (config/test.exs); a one-key put_env drops the other.
    Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: true, materialize?: false)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: false)
    end)

    :ok
  end

  defp doc_key, do: "collab:test:dur#{System.unique_integer([:positive])}"

  defp org_id, do: KilnCMS.Accounts.default_org_id()

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

    {:ok, server} = Crdt.ensure_server(key, org_id())
    {initial, 1} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, update_with_text(initial, "survives restarts"))

    # Graceful shutdown (idle stop / deploy) persists via terminate.
    :ok = GenServer.stop(server)
    refute Process.alive?(server)

    {:ok, revived} = Crdt.ensure_server(key, org_id())
    refute revived == server
    {restored, 1} = Crdt.attach(revived)
    assert text_of(restored) == "survives restarts"
  end

  test "a dirty doc checkpoints without shutting down" do
    key = doc_key()

    {:ok, server} = Crdt.ensure_server(key, org_id())
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
    {:ok, server} = Crdt.ensure_server(doc_key(), org_id())
    {_state, 1} = Crdt.attach(server)

    assert %{rows: []} =
             Repo.query!("SELECT 1 FROM collab_doc_states WHERE doc_key = $1", [dead_key])
  end

  test "persistence off means no rows and no restore (test-suite default)" do
    Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: false)

    key = doc_key()
    {:ok, server} = Crdt.ensure_server(key, org_id())
    {initial, 1} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, update_with_text(initial, "ephemeral"))
    :ok = GenServer.stop(server)

    assert %{rows: []} =
             Repo.query!("SELECT 1 FROM collab_doc_states WHERE doc_key = $1", [key])
  end

  describe "a corrupt stored state" do
    setup do
      # Without this the tests below could pass on bytes that decode fine.
      assert {:error, _} = Yex.apply_update(Yex.Doc.new(), @corrupt)
      key = doc_key()

      Repo.query!(
        "INSERT INTO collab_doc_states (doc_key, state, updated_at) VALUES ($1, $2, now())",
        [key, @corrupt]
      )

      %{key: key}
    end

    test "restores as an empty doc instead of crashing every attach", %{key: key} do
      {:ok, server} = Crdt.ensure_server(key, org_id())

      log =
        capture_log(fn ->
          {state, 1} = Crdt.attach(server)
          send(self(), {:state, state})
        end)

      assert_received {:state, state}
      assert Process.alive?(server)
      assert text_of(state) == ""

      # A second client joins the same live room.
      parent = self()

      spawn(fn ->
        send(parent, {:second, Crdt.attach(server)})

        receive do
          :never -> :ok
        end
      end)

      assert_receive {:second, {_state, 2}}

      assert log =~ "corrupt"
      assert log =~ key
      assert log =~ "starts empty"
    end

    test "the corrupt bytes are quarantined, not overwritten", %{key: key} do
      {:ok, server} = Crdt.ensure_server(key, org_id())
      capture_log(fn -> send(self(), {:state, Crdt.attach(server)}) end)
      assert_received {:state, {initial, 1}}

      assert %{rows: []} =
               Repo.query!("SELECT 1 FROM collab_doc_states WHERE doc_key = $1", [key])

      quarantined = fn ->
        Repo.query!(
          "SELECT doc_key, state FROM collab_doc_states WHERE doc_key LIKE 'corrupt:' || $1 || ':%'",
          [key]
        ).rows
      end

      assert [[quarantine_key, @corrupt]] = quarantined.()
      assert quarantine_key =~ ~r/\Acorrupt:#{key}:\d+:[0-9a-f]+\z/

      # Later checkpoints write a fresh, valid row under the real key and leave
      # the quarantined one alone.
      :ok = Crdt.apply_update(server, update_with_text(initial, "fresh"))
      :ok = GenServer.stop(server)

      {:ok, revived} = Crdt.ensure_server(key, org_id())
      {restored, 1} = Crdt.attach(revived)
      assert text_of(restored) == "fresh"
      assert [[^quarantine_key, @corrupt]] = quarantined.()
    end

    test "quarantining stale bytes leaves a row another server already replaced", %{key: key} do
      # Another server for the same key read the same bytes, then checkpointed a
      # valid state over them before this one got to its quarantine.
      doc = Yex.Doc.new()
      doc |> Yex.Doc.get_text("field") |> Yex.Text.insert(0, "valid")
      {:ok, valid} = Yex.encode_state_as_update(doc)

      Repo.query!("UPDATE collab_doc_states SET state = $2 WHERE doc_key = $1", [key, valid])

      assert DocServer.quarantine(key, @corrupt) == :gone

      assert %{rows: [[^valid]]} =
               Repo.query!("SELECT state FROM collab_doc_states WHERE doc_key = $1", [key])

      assert %{rows: []} =
               Repo.query!(
                 "SELECT 1 FROM collab_doc_states WHERE doc_key LIKE 'corrupt:' || $1 || ':%'",
                 [key]
               )
    end

    test "a restore that finds the row replaced restores the replacement instead", %{key: key} do
      # This server read corrupt bytes; by its quarantine another server had
      # checkpointed a valid state. Starting empty would let this room's next
      # checkpoint overwrite that state, so the row as it is now is restored.
      doc = Yex.Doc.new()
      doc |> Yex.Doc.get_text("field") |> Yex.Text.insert(0, "valid")
      {:ok, valid} = Yex.encode_state_as_update(doc)

      Repo.query!("UPDATE collab_doc_states SET state = $2 WHERE doc_key = $1", [key, valid])

      {result, log} = with_log(fn -> DocServer.restore_doc(key, @corrupt) end)
      assert {:ok, restored} = result
      assert restored |> Yex.Doc.get_text("field") |> Yex.Text.to_string() == "valid"
      assert log =~ "another server already replaced"

      assert %{rows: [[^valid]]} =
               Repo.query!("SELECT state FROM collab_doc_states WHERE doc_key = $1", [key])
    end
  end
end
