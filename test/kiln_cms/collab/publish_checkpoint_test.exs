defmodule KilnCMS.Collab.PublishCheckpointTest do
  @moduledoc """
  Publishing a document while a collab room is open (#1061).

  `Checkpoint.write_back/3` persists through `:autosave`, which since #1015
  carries a row-level `state == :draft` filter — so once a publish lands, the
  room's converged prose can never be written and goes away with the DocServer.
  The editors see nothing wrong: `ContentEditorLive.mark_dirty/1` also stops
  autosaving on a non-draft, so after the publish *nobody* is persisting while
  the shared doc keeps accepting edits.

  The publish is therefore the last moment the text is reachable, and these
  tests are about it being taken.

  There is deliberately no test that the prose rides in the publish's *own*
  write rather than a separate one beside it. That property is enforced by
  construction rather than observable: flushing through `:autosave` first would
  bump nothing a publish reads back (`lock_version` is not touched by
  `:publish`), and the failure it would cause — the publish built from the
  pre-flush row losing its optimistic lock — is a raise, not a silent wrong
  answer. An assertion here would have to pass either way, and two attempts at
  writing one did exactly that before it was removed.
  """
  # async: false — flips global config, and the DocServer reads records from
  # another process, which needs the sandbox in shared mode.
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.CMS
  alias KilnCMS.Collab.Crdt

  setup do
    Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: true)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: false)
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pubchk-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp draft_page!(actor) do
    CMS.create_page!(
      %{
        title: "Pub",
        slug: "pubchk-#{System.unique_integer([:positive])}",
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

  defp rich_block(page), do: Enum.find(page.blocks, &(&1.type == :rich_text)).value

  defp prose(page), do: page |> rich_block() |> Map.fetch!(:body) |> PortableText.to_plain_text()

  # Type into the room's fragment for `block_id`, exactly as y-prosemirror would.
  defp type_into_room(server, block_id, text) do
    base = Crdt.state_update(server)

    doc = Yex.Doc.new()
    :ok = Yex.apply_update(doc, base)
    frag = Yex.Doc.get_xml_fragment(doc, "block-#{block_id}")

    Yex.XmlFragment.push(
      frag,
      Yex.XmlElementPrelim.new("paragraph", [Yex.XmlTextPrelim.from(text)])
    )

    {:ok, update} = Yex.encode_state_as_update(doc)
    :ok = Crdt.apply_update(server, update)
  end

  defp open_room(page) do
    {:ok, server} = Crdt.ensure_server(Crdt.doc_key(:page, page.id), page.org_id)
    server
  end

  test "a publish carries the open room's unsaved prose instead of dropping it" do
    actor = admin()
    page = draft_page!(actor)
    server = open_room(page)

    type_into_room(server, rich_block(page).id, "typed but never autosaved")

    # The row still holds the old text: this is the state the loss happens from.
    assert prose(CMS.get_page!(page.id, actor: actor)) == "stored"

    {:ok, published} = CMS.publish_page(page, %{}, actor: actor)

    assert published.state == :published
    assert prose(CMS.get_page!(published.id, actor: actor)) == "typed but never autosaved"
  end

  test "a publish with no room open is unchanged" do
    actor = admin()
    page = draft_page!(actor)

    {:ok, published} = CMS.publish_page(page, %{}, actor: actor)

    assert published.state == :published
    assert prose(CMS.get_page!(published.id, actor: actor)) == "stored"
  end

  # The room must not be created by the publish. A publish for a record nobody
  # is editing is the overwhelming majority, and minting a DocServer for each
  # one would cost a process and a stored row per publish.
  test "a publish does not start a room for a document nobody is editing" do
    actor = admin()
    page = draft_page!(actor)
    key = Crdt.doc_key(:page, page.id)

    assert Registry.lookup(KilnCMS.Collab.Crdt.Registry, key) == []

    {:ok, _published} = CMS.publish_page(page, %{}, actor: actor)

    assert Registry.lookup(KilnCMS.Collab.Crdt.Registry, key) == []
  end

  # The other half of the issue: the room must be TOLD. Without this the shared
  # doc keeps accepting edits that nothing will ever persist — the client stops
  # autosaving on a non-draft — and the editors see nothing wrong.
  test "the room is told that it was published" do
    actor = admin()
    page = draft_page!(actor)
    _server = open_room(page)

    KilnCMSWeb.Endpoint.subscribe(Crdt.doc_key(:page, page.id))

    {:ok, _published} = CMS.publish_page(page, %{}, actor: actor)

    assert_receive %Phoenix.Socket.Broadcast{event: "published"}, 2_000
  end

  # Announced AFTER the transaction, so a rolled-back publish never tells a room
  # it was published. `after_action` would broadcast before the commit.
  test "a refused publish tells the room nothing" do
    actor = admin()
    page = draft_page!(actor)
    _server = open_room(page)

    {:ok, published} = CMS.publish_page(page, %{}, actor: actor)

    KilnCMSWeb.Endpoint.subscribe(Crdt.doc_key(:page, published.id))

    # Already published: the compare-and-swap filter refuses this one.
    assert {:error, _} = CMS.publish_page(published, %{}, actor: actor)

    refute_receive %Phoenix.Socket.Broadcast{event: "published"}, 200
  end

  # THE regression this change could have introduced, and did on the first
  # attempt. The publish gates (#377 claim checking, #403 alt text) are
  # validations, and a validation runs inline during `for_action` — before any
  # `before_action` hook. So merging the room's prose in a hook left the gates
  # judging the STORED blocks while the ROOM's blocks were what published:
  # type the banned phrase into the shared doc, never let autosave land, publish.
  #
  # Both gates are deferred to the before_action phase now, and the checkpoint
  # is declared first so its hook registers first.
  describe "the publish gates judge what actually publishes" do
    setup do
      previous = Application.get_env(:kiln_cms, KilnCMS.Compliance)

      Application.put_env(:kiln_cms, KilnCMS.Compliance,
        enabled: true,
        require_at_publish: true,
        rules: :default
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, KilnCMS.Compliance, previous),
          else: Application.delete_env(:kiln_cms, KilnCMS.Compliance)
      end)

      :ok
    end

    test "a claim typed only into the room is refused, not published" do
      actor = admin()
      page = draft_page!(actor)
      server = open_room(page)

      type_into_room(server, rich_block(page).id, "Our formula is FDA approved.")

      assert {:error, error} = CMS.publish_page(page, %{}, actor: actor)
      assert Exception.message(error) =~ "unreviewed claim"

      assert CMS.get_page!(page.id, actor: actor).state == :draft
    end

    # The mirror, and the reason this is a correctness fix rather than only a
    # security one: `ComplianceClaims` promises the gate can never disagree with
    # the panel the author is reading, and the panel reads the live editor. A
    # gate judging the stored blocks would refuse a publish over a phrase the
    # editor had already deleted in the room.
    test "a claim the room has already removed does not refuse the publish" do
      actor = admin()

      page =
        CMS.create_page!(
          %{
            title: "Pub",
            slug: "pubchk-#{System.unique_integer([:positive])}",
            blocks: [
              %{"_type" => "rich_text", "body" => pt("Our formula is FDA approved.")}
            ]
          },
          actor: actor
        )

      server = open_room(page)
      type_into_room(server, rich_block(page).id, "Our formula is gentle.")

      assert {:ok, published} = CMS.publish_page(page, %{}, actor: actor)
      assert prose(CMS.get_page!(published.id, actor: actor)) =~ "gentle"
    end
  end

  # The scheduler path is the same publish. "A scheduled publish is never under
  # an open room" is false — schedule for 09:00, keep editing collaboratively,
  # and the cron fires at 09:00 into a live room. `:publish_scheduled` also
  # carries no compare-and-swap filter, so the room is even likelier to still be
  # attached.
  test "a scheduled publish carries the room's prose too" do
    actor = admin()
    page = draft_page!(actor)
    server = open_room(page)

    type_into_room(server, rich_block(page).id, "scheduled prose")

    {:ok, published} = CMS.publish_scheduled_page(page, %{}, actor: actor)

    assert published.state == :published
    assert prose(CMS.get_page!(published.id, actor: actor)) == "scheduled prose"
  end

  # A publish never used to change content, so `:publish` carried none of the
  # derived-column changes. Now that it can, a document published with the
  # room's prose would otherwise be unfindable by its own published words —
  # `search_text` is the full-text column delivery searches.
  test "the published document is findable by the prose the room contributed" do
    actor = admin()
    page = draft_page!(actor)
    server = open_room(page)

    type_into_room(server, rich_block(page).id, "zebrafish quarterly")

    {:ok, published} = CMS.publish_page(page, %{}, actor: actor)

    assert CMS.get_page!(published.id, actor: actor).search_text =~ "zebrafish quarterly"
  end

  # The doc key must be the topic the channel joins, or the announcement lands
  # nowhere and the room is never told. The tests above build both sides from
  # `Crdt.doc_key/2`, so they are self-consistent by construction and blind to
  # this — a key that drifts from `CollabChannel`'s would ship green.
  test "the doc key is the topic the channel actually joins" do
    page = draft_page!(admin())
    ct = KilnCMS.CMS.ContentTypes.get("page", page.org_id)

    # `CollabChannel.authorize/3` builds exactly this.
    assert Crdt.doc_key(ct.type, page.id) == "collab:#{ct.type}:#{page.id}"
  end

  # A room that holds nothing new must not rewrite the record: the checkpoint
  # path already treats a no-change materialization as a skip, and a publish
  # should not differ.
  test "an open room that has never been typed into leaves the prose alone" do
    actor = admin()
    page = draft_page!(actor)
    _server = open_room(page)

    {:ok, published} = CMS.publish_page(page, %{}, actor: actor)

    assert prose(CMS.get_page!(published.id, actor: actor)) == "stored"
  end
end
