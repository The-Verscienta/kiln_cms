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
  no audience). It fails closed: only `true` is public. The transports (2.2)
  filter on it. `affected` is the webhook payload's list and is not filtered
  by audience.

  ## Subscribing

      KilnCMS.Delivery.Feed.subscribe(org_id)
      # receive {:kiln_feed, %KilnCMS.Delivery.Feed.Event{}}

  The topic is per site (`topic/1`). Phoenix.PubSub reaches every node of a
  cluster. Transports (SSE, a channel) and resume are 2.2.

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
  metadata `kind`, `type`, `id` and `org_id` — the "feed events per
  transition" number the path forward asks for. It is emitted in the
  publisher, once the event is handed off, not when subscribers receive it.

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

  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Delivery.Feed.Relay

  @pubsub KilnCMS.PubSub
  @telemetry_event [:kiln_cms, :delivery, :feed, :event]
  @affected_fields [:type, :id, :slug, :locale]

  defmodule Event do
    @moduledoc """
    One feed event: what changed, as identifiers only. `kind` is
    `:published`, `:updated` or `:withdrawn`; `type` the public type name
    (`"page"`, or a dynamic type's name); `public` whether an anonymous
    reader may see it (see "Gated documents" in `KilnCMS.Delivery.Feed`);
    `at` when the event was published.
    """
    @derive Jason.Encoder
    @enforce_keys [:kind, :type, :id]
    defstruct [:kind, :type, :id, :slug, :locale, :published_at, :public, :at, affected: []]

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
            ]
          }
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

      :ok = Relay.dispatch(org_id, "feed:" <> org_id, {:kiln_feed, feed_event})

      :telemetry.execute(@telemetry_event, %{count: 1}, %{
        kind: kind,
        type: type,
        id: id,
        org_id: org_id
      })
    end

    :ok
  rescue
    error ->
      Logger.error("Feed event for #{event} not published: " <> Exception.message(error))
      :ok
  catch
    # Runs in the publisher's `after_transaction`: an exit must not escape it
    # either.
    :exit, reason ->
      Logger.error("Feed event for #{event} not published: " <> inspect(reason))
      :ok
  end

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
