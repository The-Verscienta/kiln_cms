defmodule KilnCMSWeb.ChangeFeedControllerTest do
  @moduledoc """
  `GET /api/feed` — the change feed over SSE (#2275, `KilnCMSWeb.FeedStream`).

  A stream is a long-lived chunked response. Under `Phoenix.ConnTest` its
  chunks are readable only once the action returns, so each stream runs in a
  `Task` (whose `$callers` carry the sandbox), the test publishes and waits for
  the relay (`Feed.sync/1`), and then ends the stream the way a deploy does —
  `FeedStream.shutdown_message/0` — and reads everything it wrote. Messages
  reach the stream in order, so an event the relay delivered before the
  shutdown message is written before it. A stream's process is learned from
  its `:connect` telemetry, emitted once it is live.

  A dropped client is a sink (`conn.private[:kiln_feed_sink]`) that answers
  `{:error, :closed}`, which is what `Plug.Conn.chunk/2` answers then.
  """
  # async: false — the commit lag, the stream limits and the rate limits are
  # application config, the drain flag is node-wide, and the caps count every
  # stream on the node.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Delivery.Feed
  alias KilnCMS.Firing.SyncCursor
  alias KilnCMS.RateLimitHelpers
  alias KilnCMSWeb.FeedStream
  alias KilnCMSWeb.FeedStream.Drainer

  @gated hd(Audiences.gated())

  setup do
    previous_sync = Application.get_env(:kiln_cms, KilnCMS.Firing.Sync)
    previous_stream = Application.get_env(:kiln_cms, FeedStream)
    # Every write here has committed (to the sandbox) before the next request;
    # a test cannot wait out a ten-second lag per resume.
    Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, commit_lag_seconds: 0)

    test_pid = self()
    handler = "feed-sse-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:kiln_cms, :delivery, :feed, :sse, :connect],
        [:kiln_cms, :delivery, :feed, :sse, :disconnect]
      ],
      fn
        [_, _, _, _, :connect], _measurements, metadata, _config ->
          send(test_pid, {:sse_connected, metadata.stream})

        [_, _, _, _, :disconnect], _measurements, metadata, _config ->
          send(test_pid, {:sse_disconnected, metadata.reason})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      restore(KilnCMS.Firing.Sync, previous_sync)
      restore(FeedStream, previous_stream)
      Drainer.undrain()
    end)

    KilnCMS.Cache.bust_published()

    org =
      Ash.Seed.seed!(Accounts.Organization, %{
        name: "Feed Site",
        slug: "feed-#{System.unique_integer([:positive])}",
        status: :active
      })

    %{org: org, admin: user(:admin)}
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp stream_config(settings) do
    current = Application.get_env(:kiln_cms, FeedStream, [])
    Application.put_env(:kiln_cms, FeedStream, Keyword.merge(current, settings))
  end

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "feed-sse-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # Minted by an admin: only an admin may create a key, for anyone.
  defp key_for(user, admin) do
    user.id
    |> Accounts.mint_api_key!("feed", DateTime.add(DateTime.utc_now(), 1, :day), actor: admin)
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  # ── Content ──────────────────────────────────────────────────────────────

  defp post!(ctx, attrs \\ %{}) do
    CMS.create_post!(
      Map.merge(
        %{
          title: "Post #{System.unique_integer([:positive])}",
          slug: "feed-post-#{System.unique_integer([:positive])}"
        },
        attrs
      ),
      actor: ctx.admin,
      tenant: ctx.org
    )
  end

  defp published_post!(ctx, attrs \\ %{}),
    do: ctx |> post!(attrs) |> CMS.publish_post!(%{}, actor: ctx.admin, tenant: ctx.org)

  defp published_page!(ctx) do
    %{title: "A page", slug: "feed-page-#{System.unique_integer([:positive])}"}
    |> CMS.create_page!(actor: ctx.admin, tenant: ctx.org)
    |> CMS.publish_page!(%{}, actor: ctx.admin, tenant: ctx.org)
  end

  defp unpublish!(post, ctx),
    do: CMS.unpublish_post!(post, %{}, actor: ctx.admin, tenant: ctx.org)

  # ── Streams ──────────────────────────────────────────────────────────────

  defp feed_conn(conn, ctx, opts) do
    conn =
      conn
      |> org_conn(ctx.org)
      |> put_req_header("accept", "text/event-stream")

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    case Keyword.get(opts, :sink) do
      nil -> conn
      sink -> Plug.Conn.put_private(conn, :kiln_feed_sink, sink)
    end
  end

  # A stream that has gone live (sent `ready`), and its process.
  defp open(conn, ctx, opts \\ []) do
    stream = start(conn, ctx, opts)
    assert_receive {:sse_connected, pid}, 5_000
    Map.put(stream, :pid, pid)
  end

  # A request in flight, live or not.
  defp start(conn, ctx, opts) do
    conn = feed_conn(conn, ctx, opts)
    path = Keyword.get(opts, :path, "/api/feed")
    %{task: Task.async(fn -> get(conn, path) end)}
  end

  # End a live stream as a deploy would, and parse everything it wrote.
  defp close(%{task: task, pid: pid}) do
    send(pid, FeedStream.shutdown_message())
    task |> Task.await() |> frames()
  end

  # A request that ends on its own (a refusal, a dropped client).
  defp finish(%{task: task}), do: task |> Task.await() |> frames()

  defp frames(%Plug.Conn{} = conn) do
    assert conn.status == 200
    assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
    frames(conn.resp_body)
  end

  defp frames(body) when is_binary(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      block
      |> String.split("\n")
      |> Map.new(fn
        ": " <> comment ->
          {"comment", comment}

        line ->
          [field, value] = String.split(line, ": ", parts: 2)
          {field, if(field == "data", do: Jason.decode!(value), else: value)}
      end)
    end)
  end

  @content ~w(published updated withdrawn)

  # `{event, id}` of every content event, in order.
  defp content(frames),
    do:
      for(
        %{"event" => event, "data" => %{"id" => id}} <- frames,
        event in @content,
        do: {event, id}
      )

  defp control(frames, name), do: Enum.filter(frames, &(&1["event"] == name))

  defp sync!(conn, ctx, params) do
    conn
    |> org_conn(ctx.org)
    |> get("/api/sync", params)
    |> json_response(200)
  end

  # ── Visibility ───────────────────────────────────────────────────────────

  describe "what a stream carries" do
    test "the anonymous view, identical for anonymous, editor-key and admin-key streams",
         %{conn: conn} = ctx do
      anonymous = open(conn, ctx)

      editor =
        open(build_conn(), ctx,
          headers: [{"authorization", "Bearer " <> key_for(user(:editor), ctx.admin)}]
        )

      admin =
        open(build_conn(), ctx,
          headers: [{"authorization", "Bearer " <> key_for(ctx.admin, ctx.admin)}]
        )

      public = published_post!(ctx)
      _members = published_post!(ctx, %{audience: @gated})
      _locked = published_post!(ctx, %{access_password: "shared secret"})
      _draft = post!(ctx)

      moved = published_post!(ctx)
      CMS.update_post!(moved, %{audience: @gated}, actor: ctx.admin, tenant: ctx.org)

      deleted = published_post!(ctx)
      CMS.destroy_post!(deleted, actor: ctx.admin, tenant: ctx.org)

      never_public = published_post!(ctx, %{audience: @gated})
      CMS.destroy_post!(never_public, actor: ctx.admin, tenant: ctx.org)

      :ok = Feed.sync(ctx.org)
      [anon_frames, editor_frames, admin_frames] = Enum.map([anonymous, editor, admin], &close/1)

      expected = [
        {"published", public.id},
        {"published", moved.id},
        {"withdrawn", moved.id},
        {"published", deleted.id},
        {"withdrawn", deleted.id}
      ]

      assert content(anon_frames) == expected
      assert content(editor_frames) == expected
      assert content(admin_frames) == expected

      for %{"event" => event} = frame <- anon_frames, event in @content do
        # Every live event can be resumed from.
        assert {:ok, %{position: {:delta, _since, nil, nil}}} =
                 SyncCursor.verify(frame["id"], ctx.org.id)

        case event do
          "withdrawn" -> assert Map.keys(frame["data"]) |> Enum.sort() == ["id", "type"]
          _shown -> assert frame["data"]["affected"] == []
        end
      end

      assert [%{"data" => %{"resumed" => false}, "id" => _}] = control(anon_frames, "ready")
      assert [%{"data" => %{}}] = control(anon_frames, "shutdown")
    end

    test "`type=` narrows the stream, and its ids are scoped to the type", %{conn: conn} = ctx do
      stream = open(conn, ctx, path: "/api/feed?type=page")
      _post = published_post!(ctx)
      page = published_page!(ctx)
      :ok = Feed.sync(ctx.org)

      frames = close(stream)
      assert content(frames) == [{"published", page.id}]

      [%{"id" => id}] = Enum.filter(frames, &(&1["event"] == "published"))
      assert {:ok, %{type: "page"}} = SyncCursor.verify(id, ctx.org.id)
    end

    test "an unknown type is a 404, as on /api/sync", %{conn: conn} = ctx do
      conn = conn |> feed_conn(ctx, []) |> get("/api/feed?type=nope")
      assert conn.status == 404
      assert FeedStream.streams() == []
    end

    test "an invalid key is the same 401 as on /api/sync", %{conn: conn} = ctx do
      bad = [{"authorization", "Bearer kiln_not_a_real_key"}]

      feed = conn |> feed_conn(ctx, headers: bad) |> get("/api/feed")

      sync =
        build_conn()
        |> org_conn(ctx.org)
        |> put_req_header("authorization", "Bearer kiln_not_a_real_key")
        |> get("/api/sync?initial=true")

      assert feed.status == 401
      assert sync.status == 401
      assert FeedStream.streams() == []
    end

    test "HEAD answers the stream's headers and holds no slot", %{conn: conn} = ctx do
      conn = conn |> feed_conn(ctx, []) |> head("/api/feed")

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
      assert conn.resp_body == ""
      refute_received {:sse_connected, _pid}
      assert FeedStream.streams() == []
    end
  end

  # ── Resume ───────────────────────────────────────────────────────────────

  describe "resume" do
    test "replays what was missed, then goes live; the id works on /api/sync too",
         %{conn: conn} = ctx do
      first = open(conn, ctx)
      a = published_post!(ctx)
      :ok = Feed.sync(ctx.org)
      [%{"id" => last_id}] = first |> close() |> Enum.filter(&(&1["event"] == "published"))

      # Missed while disconnected.
      b = published_post!(ctx)
      unpublish!(a, ctx)

      # The same id on the polling transport. It needs b's artifact.
      KilnCMS.DataCase.drain_oban()
      %{"items" => items} = sync!(build_conn(), ctx, %{"cursor" => last_id})
      polled = for %{"op" => op, "id" => id} <- items, do: {op, id}

      second = open(conn, ctx, headers: [{"last-event-id", last_id}])
      c = published_post!(ctx)
      :ok = Feed.sync(ctx.org)
      frames = close(second)

      {replayed, [ready | live]} = Enum.split_while(frames, &(&1["event"] != "ready"))
      replayed = Enum.reject(replayed, &Map.has_key?(&1, "retry"))

      assert Enum.sort(content(replayed)) == Enum.sort([{"published", b.id}, {"withdrawn", a.id}])
      # Replayed events carry no id: the client keeps the one it sent.
      refute Enum.any?(replayed, &Map.has_key?(&1, "id"))

      # Parity with /api/sync from the same cursor: upsert ↔ published or
      # updated, delete ↔ withdrawn.
      as_ops =
        for {event, id} <- content(replayed),
            do: {if(event == "withdrawn", do: "delete", else: "upsert"), id}

      assert Enum.sort(as_ops) == Enum.sort(polled)

      assert ready["data"] == %{"resumed" => true}
      assert {:ok, _cursor} = SyncCursor.verify(ready["id"], ctx.org.id)
      assert {"published", c.id} in content(live)
    end

    test "a mid-delta /api/sync cursor resumes from its start, past its fixed end",
         %{conn: conn} = ctx do
      _before = published_post!(ctx)
      KilnCMS.DataCase.drain_oban()
      %{"cursor" => cursor, "has_more" => false} = sync!(conn, ctx, %{"initial" => "true"})

      changed = for _ <- 1..3, do: published_post!(ctx)
      KilnCMS.DataCase.drain_oban()

      # One page into a three-document delta: the cursor holds that delta's
      # `until`, fixed when its first page was read.
      %{"cursor" => mid, "has_more" => true} =
        sync!(build_conn(), ctx, %{"cursor" => cursor, "limit" => "1"})

      later = published_post!(ctx)

      frames = conn |> open(ctx, headers: [{"last-event-id", mid}]) |> close()
      replayed = frames |> Enum.take_while(&(&1["event"] != "ready")) |> content()

      for post <- [later | changed] do
        assert {"published", post.id} in replayed
      end
    end

    test "a client dropped partway through a replay resumes with the id it had",
         %{conn: conn} = ctx do
      cursor = SyncCursor.sign(ctx.org.id, nil, :json, {:delta, DateTime.utc_now(), nil, nil})
      missed = for _ <- 1..3, do: published_post!(ctx)

      # The connection dies on the replay's first write: no event, and no
      # new id, reached the client.
      drop = fn conn, data ->
        if IO.iodata_to_binary(data) =~ "event: published",
          do: {:error, :closed},
          else: Plug.Conn.chunk(conn, data)
      end

      dropped = conn |> start(ctx, headers: [{"last-event-id", cursor}], sink: drop) |> finish()
      assert content(dropped) == []
      assert control(dropped, "ready") == []
      assert FeedStream.streams() == []

      # Reconnecting with that same id misses nothing.
      frames = conn |> open(ctx, headers: [{"last-event-id", cursor}]) |> close()
      assert Enum.sort(content(frames)) == Enum.sort(for p <- missed, do: {"published", p.id})
    end

    test "the cursor's type wins over `type=`", %{conn: conn} = ctx do
      cursor = SyncCursor.sign(ctx.org.id, "post", :json, {:delta, DateTime.utc_now(), nil, nil})
      stream = open(conn, ctx, path: "/api/feed?type=page", headers: [{"last-event-id", cursor}])

      post = published_post!(ctx)
      _page = published_page!(ctx)
      :ok = Feed.sync(ctx.org)

      assert content(close(stream)) == [{"published", post.id}]
    end

    test "the id may come as `last_event_id` for a client that cannot set headers",
         %{conn: conn} = ctx do
      cursor = SyncCursor.sign(ctx.org.id, nil, :json, {:delta, DateTime.utc_now(), nil, nil})
      missed = published_post!(ctx)

      frames =
        conn
        |> open(ctx, path: "/api/feed?" <> URI.encode_query(%{"last_event_id" => cursor}))
        |> close()

      assert {"published", missed.id} in content(frames)
      assert [%{"data" => %{"resumed" => true}}] = control(frames, "ready")
    end

    test "a cursor that does not verify, or an initial one, is a reset; the stream stays live",
         %{conn: conn} = ctx do
      for _ <- 1..2, do: published_post!(ctx)
      KilnCMS.DataCase.drain_oban()

      %{"cursor" => initial, "has_more" => true} =
        sync!(conn, ctx, %{"initial" => "true", "limit" => "1"})

      for bad <- ["not-a-cursor", initial] do
        stream = open(build_conn(), ctx, headers: [{"last-event-id", bad}])
        live = published_post!(ctx)
        :ok = Feed.sync(ctx.org)
        frames = close(stream)

        assert [%{"data" => %{"reason" => "invalid_cursor"}, "id" => id}] =
                 control(frames, "reset")

        assert {:ok, _cursor} = SyncCursor.verify(id, ctx.org.id)
        assert [%{"data" => %{"resumed" => false}}] = control(frames, "ready")
        assert content(frames) == [{"published", live.id}]
      end
    end

    test "a replay over the cap across several pages sends nothing before the reset",
         %{conn: conn} = ctx do
      # One document a page: the third page is the one over the cap.
      stream_config(replay_limit: 2, replay_page: 1)
      cursor = SyncCursor.sign(ctx.org.id, nil, :json, {:delta, DateTime.utc_now(), nil, nil})
      for _ <- 1..3, do: published_post!(ctx)

      frames = conn |> open(ctx, headers: [{"last-event-id", cursor}]) |> close()

      {before_reset, [reset | _]} = Enum.split_while(frames, &(&1["event"] != "reset"))
      assert reset["data"] == %{"reason" => "too_far_behind"}
      assert content(before_reset) == []
      assert content(frames) == []
    end

    test "a replay that fits spans pages and is sent whole", %{conn: conn} = ctx do
      stream_config(replay_limit: 3, replay_page: 1)
      cursor = SyncCursor.sign(ctx.org.id, nil, :json, {:delta, DateTime.utc_now(), nil, nil})
      missed = for _ <- 1..3, do: published_post!(ctx)

      frames = conn |> open(ctx, headers: [{"last-event-id", cursor}]) |> close()

      assert Enum.sort(content(frames)) == Enum.sort(for p <- missed, do: {"published", p.id})
      assert [%{"data" => %{"resumed" => true}}] = control(frames, "ready")
    end

    test "a replay longer than the cap is a reset, and nothing is replayed",
         %{conn: conn} = ctx do
      stream_config(replay_limit: 2)
      cursor = SyncCursor.sign(ctx.org.id, nil, :json, {:delta, DateTime.utc_now(), nil, nil})
      for _ <- 1..3, do: published_post!(ctx)

      frames = conn |> open(ctx, headers: [{"last-event-id", cursor}]) |> close()

      assert [%{"data" => %{"reason" => "too_far_behind"}}] = control(frames, "reset")
      assert content(frames) == []
      assert [%{"data" => %{"resumed" => false}}] = control(frames, "ready")
    end

    test "a cursor older than the resume window is a reset", %{conn: conn} = ctx do
      stream_config(resume_window_seconds: 3_600)
      old = DateTime.add(DateTime.utc_now(), -2, :hour)
      cursor = SyncCursor.sign(ctx.org.id, nil, :json, {:delta, old, nil, nil})
      _missed = published_post!(ctx)

      frames = conn |> open(ctx, headers: [{"last-event-id", cursor}]) |> close()

      assert [%{"data" => %{"reason" => "too_far_behind"}}] = control(frames, "reset")
      assert content(frames) == []
    end
  end

  # ── Limits ───────────────────────────────────────────────────────────────

  describe "limits" do
    defp busy_reason(frames) do
      assert [%{"retry" => retry} | _] = Enum.filter(frames, &Map.has_key?(&1, "retry"))
      assert String.to_integer(retry) > 0
      [%{"data" => %{"reason" => reason}}] = control(frames, "busy")
      reason
    end

    test "one client over its stream cap is told to come back; a closed stream frees its slot",
         %{conn: conn} = ctx do
      stream_config(max_per_client: 1)
      held = open(conn, ctx)

      refused = conn |> start(ctx, []) |> finish()
      assert busy_reason(refused) == "too_many_streams"

      close(held)
      conn |> open(ctx) |> close()
    end

    test "an API key is its own client, wherever it connects from", %{conn: conn} = ctx do
      stream_config(max_per_client: 1)
      key = [{"authorization", "Bearer " <> key_for(ctx.admin, ctx.admin)}]
      held = open(conn, ctx, headers: key)

      refused = build_conn() |> start(ctx, headers: key) |> finish()
      assert busy_reason(refused) == "too_many_streams"

      # The address the key first came from is not spent by it.
      conn |> open(ctx) |> close()
      close(held)
    end

    test "a full node is told to come back", %{conn: conn} = ctx do
      stream_config(max_per_node: 1)
      held = open(conn, ctx)

      refused = build_conn() |> start(ctx, []) |> finish()
      assert busy_reason(refused) == "node_full"

      close(held)
    end

    test "resumes past the replay gate are told to come back", %{conn: conn} = ctx do
      stream_config(max_replays: 0)
      cursor = SyncCursor.sign(ctx.org.id, nil, :json, {:delta, DateTime.utc_now(), nil, nil})

      refused = conn |> start(ctx, headers: [{"last-event-id", cursor}]) |> finish()
      assert busy_reason(refused) == "replay_busy"
      assert FeedStream.streams() == []
    end

    test "connects over the `:feed_join` budget are told to come back, not refused for good",
         %{conn: conn} = ctx do
      RateLimitHelpers.restore_limits_on_exit()
      RateLimitHelpers.put_limit(:feed_join, 1)

      # Charged first, even for a HEAD.
      assert conn |> feed_conn(ctx, []) |> head("/api/feed") |> Map.fetch!(:status) == 200

      # A 200 an `EventSource` reads and retries, never the 429 it would stop
      # on; the retry is at least the bucket's own retry-after.
      refused = conn |> start(ctx, []) |> finish()
      assert busy_reason(refused) == "rate_limited"
      [%{"retry" => retry} | _] = Enum.filter(refused, &Map.has_key?(&1, "retry"))
      assert String.to_integer(retry) >= 1_000
      assert FeedStream.streams() == []
    end

    test "a reader slower than the feed is ended, to resume from its last id",
         %{conn: conn} = ctx do
      # One, not zero: the request process always holds Plug's own
      # `{:plug_conn, :sent}` note, which is not the stream's to consume.
      stream_config(max_queue: 1)
      test_pid = self()

      # Holds the first event's write until the test has queued another.
      hold = fn conn, data ->
        if IO.iodata_to_binary(data) =~ "event: published" and !Process.get(:held) do
          Process.put(:held, true)
          send(test_pid, {:held, self()})

          receive do
            :go -> :ok
          end
        end

        Plug.Conn.chunk(conn, data)
      end

      stream = open(conn, ctx, sink: hold)
      first = published_post!(ctx)
      :ok = Feed.sync(ctx.org)
      assert_receive {:held, pid}, 5_000

      # Two more behind it: handling the second, the stream finds the third
      # still waiting, past the bound.
      _behind = for _ <- 1..2, do: published_post!(ctx)
      :ok = Feed.sync(ctx.org)
      send(pid, :go)

      frames = finish(stream)
      assert content(frames) == [{"published", first.id}]
      assert %{"retry" => _} = List.last(frames)
      assert_receive {:sse_disconnected, :slow}
      assert FeedStream.streams() == []
    end
  end

  # ── Liveness and shutdown ────────────────────────────────────────────────

  describe "heartbeat" do
    test "a comment every `heartbeat_ms`", %{conn: conn} = ctx do
      stream_config(heartbeat_ms: 10)
      test_pid = self()

      tap = fn conn, data ->
        send(test_pid, {:wrote, IO.iodata_to_binary(data)})
        Plug.Conn.chunk(conn, data)
      end

      stream = open(conn, ctx, sink: tap)
      assert_receive {:wrote, ": ping\n\n"}, 2_000
      assert_receive {:wrote, ": ping\n\n"}, 2_000
      close(stream)
    end

    test "finds a client that has gone, and frees its slot", %{conn: conn} = ctx do
      stream_config(heartbeat_ms: 10)

      gone = fn conn, data ->
        if IO.iodata_to_binary(data) == ": ping\n\n",
          do: {:error, :closed},
          else: Plug.Conn.chunk(conn, data)
      end

      stream = open(conn, ctx, sink: gone)
      finish(stream)

      assert_receive {:sse_disconnected, :closed}
      assert FeedStream.streams() == []
    end
  end

  describe "the request process" do
    test "an exit signal from the connection's handler ends the stream", %{conn: conn} = ctx do
      stream = open(conn, ctx)
      send(stream.pid, {:EXIT, self(), :shutdown})

      finish(stream)
      assert_receive {:sse_disconnected, :closed}
      assert FeedStream.streams() == []
    end
  end

  describe "shutdown" do
    test "the drain ends every stream with a retry, and refuses new ones", %{conn: conn} = ctx do
      stream = open(conn, ctx)

      :ok = Drainer.drain()
      assert Drainer.draining?()

      frames = finish(stream)
      assert [%{"event" => "shutdown"}] = control(frames, "shutdown")
      assert %{"retry" => _} = Enum.at(frames, -2)
      assert FeedStream.streams() == []

      refused = build_conn() |> start(ctx, []) |> finish()
      assert busy_reason(refused) == "shutting_down"
    end
  end
end
