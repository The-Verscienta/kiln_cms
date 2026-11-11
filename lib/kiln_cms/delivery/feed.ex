defmodule KilnCMS.Delivery.Feed do
  @moduledoc """
  The public change feed, server side (#2050, 2.1): one event per published
  content change, per site, over native `Phoenix.PubSub` (D1 — no broker).

  ## Where the events come from

  `KilnCMS.Webhooks.dispatch/4`, the funnel every content transition's
  `<type>.<verb>` webhook already flows through. The feed is one more consumer
  of that funnel, beside automation, federation and the CDN purge, so it cannot
  drift from what webhook receivers are told: a transition that fires no
  webhook emits no feed event, and one that does emits at most one.

  | Webhook event | Feed event |
  |---|---|
  | `<type>.published` | `published` |
  | `<type>.restored` of a document restored onto the delivery path | `published` |
  | `<type>.updated` of a published document | `updated` |
  | `<type>.unpublished` | `withdrawn` |
  | `<type>.deleted` of a document that was published | `withdrawn` |

  Everything else emits nothing: drafts' events (`created`, `in_review`, …),
  `archived` (archiving a live document fires `unpublished` too, and that is
  the one carried, as in `KilnCMS.Propagation`), a draft's tombstone, taxonomy
  events and the domain events that share a verb (`release.published`).

  ## Anonymous-safe by construction

  An event carries identifiers and nothing else — `KilnCMS.Delivery.Feed.Event`
  is built field by field, never from the webhook payload as a whole — so a
  transport can hand it to an anonymous subscriber without a policy read. A
  client that wants the content fetches it through the existing cached
  delivery routes, which apply the policies. `affected` is the
  identity-only list `KilnCMS.Firing.References.affected/1` computes for the
  webhook payload (published documents only); a tombstone carries none, so a
  `withdrawn` from a delete has `affected: []`.

  ## Gated documents

  A members-only or password-protected document is published too, and its
  transitions are on the feed like any other's: a member's open page needs
  them. `public` says which events an anonymous subscriber may be shown —
  `true` for a document `audience: :public` and not locked, `false` for a
  gated one, `nil` when the payload cannot say (a delete's tombstone carries
  no audience). It fails closed: only `true` is public. `affected` is the
  webhook payload's list and is not filtered by audience.

  ## The anonymous view

  `anonymous` is what an anonymous subscriber is shown, decided once per event
  in the publisher (never per subscriber), on the rule the sync API
  (`KilnCMS.Firing.Sync`) applies to a delta:

    * `:show` — a `published` / `updated` event of a public document whose
      content type is live. The event discloses the id, so the publisher
      records it in `KilnCMS.Firing.SyncExposure` (as the `:feed` system
      actor), as `/api/sync` does for an upsert it serves: a later withdrawal
      may then name it, live or on a resume.
    * `:withdraw` — a `withdrawn` event of a public document of a live type,
      whether or not an exposure exists; or any other event of a document
      that is not (or no longer) public, or whose type is no longer live,
      **if** its id was disclosed (an exposure exists): a tombstone,
      `{type, id}` only.

      The first half deliberately differs from `/api/sync`'s tombstone rule,
      which names only recorded ids. The unpublish of a public, live-type
      document names an id that was public until that very moment (anyone
      could have fetched it a second earlier), so naming it reveals nothing;
      and an anonymous mirror that learned the document some other way —
      before exposures were recorded, say — must still hear that it went.
    * `:hide` — everything else: a gated or locked document never disclosed,
      a draft's delete. An anonymous subscriber is told nothing.

  It fails closed: an exposure that cannot be read or written hides the event.

  A resume through `GET /api/feed` replays from the sync API's version
  history, so it inherits the sync API's commit-lag assumption (see
  "Consistency" in `KilnCMS.Firing.Sync`): a transaction held open longer
  than the lag — a long release go-live, say — can write versions a
  reconnecting client's window has already passed, and those changes are
  missed across the reconnect (live events are not affected).
  `sse` carries what `GET /api/feed` (`KilnCMSWeb.FeedStream`) writes for a
  shown or withdrawn event, encoded once here rather than once per stream:
  the SSE event name, the `data:` JSON (identifiers only, `affected: []`, since
  `affected` is not audience-filtered) and the two signed ids it can carry
  (`KilnCMS.Firing.SyncCursor` delta cursors for every type and for the
  event's type). `nil` for a hidden event, or when the ids cannot be signed.

  ## Subscribing

      KilnCMS.Delivery.Feed.subscribe(org_id)
      # receive {:kiln_feed, %KilnCMS.Delivery.Feed.Event{}}

  The topic is per site (`topic/1`). Phoenix.PubSub reaches every node of a
  cluster. `GET /api/feed` (`KilnCMSWeb.FeedStream`, #2275) is the SSE
  transport, with resume through the sync API's cursor.

  ## After the commit

  `publish/4` is called from `KilnCMS.Webhooks.dispatch/4`, which runs in an
  action's `after_transaction` hook — inside a release's go-live transaction
  when the action ran in one. The event's work (the anonymous decision, the
  exposure write, the hand-off and the telemetry) goes through
  `KilnCMS.AfterCommit.run/1`, so it runs once the outermost transaction has
  committed and is dropped if it rolls back.

  ## Delivery is asynchronous

  `publish/4` does not deliver to this node's subscribers itself: it hands the
  event to the site's relay (`KilnCMS.Delivery.Feed.Relay`, #2083), which
  broadcasts it locally, and sends one message per remote node, whose PubSub
  server fans it out there. The publisher's cost is the same with no
  subscribers or ten thousand. A site's events reach its subscribers in the
  order they reached its relay, so one publisher's events stay in order. A
  burst (a release going live, a bulk publish, `KilnCMS.Portability.Import`)
  queues in the site's relay instead of slowing the publisher.

  When `publish/4` returns, the event may not have arrived yet. `sync/1`
  waits for it (tests, benchmarks).

  ## Telemetry

  Each event handed to the broadcast emits
  `[:kiln_cms, :delivery, :feed, :event]` with measurement `count: 1` and
  metadata `kind`, `type`, `id`, `org_id` and `anonymous` — the "feed events
  per transition" number the path forward asks for. It is emitted in the
  publisher, once the event is handed off (after the commit), not when
  subscribers receive it.

  ## Failure handling

  Like the other consumers of the funnel, `publish/4` never raises or exits
  into the caller: the transition has already committed, so a broken feed is
  logged and the publish stands.

  Delivery is at most once, as PubSub's is. Events already in a relay's
  mailbox are lost if that relay crashes or the node shuts down (the local
  endpoint stops first, so no local subscriber would have received them
  anyway), and an event cast to a relay that crashed just then, before its
  partition restarted it, is lost too. When no relay is running at all, the
  local broadcast runs inline in the publisher, as before #2083.
  """
  require Logger

  alias KilnCMS.AfterCommit
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Delivery.Feed.Relay
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Sync
  alias KilnCMS.Firing.SyncCursor
  alias KilnCMS.SystemActor

  @pubsub KilnCMS.PubSub
  @telemetry_event [:kiln_cms, :delivery, :feed, :event]
  @affected_fields [:type, :id, :slug, :locale]

  defmodule Event do
    @moduledoc """
    One feed event: what changed, as identifiers only. `kind` is
    `:published`, `:updated` or `:withdrawn`; `type` the public type name
    (`"page"`, or a dynamic type's name); `public` whether an anonymous
    reader may see it (see "Gated documents" in `KilnCMS.Delivery.Feed`);
    `at` when the event was published; `anonymous` and `sse` what an
    anonymous subscriber is shown (see "The anonymous view"). `sse` is left
    out of the event's JSON encoding.
    """
    @derive {Jason.Encoder, except: [:sse]}
    @enforce_keys [:kind, :type, :id]
    defstruct [
      :kind,
      :type,
      :id,
      :slug,
      :locale,
      :published_at,
      :public,
      :at,
      affected: [],
      anonymous: :hide,
      sse: nil
    ]

    @type t :: %__MODULE__{
            kind: :published | :updated | :withdrawn,
            type: String.t(),
            id: Ash.UUID.t(),
            slug: String.t() | nil,
            locale: String.t() | nil,
            published_at: DateTime.t() | nil,
            public: boolean() | nil,
            at: DateTime.t(),
            affected: [
              %{
                type: String.t(),
                id: Ash.UUID.t(),
                slug: String.t() | nil,
                locale: String.t() | nil
              }
            ],
            anonymous: :show | :withdraw | :hide,
            sse: sse() | nil
          }

    @typedoc """
    The SSE frame parts for a shown or withdrawn event: the `event:` name, the
    `data:` JSON, and the `id:` to send on a stream of every type (`:all`) or
    of the event's own type (`:type`).
    """
    @type sse :: %{event: String.t(), data: String.t(), ids: %{all: String.t(), type: String.t()}}
  end

  @doc "The telemetry event each event handed to the broadcast emits."
  def telemetry_event, do: @telemetry_event

  @doc "The PubSub topic of `org`'s feed."
  @spec topic(Ash.ToTenant.t()) :: String.t()
  def topic(org), do: "feed:" <> org_id!(org)

  @doc """
  Subscribe the calling process to `org`'s feed. Each event arrives as
  `{:kiln_feed, %KilnCMS.Delivery.Feed.Event{}}`.
  """
  @spec subscribe(Ash.ToTenant.t()) :: :ok | {:error, term()}
  def subscribe(org), do: Phoenix.PubSub.subscribe(@pubsub, topic(org))

  @doc "Undo `subscribe/1`."
  @spec unsubscribe(Ash.ToTenant.t()) :: :ok
  def unsubscribe(org), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(org))

  @doc """
  Wait until every event the calling process published to `org`'s feed
  before this call has reached this node's subscribers' mailboxes (see
  "Delivery is asynchronous"). It also covers whatever reached the site's
  relay earlier, but not events other processes are still publishing.

  This node only: remote nodes deliver on their own. Blocks while the site's
  relay is busy or suspended; `:ok` at once when no relay is running.
  """
  @spec sync(Ash.ToTenant.t()) :: :ok
  def sync(org), do: Relay.sync(org_id!(org))

  @doc """
  The feed kind webhook `event` maps to (see the moduledoc's table), or `nil`.
  `payload` is the webhook payload and `withdraws?` whether the document was
  published before the action (`KilnCMS.Webhooks.dispatch/4`'s `:withdraws`).
  """
  @spec kind(String.t(), map(), boolean()) :: :published | :updated | :withdrawn | nil
  def kind(event, payload, withdraws?) when is_binary(event) do
    with false <- event in WebhookEndpoint.domain_events(),
         {_type, verb} <- WebhookEndpoint.content_event_parts(event) do
      verb_kind(verb, payload, withdraws?)
    else
      _not_a_document_event -> nil
    end
  end

  defp verb_kind("published", _payload, _withdraws?), do: :published
  defp verb_kind("unpublished", _payload, _withdraws?), do: :withdrawn
  defp verb_kind("deleted", _payload, true), do: :withdrawn

  defp verb_kind("restored", payload, _withdraws?), do: if(published?(payload), do: :published)
  defp verb_kind("updated", payload, _withdraws?), do: if(published?(payload), do: :updated)

  defp verb_kind(_verb, _payload, _withdraws?), do: nil

  @doc """
  Broadcast the feed event for webhook `event` to `org`'s subscribers, when it
  maps to one. Called by `KilnCMS.Webhooks.dispatch/4`; never raises or exits.

  Returns once the event is handed off, before this node's subscribers have
  it (see "Delivery is asynchronous" and `sync/1`).
  """
  @spec publish(String.t(), map(), Ash.ToTenant.t() | nil, boolean()) :: :ok
  def publish(event, payload, org, withdraws? \\ true) do
    with org_id when is_binary(org_id) <- org_id(org),
         kind when not is_nil(kind) <- kind(event, payload, withdraws?),
         {type, _verb} <- WebhookEndpoint.event_parts(event),
         id when is_binary(id) <- KilnCMS.CMS.WebhookDelivery.document_id(payload) do
      feed_event = %Event{
        kind: kind,
        type: type,
        id: id,
        slug: field(payload, :slug),
        locale: field(payload, :locale),
        published_at: field(payload, :published_at),
        public: public(payload),
        at: DateTime.utc_now(),
        affected: affected(payload)
      }

      AfterCommit.run(fn -> deliver(event, org_id, feed_event) end)
    end

    :ok
  rescue
    error -> not_published(event, Exception.message(error))
  catch
    # Runs in the publisher's `after_transaction`: an exit must not escape it
    # either.
    :exit, reason -> not_published(event, inspect(reason))
  end

  # After the commit (see "After the commit"): decide, hand off, report.
  defp deliver(webhook_event, org_id, feed_event) do
    feed_event = with_anonymous_view(feed_event, org_id)

    :ok = Relay.dispatch(org_id, "feed:" <> org_id, {:kiln_feed, feed_event})

    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      kind: feed_event.kind,
      type: feed_event.type,
      id: feed_event.id,
      org_id: org_id,
      anonymous: feed_event.anonymous
    })

    :ok
  rescue
    error -> not_published(webhook_event, Exception.message(error))
  catch
    :exit, reason -> not_published(webhook_event, inspect(reason))
  end

  defp not_published(event, reason) do
    Logger.error("Feed event for #{event} not published: " <> reason)
    :ok
  end

  # ── The anonymous view ───────────────────────────────────────────────────

  defp with_anonymous_view(%Event{} = event, org_id) do
    anonymous = anonymous(event, org_id)
    %{event | anonymous: anonymous, sse: sse(event, anonymous, org_id)}
  end

  defp anonymous(%Event{kind: kind, public: true} = event, org_id)
       when kind in [:published, :updated] do
    case ContentTypes.get(event.type, org_id) do
      nil -> withdraw_if_disclosed(event, org_id)
      descriptor -> if disclose(event, descriptor, org_id), do: :show, else: :hide
    end
  end

  # An ordinary unpublish of a public document of a live type: the id was
  # public until this moment, so it is named without an exposure (see "The
  # anonymous view"). A type no longer served goes through the exposure.
  defp anonymous(%Event{kind: :withdrawn, public: true} = event, org_id) do
    if ContentTypes.get(event.type, org_id),
      do: :withdraw,
      else: withdraw_if_disclosed(event, org_id)
  end

  defp anonymous(event, org_id), do: withdraw_if_disclosed(event, org_id)

  defp withdraw_if_disclosed(event, org_id) do
    case exposure(event.id, org_id) do
      {:ok, nil} -> :hide
      {:ok, _exposure} -> :withdraw
      :error -> :hide
    end
  end

  # Record the disclosure before the event is shown, the way
  # `KilnCMS.Firing.Sync` records an upsert it serves: skipped when the id is
  # already recorded under this type name. False (hide the event) when it
  # cannot be read or written — shown unrecorded, a later withdrawal of it
  # could not be named on a resume.
  defp disclose(event, descriptor, org_id) do
    case exposure(event.id, org_id) do
      {:ok, %{type_name: type_name}} when type_name == event.type ->
        true

      {:ok, _none_or_renamed} ->
        record_exposure(event, descriptor, org_id)

      :error ->
        false
    end
  end

  defp record_exposure(event, descriptor, org_id) do
    Firing.record_sync_exposure!(
      %{
        document_type: ContentTypes.storage_type(descriptor, org_id),
        document_id: event.id,
        type_name: event.type,
        type_definition_id: definition_id(descriptor)
      },
      actor: SystemActor.new(:feed),
      tenant: org_id
    )

    true
  rescue
    error ->
      Logger.error("Feed exposure for #{event.id} not recorded: " <> Exception.message(error))
      false
  end

  defp definition_id(%{source: :dynamic, definition: %{id: id}}), do: id
  defp definition_id(_compiled), do: nil

  defp exposure(id, org_id) do
    {:ok,
     id
     |> List.wrap()
     |> Firing.sync_exposures_for!(actor: SystemActor.new(:feed), tenant: org_id)
     |> List.first()}
  rescue
    error ->
      Logger.error("Feed exposure for #{id} not read: " <> Exception.message(error))
      :error
  end

  # The SSE frame, encoded once for every stream (see "The anonymous view").
  # Field by field: the struct's own encoding would carry `public` and
  # whatever the event grows.
  defp sse(_event, :hide, _org_id), do: nil

  defp sse(event, anonymous, org_id) do
    {name, data} = frame(event, anonymous)
    position = {:delta, DateTime.add(event.at, -Sync.commit_lag_seconds(), :second), nil, nil}

    %{
      event: name,
      data: Jason.encode!(data),
      ids: %{
        all: SyncCursor.sign(org_id, nil, :json, position),
        type: SyncCursor.sign(org_id, event.type, :json, position)
      }
    }
  rescue
    # The endpoint that signs the ids is not running (a script or task
    # publishing without it): no stream can be listening on this node, and
    # the in-BEAM subscribers still get the event.
    error ->
      Logger.warning("Feed event #{event.id} has no SSE frame: " <> Exception.message(error))
      nil
  end

  defp frame(event, :show) do
    {Atom.to_string(event.kind),
     %{
       type: event.type,
       id: event.id,
       slug: event.slug,
       locale: event.locale,
       published_at: event.published_at,
       affected: []
     }}
  end

  defp frame(event, :withdraw), do: {"withdrawn", %{type: event.type, id: event.id}}

  # The resulting state, on the full payload `updated` and a live `restored`
  # carry; a tombstone carries it too.
  defp published?(payload), do: field(payload, :state) in [:published, "published"]

  # Fail closed: `true` only when the payload shows a public, unlocked document.
  defp public(payload) do
    case {field(payload, :audience), field(payload, :locked)} do
      {nil, _locked} -> nil
      {audience, _locked} when audience not in [:public, "public"] -> false
      {_public, false} -> true
      {_public, true} -> false
      {_public, _unknown} -> nil
    end
  end

  # Identity only, whatever else an entry might grow.
  defp affected(payload) do
    for entry <- List.wrap(field(payload, :affected)), is_map(entry) do
      Map.new(@affected_fields, &{&1, field(entry, &1)})
    end
  end

  # Payloads built in-process have atom keys; a replayed one (string keys)
  # reads the same.
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp org_id(org) when is_binary(org), do: org
  defp org_id(%{id: id}) when is_binary(id), do: id
  defp org_id(_org), do: nil

  defp org_id!(org) do
    org_id(org) || raise ArgumentError, "a feed is per site; got #{inspect(org)}"
  end
end
