defmodule KilnCMSWeb.FeedStream do
  @moduledoc """
  `GET /api/feed` — the change feed (`KilnCMS.Delivery.Feed`) as Server-Sent
  Events (#2275, path forward 2.2). `KilnCMSWeb.ChangeFeedController` resolves the
  request; this module runs the stream in the request's own process.

  ## What a stream carries

  Exactly what an anonymous caller of `GET /api/sync` may learn, whoever
  connects (an editor's or admin's key gets the same stream). Each event's
  `anonymous` view is decided once, in the publisher; a stream only forwards
  the frame the publisher encoded (`Feed.Event.sse`):

      event: published | updated
      id: <cursor>
      data: {"type", "id", "slug", "locale", "published_at", "affected": []}

      event: withdrawn
      id: <cursor>
      data: {"type", "id"}

  `withdrawn` names only an id that was public (see "The anonymous view" in
  `KilnCMS.Delivery.Feed`). `affected` is always empty: the publisher's list is
  not filtered by audience. `?type=<name>` narrows the stream to one content
  type.

  Control events: `ready` (`{"resumed": bool}`, with an id) once the stream is
  live; `reset` (`{"reason": "invalid_cursor" | "too_far_behind"}`, with a
  fresh id) when a resume cannot be honoured — the client re-syncs through
  `GET /api/sync?initial=true` and keeps the stream; `busy`
  (`{"reason": …}`) when the stream is refused, and `shutdown` when the node
  is going away, each after a `retry:` and followed by the end of the
  response. A `: ping` comment every `heartbeat_ms` keeps proxies from closing
  an idle stream, and finds a client that has gone.

  ## Ids and resume

  Every `id:` is a `GET /api/sync` delta cursor (`KilnCMS.Firing.SyncCursor`)
  whose `since` is the event's time minus the sync API's commit lag, so the
  same string resumes either transport. On a reconnect (`Last-Event-ID`, or a
  `last_event_id` query parameter for a client that cannot set headers) the
  stream subscribes first, then replays `Sync.page(…, bodies: false,
  commit_lag: 0)` from the cursor's `since` — `published` when the document
  was first published inside the window, else `updated`, and `withdrawn` for a
  tombstone. Replayed events carry no `id:` (the client keeps the one it sent);
  `ready` carries the new one, and live events that arrived meanwhile follow
  it. Every event is idempotent for the client, and both the lag and the
  replay/live overlap can repeat one.

  The replay inherits the sync API's commit-lag assumption ("Consistency" in
  `KilnCMS.Firing.Sync`): a transaction held open longer than the lag — a long
  release go-live, say — can write versions whose time a reconnecting client's
  window has already passed, and those changes are missed across the
  reconnect.

  A cursor's type wins over `?type=`, as on `/api/sync`. A cursor older than
  `resume_window_seconds`, or a replay longer than `replay_limit` events, is a
  `reset` with reason `too_far_behind`; a cursor that does not verify, or one
  still paging an initial snapshot, is a `reset` with reason `invalid_cursor`.
  A database outage during a replay ends the response after a `retry:`, and
  the client reconnects with the same id.

  ## Limits (per node)

  Every refusal of the stream's own answers `200` with a jittered `retry:` and
  `event: busy`, then ends: a native `EventSource` reads it, waits, and
  reconnects. The reasons:

    * `rate_limited` — over the `:feed_join` bucket (`KilnCMSWeb.RateLimit`,
      connects per client address, charged first, by
      `KilnCMSWeb.FeedStream.JoinBudget`); the `retry:` is the bucket's
      `retry_after`, plus up to as much again, so a refused crowd does not
      come back together;
    * `too_many_streams` — over `max_per_client` open streams for one API key,
      or for one client address without a key (clients behind one NAT share
      it);
    * `node_full` — over `max_per_node` open streams on this node;
    * `replay_busy` — over `max_replays` resumes replaying at once;
    * `shutting_down` — the node is draining (`KilnCMSWeb.FeedStream.Drainer`).

  The `:api` bucket's own refusal stays the `429` every `/api` route answers
  (`KilnCMSWeb.Plugs.RateLimit`), and so do a bad credential (`401`) and an
  unknown type (`404`): a native `EventSource` stops for good on any of them.

  A stream whose mailbox grows past `max_queue` messages (a reader slower than
  the feed) is ended with a `retry:`, and resumes from its last id.

      config :kiln_cms, KilnCMSWeb.FeedStream,
        max_per_client: 50,
        max_per_node: 20_000,
        max_replays: 8,
        heartbeat_ms: 25_000,
        retry_ms: 3_000,
        busy_retry_ms: 10_000,
        shutdown_retry_ms: 10_000,
        replay_limit: 1_000,
        replay_page: 100,
        resume_window_seconds: 86_400,
        max_queue: 1_000

  ## Telemetry

  `[:kiln_cms, :delivery, :feed, :sse, :connect]` (`%{count: 1}`, metadata
  `org_id`, `resumed`, `stream`), `… :disconnect` (`%{count: 1, duration}`,
  metadata `org_id`, `reason`), `… :replay` (`%{events: n}`, metadata
  `org_id`) and `… :refused` (`%{count: 1}`, metadata `reason`).
  """
  import Plug.Conn

  alias KilnCMS.Delivery.Feed
  alias KilnCMS.Firing.Sync
  alias KilnCMS.Firing.SyncCursor
  alias KilnCMSWeb.FeedStream.Drainer

  @streams KilnCMSWeb.FeedStream.Streams
  @replays KilnCMSWeb.FeedStream.Replays
  @telemetry [:kiln_cms, :delivery, :feed, :sse]

  @defaults [
    max_per_client: 50,
    max_per_node: 20_000,
    max_replays: 8,
    heartbeat_ms: 25_000,
    retry_ms: 3_000,
    busy_retry_ms: 10_000,
    shutdown_retry_ms: 10_000,
    replay_limit: 1_000,
    replay_page: 100,
    resume_window_seconds: 86_400,
    max_queue: 1_000
  ]

  @typedoc """
  A resolved request: the site, the type filter, the client the per-client
  cap counts, and what to do about a `Last-Event-ID`.
  """
  @type scope :: %{
          org_id: Ash.UUID.t(),
          type: String.t() | nil,
          client: String.t(),
          resume: nil | {:since, DateTime.t()} | {:reset, String.t()}
        }

  @doc "The setting `key` (see the moduledoc's config block)."
  @spec config(atom()) :: term()
  def config(key) do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get_lazy(key, fn -> Keyword.fetch!(@defaults, key) end)
  end

  @doc "The Registry every open stream is registered in, keyed by its client."
  def streams_registry, do: @streams

  @doc "The pids of this node's open streams."
  @spec streams() :: [pid()]
  def streams, do: Registry.select(@streams, [{{:_, :"$1", :_}, [], [:"$1"]}])

  @doc """
  The message that ends a stream the way a deploy does: a jittered `retry:`,
  `event: shutdown`, and the end of the response.
  """
  @spec shutdown_message() :: term()
  def shutdown_message, do: {__MODULE__, :shutdown}

  @doc "The response headers of every stream, a refusal and a `HEAD`."
  @spec put_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def put_headers(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    # `no-transform` also keeps Bandit from compressing the stream, which
    # would buffer events behind a deflate window.
    |> put_resp_header("cache-control", "no-store, no-transform")
    # nginx buffers a proxied response unless told not to.
    |> put_resp_header("x-accel-buffering", "no")
  end

  @doc """
  Run the stream for `scope` until the client goes, the node drains, or the
  stream is refused. Returns the conn, whose chunked response is complete.
  """
  @spec run(Plug.Conn.t(), scope()) :: Plug.Conn.t()
  def run(conn, scope) do
    conn = put_headers(conn)

    if Drainer.draining?() do
      busy(conn, "shutting_down")
    else
      case admit(scope.client) do
        :ok ->
          try do
            stream(conn, scope)
          after
            Registry.unregister(@streams, scope.client)
          end

        {:refused, reason} ->
          busy(conn, reason)
      end
    end
  end

  # Register first, then count: two connects racing for the last slot both
  # count each other and are both refused, rather than both admitted.
  defp admit(client) do
    {:ok, _owner} = Registry.register(@streams, client, nil)

    cond do
      # Again, now that this stream is registered: a drain that began between
      # the first check and the registration took its snapshot of the streams
      # without this one, and would never tell it to finish.
      Drainer.draining?() ->
        refuse(client, "shutting_down")

      Registry.count(@streams) > config(:max_per_node) ->
        refuse(client, "node_full")

      # Counted, not listed: a list of the client's entries would stay on
      # this long-lived process's heap.
      Registry.count_match(@streams, client, :_) > config(:max_per_client) ->
        refuse(client, "too_many_streams")

      true ->
        :ok
    end
  end

  defp refuse(client, reason) do
    Registry.unregister(@streams, client)
    {:refused, reason}
  end

  @doc """
  Refuse the stream the way an `EventSource` survives: a `200` it reads to the
  end, `event: busy` with `reason`, then a reconnect after the `retry:` it was
  given (`retry_ms`, or a jittered `busy_retry_ms`).
  """
  @spec busy(Plug.Conn.t(), String.t(), pos_integer() | nil) :: Plug.Conn.t()
  def busy(conn, reason, retry_ms \\ nil) do
    :telemetry.execute(@telemetry ++ [:refused], %{count: 1}, %{reason: reason})

    conn
    |> put_headers()
    |> send_chunked(200)
    |> write([
      retry(retry_ms || jitter(config(:busy_retry_ms))),
      frame("busy", nil, %{reason: reason})
    ])
    |> elem(1)
  end

  # ── The stream ───────────────────────────────────────────────────────────

  defp stream(conn, scope) do
    # Subscribe before anything is replayed: an event committed during the
    # replay waits in the mailbox and follows `ready`.
    :ok = Feed.subscribe(scope.org_id)
    started = System.monotonic_time()

    try do
      conn = send_chunked(conn, 200)

      with {:ok, conn} <- write(conn, retry(config(:retry_ms))),
           {:ok, conn, resumed?, ready_id} <- resume(conn, scope),
           {:ok, conn} <- write(conn, frame("ready", ready_id, %{resumed: resumed?})) do
        :telemetry.execute(@telemetry ++ [:connect], %{count: 1}, %{
          org_id: scope.org_id,
          resumed: resumed?,
          stream: self()
        })

        # Whatever the connect and the replay allocated is garbage now, and
        # an idle stream may not collect again for hours: start the loop
        # from a small heap.
        :erlang.garbage_collect()
        {conn, reason, {timer, _tag}} = loop(conn, scope, schedule_heartbeat())
        Process.cancel_timer(timer)
        disconnected(scope, started, reason)
        conn
      else
        {:halt, conn, reason} ->
          disconnected(scope, started, reason)
          conn

        # The client went before the stream was live.
        {:error, conn} ->
          disconnected(scope, started, :closed)
          conn
      end
    after
      Feed.unsubscribe(scope.org_id)
      flush()
    end
  end

  defp disconnected(scope, started, reason) do
    :telemetry.execute(
      @telemetry ++ [:disconnect],
      %{count: 1, duration: System.monotonic_time() - started},
      %{org_id: scope.org_id, reason: reason}
    )
  end

  # ── Resume ───────────────────────────────────────────────────────────────

  # `{:ok, conn, resumed?, ready_id}`, or `{:halt, conn, reason}` when the
  # response must end here.
  defp resume(conn, %{resume: nil} = scope), do: {:ok, conn, false, fresh_id(scope)}

  defp resume(conn, %{resume: {:reset, reason}} = scope), do: reset(conn, scope, reason)

  defp resume(conn, %{resume: {:since, since}} = scope) do
    window = DateTime.add(DateTime.utc_now(), -config(:resume_window_seconds), :second)

    if DateTime.compare(since, window) == :lt do
      # Too old to be worth reading at all: no query.
      reset(conn, scope, "too_far_behind")
    else
      replaying(conn, scope, since)
    end
  end

  defp reset(conn, scope, reason) do
    id = fresh_id(scope)

    case write(conn, frame("reset", id, %{reason: reason})) do
      {:ok, conn} -> {:ok, conn, false, id}
      {:error, conn} -> {:halt, conn, :closed}
    end
  end

  # The replay gate: register first, then count, like `admit/1`.
  defp replaying(conn, scope, since) do
    {:ok, _owner} = Registry.register(@replays, :replay, nil)

    try do
      if Registry.count(@replays) > config(:max_replays) do
        :telemetry.execute(@telemetry ++ [:refused], %{count: 1}, %{reason: "replay_busy"})

        {_, conn} =
          write(conn, [
            retry(jitter(config(:busy_retry_ms))),
            frame("busy", nil, %{reason: "replay_busy"})
          ])

        {:halt, conn, :replay_busy}
      else
        now = DateTime.utc_now()
        replay(conn, scope, since, now, {:delta, since, nil, nil}, {[], 0})
      end
    after
      Registry.unregister(@replays, :replay)
    end
  end

  # Pages are read into a buffer and written only once the whole replay is
  # known to fit under `replay_limit`: a client that is about to be told
  # `too_far_behind` must not first be handed part of what it missed. The
  # buffer is bounded by the same limit.
  defp replay(conn, scope, since, now, position, {frames, count}) do
    case Sync.page(scope.org_id, scope.type, position,
           limit: config(:replay_page),
           bodies: false,
           commit_lag: 0,
           now: now
         ) do
      {:ok, items, next, more?} ->
        count = count + length(items)
        frames = [frames | Enum.map(items, &replayed_frame(&1, since))]

        cond do
          count > config(:replay_limit) ->
            :ok = replayed(scope, 0)
            reset(conn, scope, "too_far_behind")

          more? ->
            replay(conn, scope, since, now, next, {frames, count})

          true ->
            flush_replay(conn, scope, now, frames, count)
        end

      # A database outage, or the type was archived since the request was
      # resolved: end with a `retry:`. The client reconnects with the id it
      # sent, which is still right (or, for a type that is gone, gets a 404).
      _unavailable ->
        {_, conn} = write(conn, retry(jitter(config(:busy_retry_ms))))
        {:halt, conn, :unavailable}
    end
  end

  defp flush_replay(conn, scope, now, frames, count) do
    case write(conn, frames) do
      {:ok, conn} ->
        :ok = replayed(scope, count)
        {:ok, conn, true, id(scope, now)}

      {:error, conn} ->
        {:halt, conn, :closed}
    end
  end

  defp replayed(scope, events),
    do: :telemetry.execute(@telemetry ++ [:replay], %{events: events}, %{org_id: scope.org_id})

  defp replayed_frame(%{op: "upsert"} = item, since) do
    kind =
      if item.published_at && DateTime.compare(item.published_at, since) == :gt,
        do: "published",
        else: "updated"

    frame(kind, nil, %{
      type: item.type,
      id: item.id,
      slug: item.slug,
      locale: item.locale,
      published_at: item.published_at,
      affected: []
    })
  end

  defp replayed_frame(%{op: "delete"} = item, _since),
    do: frame("withdrawn", nil, %{type: item.type, id: item.id})

  # ── Live ─────────────────────────────────────────────────────────────────

  # `{conn, reason, heartbeat}` once the stream ends; the caller cancels the
  # heartbeat's timer.
  defp loop(conn, scope, {_timer, tag} = heartbeat) do
    receive do
      {:kiln_feed, event} ->
        case live_frame(event, scope.type) do
          nil -> loop(conn, scope, heartbeat)
          frame -> forward(conn, scope, heartbeat, frame)
        end

      {__MODULE__, :heartbeat, ^tag} ->
        case write(conn, ": ping\n\n") do
          {:ok, conn} -> loop(conn, scope, schedule_heartbeat())
          {:error, conn} -> {conn, :closed, heartbeat}
        end

      {__MODULE__, :shutdown} ->
        {_, conn} =
          write(conn, [retry(jitter(config(:shutdown_retry_ms))), frame("shutdown", nil, %{})])

        {conn, :shutdown, heartbeat}

      # The connection's handler is going away (it links the request process
      # and traps exits): end the stream rather than keep a slot for it.
      # Deliberately no catch-all clause: Bandit's own messages to an HTTP/2
      # stream process (body data, resets) must stay in the mailbox for it.
      {:EXIT, _pid, _reason} ->
        {conn, :closed, heartbeat}
    end
  end

  defp forward(conn, scope, heartbeat, frame) do
    if mailbox() > config(:max_queue) do
      # Behind by more than the bound: end it, and let the client resume from
      # its last id rather than hold an ever-growing mailbox for it.
      {_, conn} = write(conn, retry(jitter(config(:busy_retry_ms))))
      {conn, :slow, heartbeat}
    else
      case write(conn, frame) do
        {:ok, conn} -> loop(conn, scope, heartbeat)
        {:error, conn} -> {conn, :closed, heartbeat}
      end
    end
  end

  # The frame the publisher encoded, when the event is shown to an anonymous
  # stream and is of the stream's type. An event without one — hidden, or
  # from a node running a release that did not encode it — is not sent.
  defp live_frame(event, type) do
    case Map.get(event, :sse) do
      %{event: name, data: data, ids: ids} when is_nil(type) ->
        raw_frame(name, ids.all, data)

      %{event: name, data: data, ids: ids} ->
        if Map.get(event, :type) == type, do: raw_frame(name, ids.type, data)

      _hidden ->
        nil
    end
  end

  defp mailbox do
    {:message_queue_len, length} = Process.info(self(), :message_queue_len)
    length
  end

  defp schedule_heartbeat do
    tag = make_ref()
    {Process.send_after(self(), {__MODULE__, :heartbeat, tag}, config(:heartbeat_ms)), tag}
  end

  # The request process can outlive the stream (HTTP/1.1 keep-alive serves the
  # next request in the same process): leave nothing of the stream behind in
  # its mailbox.
  defp flush do
    receive do
      {:kiln_feed, _event} -> flush()
      {__MODULE__, :heartbeat, _ref} -> flush()
      {__MODULE__, :shutdown} -> flush()
    after
      0 -> :ok
    end
  end

  # ── Wire format ──────────────────────────────────────────────────────────

  defp fresh_id(scope), do: id(scope, DateTime.utc_now())

  # A delta cursor from `at` less the commit lag, the conservative end: a
  # transaction that wrote before then and commits later is still replayed.
  defp id(scope, at) do
    since = DateTime.add(at, -Sync.commit_lag_seconds(), :second)
    SyncCursor.sign(scope.org_id, scope.type, :json, {:delta, since, nil, nil})
  end

  defp frame(name, id, data), do: raw_frame(name, id, Jason.encode!(data))

  defp raw_frame(name, nil, data), do: ["event: ", name, "\ndata: ", data, "\n\n"]
  defp raw_frame(name, id, data), do: ["event: ", name, "\nid: ", id, "\ndata: ", data, "\n\n"]

  defp retry(ms), do: ["retry: ", Integer.to_string(ms), "\n\n"]

  # Between a tenth of `max` and `max`, so a node's clients do not all come
  # back in the same instant.
  defp jitter(max) do
    floor = max(div(max, 10), 1)
    floor + :rand.uniform(max(max - floor, 1)) - 1
  end

  # `{:ok, conn}` or `{:error, conn}` (the client has gone). Through a seam a
  # test can replace (`conn.private[:kiln_feed_sink]`), so a dropped client is
  # testable without a socket.
  defp write(conn, data) do
    sink = conn.private[:kiln_feed_sink] || (&chunk/2)

    case sink.(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, conn}
    end
  end
end
