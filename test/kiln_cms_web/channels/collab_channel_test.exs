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
  alias KilnCMS.RateLimitHelpers
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

  # `handle_in/3` runs in the sender's own channel process, so a crash drops
  # that client to a rejoin mid-edit (#764). The second client below is here to
  # pin the other half — that the room and the doc server are NOT taken with it,
  # which is what `Collab.DocServer` monitoring rather than linking buys.
  test "a wrong-shaped or unknown frame is ignored, room intact", %{actor: actor, page: page} do
    topic = topic(page)
    {_reply, socket} = join!(actor, topic)
    # A second client, so the assertion covers the room surviving as well as
    # the sender's own socket.
    {_reply2, sock_b} = join!(actor, topic)

    # `"update"` matched on the key and never the value, so `Base.decode64/2`
    # raised on anything non-binary.
    for shape <- [[], ["x"], %{"a" => "1"}, 1, nil, true] do
      push(socket, "update", %{"update" => shape})
    end

    # `handle_in/3` had no catch-all, so an unknown name was a
    # FunctionClauseError.
    push(socket, "no_such_event", %{})
    push(socket, "update", %{"not_the_key" => "x"})

    # The room still works: a real update from the surviving socket still
    # reaches the other client.
    doc = Yex.Doc.new()
    doc |> Yex.Doc.get_text("block-0") |> Yex.Text.insert(0, "alive")
    {:ok, update} = Yex.encode_state_as_update(doc)

    ref = push(sock_b, "update", %{"update" => Base.encode64(update)})
    assert_reply ref, :ok
    assert_push "update", %{"update" => _}
  end

  test "awareness payloads relay verbatim to the other clients", %{actor: actor, page: page} do
    topic = topic(page)
    {_reply, sock_a} = join!(actor, topic)
    {_reply2, _sock_b} = join!(actor, topic)

    push(sock_a, "awareness", %{"cursor" => %{"anchor" => 3}, "name" => "A"})
    assert_push "awareness", %{"cursor" => %{"anchor" => 3}, "name" => "A"}
  end

  describe "periodic re-authorization (#775)" do
    setup do
      previous = %{
        interval: Application.get_env(:kiln_cms, :socket_reauth_interval_ms),
        floor: Application.get_env(:kiln_cms, :socket_reauth_update_floor)
      }

      on_exit(fn ->
        restore(:socket_reauth_interval_ms, previous.interval)
        restore(:socket_reauth_update_floor, previous.floor)
      end)

      # `subscribe_and_join/3` LINKS the channel to the test process, so a room
      # that closes itself takes the test with it — which is the whole behaviour
      # under test here. Trapping turns that into the `{:EXIT, …}` message these
      # tests assert on, and is also how a real client learns: Phoenix pushes
      # `phx_error` on the channel exiting, and `phoenix.js` retries the join.
      Process.flag(:trap_exit, true)

      :ok
    end

    # Nothing sets these at boot, so `nil` is genuinely "absent" here and putting
    # it back would be wrong for the next test — the opposite of the
    # `:collab_prototype` case above, where the config file DOES set a value.
    defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
    defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

    defp yjs_update(text) do
      doc = Yex.Doc.new()
      doc |> Yex.Doc.get_text("block-0") |> Yex.Text.insert(0, text)
      {:ok, update} = Yex.encode_state_as_update(doc)
      Base.encode64(update)
    end

    test "an open room closes when the actor's grant is narrowed, with nothing evicting",
         %{page: page} do
      # THE test for this issue. `Ash.Seed.update!` writes the row directly, so
      # no action runs and `SessionEviction` never fires — this is the gap
      # direction (1) cannot close: the change nobody remembered to wire in.
      #
      # It is also the test that fails if the check stops reloading the actor.
      # Re-running the policies against the struct the socket connected with
      # re-derives the same answer from the same stale scopes forever.
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 50)

      editor = user(:editor)
      {_reply, socket} = join!(editor, topic(page))
      channel = socket.channel_pid

      Ash.Seed.update!(editor, %{editable_types: ["post"]})

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
    end

    test "a room whose authorization still holds survives its checks and keeps relaying",
         %{actor: actor, page: page} do
      # The negative control, and not a formality: a mechanism that closed every
      # room would pass the test above while making the feature useless.
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 50)

      {_reply, socket} = join!(actor, topic(page))
      channel = socket.channel_pid

      refute_receive {:EXIT, ^channel, _reason}, 400

      ref = push(socket, "update", %{"update" => yjs_update("still here")})
      assert_reply ref, :ok
    end

    test "a document moved out of the actor's audience under an open room is caught",
         %{actor: admin} do
      # The other half of the acceptance: a change to the DOCUMENT, not the user.
      #
      # This editor reads pages only as a consumer does — `readable_types` covers
      # posts, so the page policy's `published and public` grant is what admits
      # the read — while `editable_types` still authorizes the `:autosave` write
      # the room is gated on. So the room is theirs at join, and the audience
      # alone decides whether it stays theirs.
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 50)

      published =
        admin |> draft_page!() |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      restricted = user(:editor, readable_types: ["post"])
      {_reply, socket} = join!(restricted, topic(published))
      channel = socket.channel_pid

      Ash.Seed.update!(published, %{audience: :member})

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
    end

    test "a document whose state changes under an open room is caught", %{actor: admin} do
      # Same editor, same room, the other attribute the acceptance names: taking
      # the page back out of `:published` withdraws the grant their read stood on.
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 50)

      published =
        admin |> draft_page!() |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      restricted = user(:editor, readable_types: ["post"])
      {_reply, socket} = join!(restricted, topic(published))
      channel = socket.channel_pid

      Ash.Seed.update!(published, %{state: :draft})

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
    end

    test "the update floor refuses a busy room without waiting for the timer", %{page: page} do
      # A timer alone bounds the exposure window but not the number of writes: at
      # typing speed a room emits several updates a second. The floor is what
      # makes that a bounded number, so the interval is set out of reach here to
      # prove the count is doing the work and not the clock.
      Application.put_env(:kiln_cms, :socket_reauth_interval_ms, 60_000)
      Application.put_env(:kiln_cms, :socket_reauth_update_floor, 3)

      editor = user(:editor)
      {_reply, socket} = join!(editor, topic(page))
      channel = socket.channel_pid

      Ash.Seed.update!(editor, %{editable_types: ["post"]})

      # Two ride the authorization the join established.
      for text <- ["one", "two"] do
        ref = push(socket, "update", %{"update" => yjs_update(text)})
        assert_reply ref, :ok
      end

      # The third trips the floor, and is refused rather than being the last one
      # through — the check runs before the update is applied.
      push(socket, "update", %{"update" => yjs_update("three")})

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
    end
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

  describe "per-account event budget (#1305)" do
    # `subscribe_and_join/3` runs every socket a test opens with the TEST
    # process as its transport, so the transport-bound side of a refusal (the
    # disconnect the client recovers from) lands in this mailbox and can be
    # asserted like any other push. Joins spend frames too, so each limit below
    # is written as `joins + frames`. The budget's own mechanics (two accounts,
    # two budgets; a reconnect keeps the key) are `SocketEventBudgetTest`'s.
    setup do
      RateLimitHelpers.restore_limits_on_exit()

      # Same reason as the #775 block: a room that closes itself takes a linked
      # test process with it unless exits are trapped.
      Process.flag(:trap_exit, true)
      :ok
    end

    @event_bucket :collab_event

    defp put_event_limit(limit), do: RateLimitHelpers.put_limit(@event_bucket, limit)

    test "the frame over the ceiling closes the connection; the ones under it are served",
         %{actor: actor, page: page} do
      # A room with a peer, so "served" is observable: the peer's transport (this
      # process) receives each relayed awareness frame. Two joins + two frames
      # under the limit; the third frame is over.
      put_event_limit(2 + 2)
      topic = topic(page)
      {_reply, sender} = join!(actor, topic)
      {_reply2, _peer} = join!(actor, topic)
      channel = sender.channel_pid

      push(sender, "awareness", %{"cursor" => 1})
      assert_push "awareness", %{"cursor" => 1}
      push(sender, "awareness", %{"cursor" => 2})
      assert_push "awareness", %{"cursor" => 2}

      push(sender, "awareness", %{"cursor" => 3})

      # What the client sees: its CONNECTION told to close (phoenix.js
      # reconnects and rejoins from that), not merely a `phx_close` for one
      # channel (which it would treat as a finished leave and never rejoin).
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 2_000
      assert_receive {:EXIT, ^channel, {:shutdown, :over_budget}}, 2_000
      refute_push "awareness", %{"cursor" => 3}
    end

    test "the charge runs before the frame's work: an over-budget update is never applied",
         %{actor: actor, page: page} do
      # A peer would receive the relay if the update had been served, and the
      # doc server would hold its text. Limit = the two joins; the update itself
      # is the frame over.
      put_event_limit(2)
      topic = topic(page)
      {_reply, sender} = join!(actor, topic)
      {_reply2, _peer} = join!(actor, topic)
      channel = sender.channel_pid

      ref = push(sender, "update", %{"update" => yjs_update("flood")})

      assert_receive {:EXIT, ^channel, {:shutdown, :over_budget}}, 2_000
      refute_reply ref, :ok
      refute_push "update", %{"update" => _}
    end

    test "unknown and wrong-shaped frames count too", %{actor: actor, page: page} do
      # #764 made these free to send (ignored, not crashed). They are still
      # frames from the account, and a flood of them is still a flood.
      put_event_limit(1 + 1)
      {_reply, socket} = join!(actor, topic(page))
      channel = socket.channel_pid

      push(socket, "no_such_event", %{})
      push(socket, "update", %{"update" => []})

      assert_receive {:EXIT, ^channel, {:shutdown, :over_budget}}, 2_000
    end

    test "the budget follows the account across a reconnect, and rejoins are refused before authorization",
         %{actor: actor, page: page} do
      # The amplifier a per-connection key would have left open: a closed
      # connection's client reconnects (a fresh transport), and each `join/3`
      # costs three authorization reads if it gets that far. The key is the
      # account, so the rejoin over the NEW socket lands on the spent budget —
      # and is refused with "over budget", not "not found", even for a topic
      # that names no document at all: proof `authorize/3` never ran.
      put_event_limit(1)
      {_reply, socket} = join!(actor, topic(page))
      channel = socket.channel_pid

      push(socket, "awareness", %{})
      assert_receive {:EXIT, ^channel, {:shutdown, :over_budget}}, 2_000
      # The frame refusal closed the (test-process) transport once — take that
      # message, so the join refusals below can be shown NOT to add one.
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 2_000

      reconnected = socket!(actor)

      assert {:error, %{reason: "over budget"}} =
               subscribe_and_join(reconnected, topic(page), %{"vsn" => @schema_vsn})

      assert {:error, %{reason: "over budget"}} =
               subscribe_and_join(reconnected, "collab:page:#{Ash.UUID.generate()}", %{
                 "vsn" => @schema_vsn
               })

      # A refused JOIN does not close the connection: phoenix.js already retries
      # a refused join on a backoff, and closing would only make it dearer.
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      # Another account over the very same transport is unaffected — the key is
      # the actor, not the process the sockets run in.
      assert {:ok, %{"peers" => _}, _joined} =
               subscribe_and_join(socket!(user(:admin)), topic(page), %{"vsn" => @schema_vsn})
    end

    test "the join is charged ahead of the flag and schema checks", %{actor: actor, page: page} do
      # A join the room refuses anyway still costs a frame and still counts, so
      # a flood of doomed joins cannot run for free. Limit 1: the first refused
      # join spends it; the second is refused for the budget, not the schema.
      put_event_limit(1)
      socket = socket!(actor)

      assert {:error, %{reason: "stale bundle"}} = subscribe_and_join(socket, topic(page), %{})
      assert {:error, %{reason: "over budget"}} = subscribe_and_join(socket, topic(page), %{})
    end

    test "awareness_request is relayed at most once per interval per channel",
         %{actor: actor, page: page} do
      # Each relay makes every peer send an awareness frame of their own and pay
      # for it, so an unbounded relay lets one seat spend the whole room's
      # budget. Two requests back to back: one relay.
      topic = topic(page)
      {_reply, requester} = join!(actor, topic)
      {_reply2, _peer} = join!(actor, topic)

      push(requester, "awareness_request", %{})
      assert_push "awareness_request", %{}
      push(requester, "awareness_request", %{})
      refute_push "awareness_request", %{}
    end
  end
end
