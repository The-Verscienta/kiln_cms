defmodule KilnCMS.Collab.CrdtMaterializationTest do
  @moduledoc """
  Server-side checkpoint materialization (spike doc §8): when the last editor
  detaches (or the server shuts down mid-session), the DocServer renders the
  converged Yjs text to sanitized HTML on the BEAM and writes it into the
  draft's blocks through the autosave action — the persistence net for
  "everyone crashed before their autosave fired".
  """
  # async: false — flips global config; sync tests run the sandbox in shared
  # mode so the DocServer process can read/write records.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Collab.Crdt
  alias KilnCMS.Collab.Crdt.Materializer

  setup do
    Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: true)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: false)
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mat-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp draft_page!(actor) do
    CMS.create_page!(
      %{
        title: "Mat",
        slug: "mat-#{System.unique_integer([:positive])}",
        blocks: [
          %{"_type" => "heading", "text" => "Keep me"},
          %{"_type" => "rich_text", "legacy_html" => "<p>stored</p>"}
        ]
      },
      actor: actor
    )
  end

  # An update writing ProseMirror-shaped content (a paragraph with a bold run)
  # into the block's fragment, exactly as y-prosemirror would.
  defp typed_paragraph_update(base_state, fragment_name) do
    doc = Yex.Doc.new()
    :ok = Yex.apply_update(doc, base_state)
    frag = Yex.Doc.get_xml_fragment(doc, fragment_name)

    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("paragraph", [Yex.XmlTextPrelim.from("typed together")])
    )

    text = frag |> Yex.XmlFragment.fetch!(0) |> Yex.XmlElement.fetch!(0)
    Yex.XmlText.format(text, 6, 8, %{"bold" => %{}})

    {:ok, update} = Yex.encode_state_as_update(doc)
    update
  end

  defp rich_block(page), do: Enum.find(page.blocks, &(&1.type == :rich_text)).value

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

    assert_receive :attached
    fn -> send(pid, :leave) end
  end

  defp await(fun, tries \\ 40) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(25)
        await(fun, tries - 1)
    end
  end

  test "the last client's departure materializes converged text into the draft" do
    actor = admin()
    page = draft_page!(actor)
    block_id = rich_block(page).id

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}")
    leave = attach_client(server)

    {initial, _n} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, typed_paragraph_update(initial, "block-#{block_id}"))

    # Our own attach (this test process) plus the disposable client — drop the
    # client, then drop ourselves out of the count by... the test process stays
    # attached, so detach the client and stop the server to hit terminate.
    leave.()

    # The test process is still a client, so materialization hasn't run yet.
    assert rich_block(CMS.get_page!(page.id, actor: actor)).legacy_html == "<p>stored</p>"

    # Server shutdown (deploy path) flushes regardless of attached clients.
    :ok = GenServer.stop(server)

    await(fn ->
      rich_block(CMS.get_page!(page.id, actor: actor)).legacy_html =~ "typed"
    end)

    page = CMS.get_page!(page.id, actor: actor)
    assert rich_block(page).legacy_html == "<p>typed <strong>together</strong></p>"
    # Untouched blocks round-trip identically; block identity is preserved.
    assert Enum.find(page.blocks, &(&1.type == :heading)).value.text == "Keep me"
    assert rich_block(page).id == block_id
  end

  test "last-client-down (not just shutdown) triggers the write-back" do
    actor = admin()
    page = draft_page!(actor)
    block_id = rich_block(page).id

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}")
    leave = attach_client(server)

    {initial, _n} = Crdt.state_update(server) |> then(&{&1, nil})
    :ok = Crdt.apply_update(server, typed_paragraph_update(initial, "block-#{block_id}"))

    # The disposable client was the ONLY attached client (state_update doesn't
    # attach) — its departure empties the room and materializes.
    leave.()

    await(fn ->
      rich_block(CMS.get_page!(page.id, actor: actor)).legacy_html =~ "typed"
    end)
  end

  test "blocks without fragment content keep their stored HTML" do
    actor = admin()
    page = draft_page!(actor)

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}")
    leave = attach_client(server)
    # No updates at all — nothing dirty, nothing written.
    leave.()
    :ok = GenServer.stop(server)

    assert rich_block(CMS.get_page!(page.id, actor: actor)).legacy_html == "<p>stored</p>"
  end

  test "published content is never written by the server" do
    actor = admin()
    page = draft_page!(actor)
    page = CMS.publish_page!(page, %{}, actor: actor)
    block_id = rich_block(page).id

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}")
    leave = attach_client(server)

    {initial, _} = {Crdt.state_update(server), nil}
    :ok = Crdt.apply_update(server, typed_paragraph_update(initial, "block-#{block_id}"))
    leave.()
    :ok = GenServer.stop(server)

    assert rich_block(CMS.get_page!(page.id, actor: actor)).legacy_html == "<p>stored</p>"
  end

  test "the materializer renders the StarterKit node set totally" do
    doc = Yex.Doc.new()
    frag = Yex.Doc.get_xml_fragment(doc, "f")

    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("heading", [Yex.XmlTextPrelim.from("Title")])
    )

    Yex.XmlFragment.fetch!(frag, 0) |> Yex.XmlElement.insert_attribute("level", "3")

    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("bulletList", [
        Yex.XmlElementPrelim.new("listItem", [
          Yex.XmlElementPrelim.new("paragraph", [Yex.XmlTextPrelim.from("item & <escaped>")])
        ])
      ])
    )

    Yex.XmlFragment.push(frag, Yex.XmlElementPrelim.new("horizontalRule", []))
    # Unknown element: contributes children instead of crashing.
    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("galaxyBrain", [Yex.XmlTextPrelim.from("degraded")])
    )

    html = Materializer.fragment_html(doc, "f")

    assert html =~ "<h3>Title</h3>"
    assert html =~ "<ul><li><p>item &amp; &lt;escaped&gt;</p></li></ul>"
    assert html =~ "<hr"
    assert html =~ "degraded"
    refute html =~ "galaxyBrain"

    # Empty/absent fragments are nil — callers must not clobber stored HTML.
    assert Materializer.fragment_html(doc, "never-touched") == nil
  end
end
