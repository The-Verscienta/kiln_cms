defmodule KilnCMS.Governance.SystemActorAuthorizationTest do
  @moduledoc """
  What the governance subsystem's own bookkeeping is *authorized* to do, now
  that the anchor chain, checkpoint minting and the dashboard's entitlement
  trail run as `KilnCMS.Governance.system/0` instead of `authorize?: false`
  (#1659, batch 2).

  Two halves, and both are the point:

    * **Grant and refusal.** Every resource that admits the system actor has a
      positive next to a negative: the chain reads a document's anchors but not
      the whole table; the checkpoint worker writes and re-reads checkpoints and
      entries, and a person below admin still gets nothing. Reads assert on the
      ROW, never on `{:ok, _}`, because a refused read under a filter policy
      comes back `{:ok, []}`.
    * **Failing closed.** Each governance read backs a decision ("never
      anchored", "never witnessed", "nothing waiting to publish", "no earlier
      checkpoint") that a silently empty read would answer the permissive way.
      With the grant taken away (`Governance.with_actor(nil, ...)`), every one
      of them must raise instead.

  Removing any `KilnCMS.Checks.SystemActor` clause, any `forbid_unless`
  narrowing, or any `authorize_with: :error` at a call site must turn a test
  here red.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  alias KilnCMS.CMS
  alias KilnCMS.Governance
  alias KilnCMS.Governance.Chain
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp system, do: Governance.system()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gsa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # A published page: the publish hook mints its first anchor as the system.
  defp published_page do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Governed", slug: "gsa-#{uniq()}"}, actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # A refused grant must RAISE out of the call site, not answer `[]`.
  defmacrop refused(do: block) do
    quote do
      assert_raise Ash.Error.Forbidden, fn ->
        Governance.with_actor(nil, fn -> unquote(block) end)
      end
    end
  end

  test "Governance.system/0 is a system actor labelled :governance" do
    assert %SystemActor{subsystem: :governance} = Governance.system()
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Governance.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :governance} = Governance.system()
  end

  describe "HistoryAnchor: mint and read back one document's chain, never list the table" do
    test "publishing mints an anchor as the system, and the chain reads it back" do
      page = published_page()

      assert [%{source_id: source_id, sequence: 1} = anchor] =
               CMS.list_history_anchors_for!("page", page.id,
                 actor: system(),
                 tenant: page.org_id
               )

      assert source_id == page.id
      assert anchor.id in ids(Chain.anchors("page", page.id, page.org_id))
    end

    test "the system actor creates an anchor directly" do
      page = published_page()

      assert {:ok, %{sequence: 99}} =
               CMS.create_history_anchor(
                 %{
                   resource_type: "page",
                   source_id: page.id,
                   chain_hash: "h",
                   version_count: 0,
                   sequence: 99
                 },
                 actor: system(),
                 tenant: page.org_id
               )
    end

    test "the plain read is not admitted, not even to the system actor" do
      page = published_page()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(CMS.HistoryAnchor,
                 actor: system(),
                 tenant: page.org_id,
                 authorize_with: :error
               )
    end

    test "a person below admin reads and writes nothing" do
      page = published_page()
      editor = user(:editor)

      assert [] =
               CMS.list_history_anchors_for!("page", page.id,
                 actor: editor,
                 tenant: page.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_history_anchor(
                 %{
                   resource_type: "page",
                   source_id: page.id,
                   chain_hash: "h",
                   version_count: 0,
                   sequence: 98
                 },
                 actor: editor,
                 tenant: page.org_id
               )
    end

    test "fails closed: without the grant the chain raises rather than reading 'never anchored'" do
      page = published_page()

      refused(do: Chain.anchors("page", page.id, page.org_id))
    end

    test "fails closed: a promotion re-key without the grant raises rather than moving nothing" do
      page = published_page()

      refused(do: Chain.repoint_after_promotion(CMS.Page, [page.id], "page", "gsa", page.org_id))
    end
  end

  describe "ChainCheckpoint and ChainCheckpointEntry: the checkpoint worker's own tables" do
    setup do
      page = published_page()
      assert {:ok, checkpoint} = Checkpoint.mint(page.org_id)
      %{page: page, checkpoint: checkpoint}
    end

    test "the worker mints a checkpoint and reads it back", %{page: page, checkpoint: checkpoint} do
      assert checkpoint.id in ids(Checkpoint.recent(page.org_id))
      assert Checkpoint.latest(page.org_id).id == checkpoint.id

      # The test witness is `None`, so every checkpoint stays in the retry queue.
      assert checkpoint.id in ids(Checkpoint.unwitnessed(page.org_id))

      assert {:ok, %{id: id}} =
               Ash.get(CMS.ChainCheckpoint, checkpoint.id,
                 actor: system(),
                 tenant: page.org_id
               )

      assert id == checkpoint.id
    end

    test "the worker records a publication result", %{page: page, checkpoint: checkpoint} do
      assert {:ok, %{witness_error: "sink down"}} =
               CMS.record_checkpoint_publication(checkpoint, %{witness_error: "sink down"},
                 actor: system(),
                 tenant: page.org_id
               )
    end

    test "the worker writes entries and verification reads them back",
         %{page: page, checkpoint: checkpoint} do
      assert [%{source_id: source_id} = entry] = Checkpoint.entries(checkpoint, page.org_id)
      assert source_id == page.id

      assert entry.id in ids(
               CMS.list_checkpoint_entries_for!("page", page.id,
                 actor: system(),
                 tenant: page.org_id
               )
             )

      assert {:ok, %{id: witnessed}, _attestation} =
               Checkpoint.witnessed_head("page", page.id, page.org_id)

      assert witnessed == entry.id
    end

    test "the system actor creates an entry directly", %{page: page, checkpoint: checkpoint} do
      assert {:ok, %{head_sequence: 7}} =
               CMS.create_chain_checkpoint_entry(
                 %{
                   checkpoint_id: checkpoint.id,
                   checkpoint_sequence: checkpoint.sequence,
                   resource_type: "page",
                   source_id: Ecto.UUID.generate(),
                   head_anchor_id: Ecto.UUID.generate(),
                   head_sequence: 7,
                   chain_hash: "h",
                   version_count: 1
                 },
                 actor: system(),
                 tenant: page.org_id
               )
    end

    test "an entry's plain read is not admitted, not even to the system actor",
         %{page: page} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(CMS.ChainCheckpointEntry,
                 actor: system(),
                 tenant: page.org_id,
                 authorize_with: :error
               )
    end

    test "a person below admin reads nothing", %{page: page, checkpoint: checkpoint} do
      editor = user(:editor)

      assert [] = CMS.list_chain_checkpoints!(actor: editor, tenant: page.org_id)
      assert [] = CMS.list_unwitnessed_checkpoints!(actor: editor, tenant: page.org_id)

      assert [] =
               CMS.list_checkpoint_entries_in!(checkpoint.id, actor: editor, tenant: page.org_id)

      assert [] =
               CMS.list_checkpoint_entries_for!("page", page.id,
                 actor: editor,
                 tenant: page.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.record_checkpoint_publication(checkpoint, %{witness_error: "x"},
                 actor: editor,
                 tenant: page.org_id
               )
    end

    test "fails closed: without the grant, no checkpoint read comes back empty",
         %{page: page, checkpoint: checkpoint} do
      # "No earlier checkpoint" would restart the chain at sequence 1.
      refused(do: Checkpoint.recent(page.org_id))
      # "Nothing waiting" would show a witness outage as healthy.
      refused(do: Checkpoint.unwitnessed(page.org_id))
      # An empty entry list would publish an empty commitment.
      refused(do: Checkpoint.entries(checkpoint, page.org_id))
    end

    test "fails closed: without the grant a witnessed document is :unreadable, never :none",
         %{page: page} do
      assert :unreadable =
               Governance.with_actor(nil, fn ->
                 Checkpoint.witnessed_head("page", page.id, page.org_id)
               end)
    end
  end

  describe "the dashboard's entitlement trail" do
    test "fails closed: without the grant it raises rather than showing an empty trail" do
      refused(do: Governance.entitlement_index(KilnCMS.Accounts.default_org_id()))
    end
  end
end
