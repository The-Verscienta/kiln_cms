defmodule KilnCMS.Collab.CrdtWritebackTest do
  @moduledoc """
  The DocServer's two durability paths together (#2756): the database
  checkpoint (`collab_doc_states`) and the write-back of converged prose into
  the record's blocks. Each is pending on its own flag, cleared by a different
  event, so an update must leave both pending.

  Also what a corrupt stored state may and may not do to the record.
  """
  # async: false — flips the global `KilnCMS.Collab.Crdt` config; sync tests
  # also run the SQL sandbox in shared mode, so the DocServer can query freely.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.CMS
  alias KilnCMS.Collab.Crdt
  alias KilnCMS.Collab.Crdt.Materializer
  alias KilnCMS.Repo

  # Decodes to an error, not a doc; the precondition is asserted below.
  @corrupt <<0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 1, 2, 3>>

  setup do
    Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: true, materialize?: true)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: false)
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "wb-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp draft_page!(actor) do
    CMS.create_page!(
      %{
        title: "Writeback",
        slug: "wb-#{System.unique_integer([:positive])}",
        blocks: [
          %{"_type" => "heading", "text" => "Keep me"},
          %{"_type" => "rich_text", "body" => pt("stored")}
        ]
      },
      actor: actor
    )
  end

  defp pt(text) do
    [
      %{
        "_type" => "block",
        "_key" => "b0",
        "style" => "normal",
        "children" => [%{"_type" => "span", "text" => text, "marks" => []}],
        "markDefs" => []
      }
    ]
  end

  defp prose(block), do: PortableText.to_plain_text(block.body)

  defp rich_block(page), do: Enum.find(page.blocks, &(&1.type == :rich_text)).value

  defp page_prose(page, actor), do: prose(rich_block(CMS.get_page!(page.id, actor: actor)))

  # An update appending a paragraph holding `text` to the block's fragment, as
  # y-prosemirror would.
  defp paragraph_update(base_state, fragment_name, text) do
    doc = Yex.Doc.new()
    :ok = Yex.apply_update(doc, base_state)
    frag = Yex.Doc.get_xml_fragment(doc, fragment_name)

    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("paragraph", [Yex.XmlTextPrelim.from(text)])
    )

    {:ok, update} = Yex.encode_state_as_update(doc)
    update
  end

  # Attach a disposable client process and return a fun that detaches it.
  defp attach_client(server) do
    parent = self()

    pid =
      spawn(fn ->
        {_state, _n} = Crdt.attach(server)
        send(parent, :attached)

        receive do
          :leave -> :ok
        end
      end)

    # Not the 100 ms default: with persistence on, the first attach restores
    # (prune, read, maybe quarantine) before it replies.
    assert_receive :attached, 5_000
    fn -> send(pid, :leave) end
  end

  defp await(fun) do
    KilnCMS.Test.Eventually.eventually(fun, message: "condition never held")
    :ok
  end

  defp stored_row(key) do
    case Repo.query!("SELECT state FROM collab_doc_states WHERE doc_key = $1", [key]) do
      %{rows: [[stored]]} -> stored
      %{rows: []} -> nil
    end
  end

  defp corrupt_row!(key) do
    Repo.query!(
      "INSERT INTO collab_doc_states (doc_key, state, updated_at) VALUES ($1, $2, now())",
      [key, @corrupt]
    )
  end

  # Client A types "one" and leaves: the write-back runs, the checkpoint is
  # still pending. Then client B joins inside the checkpoint window and types
  # "two". Returns B's detach fun and the server.
  defp rejoin_within_checkpoint_window(page, actor) do
    key = "collab:page:#{page.id}"
    fragment = "block-#{rich_block(page).id}"
    {:ok, server} = Crdt.ensure_server(key, page.org_id)

    leave_a = attach_client(server)
    :ok = Crdt.apply_update(server, paragraph_update(Crdt.state_update(server), fragment, "one"))
    leave_a.()

    await(fn -> page_prose(page, actor) =~ "one" end)
    # No row yet: the checkpoint A's update scheduled has not fired.
    assert stored_row(key) == nil

    leave_b = attach_client(server)
    :ok = Crdt.apply_update(server, paragraph_update(Crdt.state_update(server), fragment, "two"))

    {server, leave_b}
  end

  test "a client who rejoins before the pending checkpoint still reaches the record, on :DOWN" do
    actor = admin()
    page = draft_page!(actor)

    {server, leave_b} = rejoin_within_checkpoint_window(page, actor)
    leave_b.()

    # Used to time out: B's update found `dirty?` already set and never marked
    # the write-back pending, so B's departure materialized nothing.
    await(fn -> page_prose(page, actor) =~ "two" end)
    assert page_prose(page, actor) =~ "one"

    :ok = GenServer.stop(server)
  end

  test "a client still attached at shutdown reaches the record through terminate" do
    actor = admin()
    page = draft_page!(actor)

    {server, _leave_b} = rejoin_within_checkpoint_window(page, actor)

    # Deploy path: B is still attached when the server goes down.
    :ok = GenServer.stop(server)

    await(fn -> page_prose(page, actor) =~ "two" end)
  end

  test "the checkpoint still persists after a write-back cleared its own flag" do
    actor = admin()
    page = draft_page!(actor)
    key = "collab:page:#{page.id}"
    fragment = "block-#{rich_block(page).id}"

    {server, leave_b} = rejoin_within_checkpoint_window(page, actor)
    leave_b.()
    await(fn -> page_prose(page, actor) =~ "two" end)

    # Force the scheduled flush now rather than waiting out the interval.
    send(server, :checkpoint)
    _sync = Crdt.state_update(server)

    doc = Yex.Doc.new()
    :ok = Yex.apply_update(doc, stored_row(key))
    text = doc |> Materializer.fragment_body(fragment) |> PortableText.to_plain_text()
    assert text =~ "one"
    assert text =~ "two"

    :ok = GenServer.stop(server)
  end

  describe "a corrupt stored state" do
    setup do
      # Without this the tests below could pass on bytes that decode fine.
      assert {:error, _} = Yex.apply_update(Yex.Doc.new(), @corrupt)
      :ok
    end

    test "never wipes the record" do
      actor = admin()
      page = draft_page!(actor)
      key = "collab:page:#{page.id}"
      corrupt_row!(key)

      capture_log(fn ->
        {:ok, server} = Crdt.ensure_server(key, page.org_id)
        leave = attach_client(server)
        leave.()
        :ok = GenServer.stop(server)
      end)

      reloaded = CMS.get_page!(page.id, actor: actor)
      assert prose(rich_block(reloaded)) == "stored"
      assert Enum.find(reloaded.blocks, &(&1.type == :heading)).value.text == "Keep me"
    end

    test "a first client seeding the empty room from the record leaves it unchanged" do
      actor = admin()
      page = draft_page!(actor)
      key = "collab:page:#{page.id}"
      fragment = "block-#{rich_block(page).id}"
      corrupt_row!(key)

      capture_log(fn ->
        {:ok, server} = Crdt.ensure_server(key, page.org_id)
        leave = attach_client(server)
        # What the first peer does: seed each empty fragment from the record.
        seed = paragraph_update(Crdt.state_update(server), fragment, "stored")
        :ok = Crdt.apply_update(server, seed)
        leave.()
        :ok = GenServer.stop(server)
      end)

      reloaded = CMS.get_page!(page.id, actor: actor)
      assert prose(rich_block(reloaded)) == "stored"
      assert Enum.find(reloaded.blocks, &(&1.type == :heading)).value.text == "Keep me"
    end
  end
end
