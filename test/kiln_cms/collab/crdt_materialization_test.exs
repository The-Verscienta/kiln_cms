defmodule KilnCMS.Collab.CrdtMaterializationTest do
  @moduledoc """
  Server-side checkpoint materialization (spike doc §8): when the last editor
  detaches (or the server shuts down mid-session), the DocServer converts the
  converged Yjs text to Portable Text on the BEAM and writes it into the
  draft's blocks through the autosave action — the persistence net for
  "everyone crashed before their autosave fired".

  These tests seeded rich-text blocks holding **only `legacy_html`**, which was
  the one shape whose checkpoint still worked: Portable Text is authoritative,
  so the cast nulls `legacy_html` whenever `body` is present, and a checkpoint
  materializing to HTML had its write discarded for every block the editor had
  ever saved. The fixture now carries a `body`, so the assertions run against
  the shape real content is in.
  """
  # async: false — flips global config; sync tests run the sandbox in shared
  # mode so the DocServer process can read/write records.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Blocks.PortableText
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
          %{"_type" => "rich_text", "body" => pt("stored")}
        ]
      },
      actor: actor
    )
  end

  # Prose in the shape the editor actually stores it.
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

  # Deadline-based (#1349): the previous `tries \\ 40` at `sleep(25)` was the
  # literal one-second budget ConnCase.eventually/4's docstring post-mortems.
  defp await(fun) do
    KilnCMS.Test.Eventually.eventually(fun, message: "condition never held")
    :ok
  end

  test "the last client's departure materializes converged text into the draft" do
    actor = admin()
    page = draft_page!(actor)
    block_id = rich_block(page).id

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}", page.org_id)
    leave = attach_client(server)

    {initial, _n} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, typed_paragraph_update(initial, "block-#{block_id}"))

    # Our own attach (this test process) plus the disposable client — drop the
    # client, then drop ourselves out of the count by... the test process stays
    # attached, so detach the client and stop the server to hit terminate.
    leave.()

    # The test process is still a client, so materialization hasn't run yet.
    assert prose(rich_block(CMS.get_page!(page.id, actor: actor))) == "stored"

    # Server shutdown (deploy path) flushes regardless of attached clients.
    :ok = GenServer.stop(server)

    await(fn ->
      prose(rich_block(CMS.get_page!(page.id, actor: actor))) =~ "typed"
    end)

    page = CMS.get_page!(page.id, actor: actor)
    assert prose(rich_block(page)) == "typed together"
    # Untouched blocks round-trip identically; block identity is preserved.
    assert Enum.find(page.blocks, &(&1.type == :heading)).value.text == "Keep me"
    assert rich_block(page).id == block_id
  end

  test "last-client-down (not just shutdown) triggers the write-back" do
    actor = admin()
    page = draft_page!(actor)
    block_id = rich_block(page).id

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}", page.org_id)
    leave = attach_client(server)

    {initial, _n} = Crdt.state_update(server) |> then(&{&1, nil})
    :ok = Crdt.apply_update(server, typed_paragraph_update(initial, "block-#{block_id}"))

    # The disposable client was the ONLY attached client (state_update doesn't
    # attach) — its departure empties the room and materializes.
    leave.()

    await(fn ->
      prose(rich_block(CMS.get_page!(page.id, actor: actor))) =~ "typed"
    end)
  end

  test "blocks without fragment content keep their stored prose" do
    actor = admin()
    page = draft_page!(actor)

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}", page.org_id)
    leave = attach_client(server)
    # No updates at all — nothing dirty, nothing written.
    leave.()
    :ok = GenServer.stop(server)

    assert prose(rich_block(CMS.get_page!(page.id, actor: actor))) == "stored"
  end

  test "the write-back lands on a document outside the default org (#655)" do
    actor = admin()
    other = KilnCMS.OrgFixtures.org("collab-mat")

    page =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Theirs",
        slug: "theirs-#{System.unique_integer([:positive])}",
        org_id: other.id,
        state: :draft,
        blocks: [
          %{"_type" => "rich_text", "id" => Ash.UUID.generate(), "legacy_html" => "<p>stored</p>"}
        ]
      })

    block_id = rich_block(page).id

    # Seeded with legacy HTML and no body — the never-migrated shape. Its first
    # collaborative checkpoint converts it to Portable Text, which is the
    # direction the cast enforces anyway.
    # The checkpoint used to resolve `default_org_id/0` unconditionally, so on
    # any site but the default one it looked the document up in the wrong tenant
    # and silently wrote nothing — the converged text was simply lost.
    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}", page.org_id)
    leave = attach_client(server)

    {initial, _n} = Crdt.attach(server)
    :ok = Crdt.apply_update(server, typed_paragraph_update(initial, "block-#{block_id}"))
    leave.()
    :ok = GenServer.stop(server)

    reloaded = CMS.get_page!(page.id, actor: actor, tenant: other.id)
    assert prose(rich_block(reloaded)) =~ "typed"
  end

  test "published content is never written by the server" do
    actor = admin()
    page = draft_page!(actor)
    page = CMS.publish_page!(page, %{}, actor: actor)
    block_id = rich_block(page).id

    {:ok, server} = Crdt.ensure_server("collab:page:#{page.id}", page.org_id)
    leave = attach_client(server)

    {initial, _} = {Crdt.state_update(server), nil}
    :ok = Crdt.apply_update(server, typed_paragraph_update(initial, "block-#{block_id}"))
    leave.()
    :ok = GenServer.stop(server)

    assert prose(rich_block(CMS.get_page!(page.id, actor: actor))) == "stored"
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

    body = Materializer.fragment_body(doc, "f")
    html = PortableText.to_html(body)

    assert html =~ "<h3>Title</h3>"
    assert html =~ "<ul><li>item &amp; &lt;escaped&gt;</li></ul>"
    assert html =~ "<hr"
    assert html =~ "degraded"
    refute html =~ "galaxyBrain"

    # Empty/absent fragments are nil — callers must not clobber stored prose.
    assert Materializer.fragment_body(doc, "never-touched") == nil
  end

  test "a link authored collaboratively survives the checkpoint (#823)" do
    doc = Yex.Doc.new()
    frag = Yex.Doc.get_xml_fragment(doc, "f")

    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("paragraph", [Yex.XmlTextPrelim.from("See the refund policy")])
    )

    text = frag |> Yex.XmlFragment.fetch!(0) |> Yex.XmlElement.fetch!(0)
    Yex.XmlText.format(text, 0, 3, %{"bold" => %{}})
    Yex.XmlText.format(text, 4, 17, %{"link" => %{"href" => "/refunds"}})

    # The HTML materializer knew four marks — bold, italic, strike, code — so a
    # collaborative link was rendered as its bare text and the checkpoint wrote
    # the loss back. Going through `from_tiptap/1` means one list of marks.
    [block] = Materializer.fragment_body(doc, "f")

    assert [%{"_type" => "link", "_key" => key, "href" => "/refunds"}] = block["markDefs"]
    assert %{"text" => "the refund policy", "marks" => [^key]} = List.last(block["children"])
    assert PortableText.to_html([block]) =~ ~s(<a href="/refunds">the refund policy</a>)

    # An href the policy refuses is blanked by `sanitize_def/1`, exactly as it
    # would be coming from the editor or the API — no second URL rule here.
    Yex.XmlText.format(text, 0, 3, %{"link" => %{"href" => "javascript:alert(1)"}})
    [block] = Materializer.fragment_body(doc, "f")
    assert Enum.any?(block["markDefs"], &(&1["href"] == ""))
    refute PortableText.to_html([block]) =~ "javascript:"
  end

  test "the materializer keeps table structure and the code-block language tag" do
    doc = Yex.Doc.new()
    frag = Yex.Doc.get_xml_fragment(doc, "f")

    # A 1x2 table with a header cell and a spanning data cell — before the
    # table clauses landed, checkpoint write-back flattened this to <p> soup.
    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("table", [
        Yex.XmlElementPrelim.new("tableRow", [
          Yex.XmlElementPrelim.new("tableHeader", [
            Yex.XmlElementPrelim.new("paragraph", [Yex.XmlTextPrelim.from("Name")])
          ]),
          Yex.XmlElementPrelim.new("tableCell", [
            Yex.XmlElementPrelim.new("paragraph", [Yex.XmlTextPrelim.from("Ginger")])
          ])
        ])
      ])
    )

    frag
    |> Yex.XmlFragment.fetch!(0)
    |> Yex.XmlElement.fetch!(0)
    |> Yex.XmlElement.fetch!(1)
    |> Yex.XmlElement.insert_attribute("colspan", "2")

    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("codeBlock", [Yex.XmlTextPrelim.from("IO.puts(1)")])
    )

    Yex.XmlFragment.fetch!(frag, 1) |> Yex.XmlElement.insert_attribute("language", "elixir")

    body = Materializer.fragment_body(doc, "f")

    assert [%{"_type" => "table", "rows" => [%{"cells" => [header, spanning]}]}, code] = body
    assert %{"header" => true, "children" => [%{"text" => "Name"}]} = header
    # Y attributes are strings; `from_tiptap/1` only stores an INTEGER span, so
    # a checkpoint that passed "2" straight through would silently drop it.
    assert %{"header" => false, "colspan" => 2, "children" => [%{"text" => "Ginger"}]} = spanning
    assert %{"style" => "code", "language" => "elixir"} = code
    assert PortableText.to_html(body) =~ ~s|<code class="language-elixir">|
  end
end
