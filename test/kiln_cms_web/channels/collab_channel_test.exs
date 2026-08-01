defmodule KilnCMSWeb.CollabChannelTest do
  @moduledoc """
  The collab CRDT relay end-to-end at the channel layer: token-gated socket,
  every join authorized against the document it names (#655), join replies with
  the authoritative state + peer count, updates relay to the other clients, and
  the whole surface is inert when the flag is off.
  """
  # async: false — the flag test flips global application env, and the doc
  # server runs in its own process (shared sandbox).
  use KilnCMS.DataCase, async: false

  import Phoenix.ChannelTest
  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS
  alias KilnCMSWeb.CollabSocket

  @endpoint KilnCMSWeb.Endpoint

  # Must track SCHEMA_VSN in assets/js/collab.js / @schema_vsn in the channel.
  @schema_vsn 2

  setup do
    # RESTORE, don't delete: `config/test.exs` sets this at boot, so deleting the
    # key leaves `Crdt.enabled?/0` on its `false` default for every module that
    # runs after this one.
    previous = Application.get_env(:kiln_cms, :collab_prototype)
    Application.put_env(:kiln_cms, :collab_prototype, true)
    on_exit(fn -> Application.put_env(:kiln_cms, :collab_prototype, previous) end)

    actor = user(:admin)
    %{actor: actor, page: draft_page!(actor)}
  end

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "collab-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        Map.new(attrs)
      )
    )
  end

  defp draft_page!(actor, opts \\ []) do
    CMS.create_page!(
      Map.merge(
        %{title: "Collab", slug: "collab-#{System.unique_integer([:positive])}"},
        Map.new(opts)
      ),
      actor: actor
    )
  end

  defp token(actor), do: Phoenix.Token.sign(@endpoint, "collab", actor.id)

  defp topic(page), do: "collab:page:#{page.id}"

  defp socket!(actor, host \\ nil) do
    {:ok, socket} = connect(CollabSocket, %{"token" => token(actor)}, connect_info(host))
    socket
  end

  # A bare connect carries no `connect_info`, which resolves to the default org.
  defp connect_info(nil), do: %{}
  defp connect_info(host), do: %{uri: URI.parse("wss://#{host}/ws/collab")}

  defp host_of(org), do: "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"

  defp join!(actor, topic) do
    {:ok, reply, joined} = subscribe_and_join(socket!(actor), topic, %{"vsn" => @schema_vsn})
    {reply, joined}
  end

  describe "socket authentication" do
    test "sockets demand a valid token" do
      assert :error = connect(CollabSocket, %{"token" => "forged"})
      assert :error = connect(CollabSocket, %{})
    end

    test "a token naming no live account is refused" do
      # Tokens outlive the accounts they name by up to a day, so resolving the
      # user at connect is what stops a removed editor collaborating on one.
      stale = Phoenix.Token.sign(@endpoint, "collab", Ash.UUID.generate())
      assert :error = connect(CollabSocket, %{"token" => stale})
    end
  end

  describe "join authorization (#655)" do
    test "a topic naming no document is refused", %{actor: actor} do
      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(actor), "collab:page:#{Ash.UUID.generate()}", %{
                 "vsn" => @schema_vsn
               })
    end

    test "a topic naming no known content type is refused", %{actor: actor, page: page} do
      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(actor), "collab:nonsense:#{page.id}", %{
                 "vsn" => @schema_vsn
               })
    end

    test "a malformed topic is refused rather than crashing the socket", %{actor: actor} do
      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(actor), "collab:nokey", %{"vsn" => @schema_vsn})
    end

    test "a document in another organization is refused", %{actor: actor} do
      # The whole point of the issue: a valid editor token used to be a key to
      # every document in every org, readable and writable through the relay.
      other = org("other")

      foreign =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Theirs",
          slug: "theirs-#{System.unique_integer([:positive])}",
          org_id: other.id,
          state: :draft
        })

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(actor), "collab:page:#{foreign.id}", %{
                 "vsn" => @schema_vsn
               })
    end

    test "a document the actor may not read is refused", %{page: page} do
      # A signed-in account with no editorial role holds a perfectly valid token
      # (the mint is gated, but the check that matters is this one).
      outsider = user(:viewer)

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(outsider), topic(page), %{"vsn" => @schema_vsn})
    end

    test "an editor joining their own org's document is admitted", %{actor: actor, page: page} do
      assert {%{"state" => _state, "peers" => 1}, _socket} = join!(actor, topic(page))
    end

    test "an editor scoped away from this type is refused, though they may READ it",
         %{page: page} do
      # The read axis and the write axis are separate scopes (#332), and the
      # read is the wider one. An editor with a non-empty `editable_types` that
      # excludes pages still READS pages fine — so a read-gated join would admit
      # them, and everything they typed would be persisted by the checkpoint
      # under `authorize?: false`, authoring a type they are forbidden to author.
      restricted = user(:editor, editable_types: ["post"])

      assert {:ok, _} = KilnCMS.CMS.get_page(page.id, actor: restricted)

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(restricted), topic(page), %{"vsn" => @schema_vsn})
    end

    test "a published, public document is not a room anyone signed in may enter",
         %{actor: actor} do
      # `state == :published and audience == :public` authorizes the READ for
      # anybody at all, including anonymous delivery. Gating the join on the read
      # would hand every token-holder write access to every published document.
      published =
        actor |> draft_page!() |> then(&KilnCMS.CMS.publish_page!(&1, %{}, actor: actor))

      viewer = user(:viewer)

      assert {:ok, _} = KilnCMS.CMS.get_page(published.id, actor: viewer)

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(viewer), topic(published), %{"vsn" => @schema_vsn})
    end

    test "a differently-cased id joins the SAME authoritative doc", %{actor: actor, page: page} do
      # Ash casts uuids leniently, so an upper-cased id authorizes the same
      # record. Keyed on the client's topic string that would be a second
      # authoritative doc over one record — invisible to the first room's
      # editors, and overwriting their text at checkpoint.
      {_reply, sock_a} = join!(actor, topic(page))
      {_reply_b, _sock_b} = join!(actor, "collab:page:#{String.upcase(page.id)}")

      assert sock_a.assigns.doc_server ==
               elem(join!(actor, "collab:page:#{String.upcase(page.id)}"), 1).assigns.doc_server
    end
  end

  describe "tenant resolution (#563 / #655)" do
    test "an editor on their own org's host joins their own org's document" do
      other = org("collab-host")
      editor = user(:admin)

      page =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Theirs",
          slug: "theirs-#{System.unique_integer([:positive])}",
          org_id: other.id,
          state: :draft
        })

      # Connected on the default host, the document is in another org and is
      # refused; connected on its own org's host it resolves and is admitted.
      # Without both halves, hardcoding the socket back to the default org would
      # leave every test in this file green.
      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket!(editor), "collab:page:#{page.id}", %{
                 "vsn" => @schema_vsn
               })

      assert {:ok, %{"peers" => 1}, _joined} =
               subscribe_and_join(socket!(editor, host_of(other)), "collab:page:#{page.id}", %{
                 "vsn" => @schema_vsn
               })
    end

    test "an unresolvable host is refused outright under TENANT_STRICT_HOST", %{actor: actor} do
      # Restore, don't delete: `config/config.exs` sets this, and
      # `tenant_strict_host_test.exs` saves-and-restores it the same way — so a
      # `delete_env` here makes *that* file capture `nil` as its previous value
      # and put `nil` back, which is neither true nor false and crashes
      # `Tenant.fetch_org/1` for every test that runs afterwards.
      previous = Application.get_env(:kiln_cms, :tenant_strict_host)
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      on_exit(fn -> Application.put_env(:kiln_cms, :tenant_strict_host, previous) end)

      assert :error =
               connect(CollabSocket, %{"token" => token(actor)}, connect_info("nowhere.example"))
    end
  end

  test "peers on a stale bundle (old or missing schema vsn) are refused", %{
    actor: actor,
    page: page
  } do
    socket = socket!(actor)

    # A pre-#475 bundle sends no vsn at all; a future mismatch is refused too.
    # y-prosemirror deletes unknown nodes from the shared doc, so a stale peer
    # must never enter the room (it degrades to solo editing client-side).
    assert {:error, %{reason: "stale bundle"}} = subscribe_and_join(socket, topic(page), %{})

    assert {:error, %{reason: "stale bundle"}} =
             subscribe_and_join(socket, topic(page), %{"vsn" => @schema_vsn - 1})
  end

  test "clients converge through the channel; late joiners get full state", %{
    actor: actor,
    page: page
  } do
    topic = topic(page)

    {%{"state" => _empty, "peers" => 1}, sock_a} = join!(actor, topic)
    {%{"peers" => 2}, _sock_b} = join!(actor, topic)

    # A types locally and pushes the binary Yjs update.
    doc_a = Yex.Doc.new()
    doc_a |> Yex.Doc.get_text("block-0") |> Yex.Text.insert(0, "synced!")
    {:ok, update} = Yex.encode_state_as_update(doc_a)

    ref = push(sock_a, "update", %{"update" => Base.encode64(update)})
    assert_reply ref, :ok

    # The other client receives the relay (sender excluded by broadcast_from).
    assert_push "update", %{"update" => relayed}
    assert Base.decode64!(relayed) == update

    # A third client joining later converges from the join reply alone.
    {%{"state" => state, "peers" => 3}, _sock_c} = join!(actor, topic)
    doc_c = Yex.Doc.new()
    :ok = Yex.apply_update(doc_c, Base.decode64!(state))
    assert doc_c |> Yex.Doc.get_text("block-0") |> Yex.Text.to_string() == "synced!"
  end

  test "malformed updates are refused", %{actor: actor, page: page} do
    {_reply, socket} = join!(actor, topic(page))

    ref = push(socket, "update", %{"update" => "!!! not base64 !!!"})
    assert_reply ref, :error, %{reason: "bad update"}

    ref = push(socket, "update", %{"update" => Base.encode64("not yjs")})
    assert_reply ref, :error, %{reason: "bad update"}
  end

  test "awareness payloads relay verbatim to the other clients", %{actor: actor, page: page} do
    topic = topic(page)
    {_reply, sock_a} = join!(actor, topic)
    {_reply2, _sock_b} = join!(actor, topic)

    push(sock_a, "awareness", %{"cursor" => %{"anchor" => 3}, "name" => "A"})
    assert_push "awareness", %{"cursor" => %{"anchor" => 3}, "name" => "A"}
  end

  test "a newcomer's awareness_request is relayed so peers re-announce", %{
    actor: actor,
    page: page
  } do
    topic = topic(page)
    {_reply, _sock_a} = join!(actor, topic)
    {_reply2, sock_b} = join!(actor, topic)

    push(sock_b, "awareness_request", %{})
    assert_push "awareness_request", %{}
  end

  test "joins are refused while the prototype flag is off", %{actor: actor, page: page} do
    Application.put_env(:kiln_cms, :collab_prototype, false)

    assert {:error, %{reason: "collab disabled"}} =
             subscribe_and_join(socket!(actor), topic(page), %{"vsn" => @schema_vsn})
  end
end
