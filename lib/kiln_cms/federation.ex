defmodule KilnCMS.Federation do
  @moduledoc """
  ActivityPub federation — a Kiln site as a fediverse actor (#491, phase 1).

  A site with federation on is followable from Mastodon (and anything else
  speaking ActivityPub): it publishes a WebFinger record, an actor document,
  and an outbox of its published content, and it delivers `Create` / `Update` /
  `Delete` activities to its followers as content is published, edited and
  unpublished.

  ## Two switches, both off

  Federation is off unless an operator says otherwise **twice**:

    * deployment-wide, `KILN_FEDERATION_ENABLED` (see `enabled?/0`). Off means
      every federation route 404s, exactly as `KilnCMS.Provenance` does — an
      instance that cannot federate should be indistinguishable from one built
      without the feature, not one advertising a closed door;
    * per site, a `KilnCMS.Federation.SiteFederation` row. Absent is off.

  The deployment switch exists because federation is an egress decision, not an
  editorial one: turning it on makes the server sign and POST to servers chosen
  by strangers who followed you. An operator who cannot allow that must be able
  to say so once, without trusting every tenant admin to agree.

  ## What federates

  Published, `:public`-audience, default-locale content of a type that already
  syndicates a feed (`KilnCMS.Feeds.syndicated_types/1`). Each of those is a
  deliberate narrowing:

    * **published + public** — an audience-gated record is published and
      paywalled, and an outbox is the most public surface there is;
    * **default locale only** — a record in three languages is three rows, and
      federating all three re-notifies every follower three times per publish
      (the same guard the newsletter reaction and the feeds make);
    * **types that syndicate** — an operator who chose not to put a type in the
      site's feed did not choose to broadcast it to the fediverse either.

  ## Where it hangs off

  `handle_event/3` is called from `KilnCMS.Webhooks.dispatch/3`, the single
  funnel every editorial event already flows through, beside
  `KilnCMS.Automation.handle_event/3`. It runs inside the publish transaction,
  so it is enqueue-only and never raises — a federation problem must not fail a
  publish.

  Deliberately **not** built on the `"firing"` PubSub broadcast: that message
  carries no `org_id` and fires on every re-fire, including cache warms and the
  `:reindex` automation, so it would re-announce content nobody edited.

  ## Phase 1 boundaries

  Inbound is limited to `Follow` and `Undo{Follow}` — enough that following a
  Kiln site from Mastodon works, which is the demo the feature exists for.
  Replies, likes, boosts and announces are accepted-and-ignored rather than
  rejected (a 202 with no action), so a remote server's retry queue does not
  fill up over something we simply do not implement yet. Moderated inbound
  replies are phase 3 and intersect the visitor-comments non-goal; see #491.
  """
  use Ash.Domain, otp_app: :kiln_cms

  resources do
    resource KilnCMS.Federation.SiteFederation do
      define :list_site_federation, action: :read
      define :enable_site_federation, action: :enable, args: [:origin, :username]
      define :disable_site_federation, action: :disable
    end

    resource KilnCMS.Federation.Follower do
      define :list_followers, action: :read
      define :follow, action: :follow, args: [:actor_uri, :inbox_uri]
      define :destroy_follower, action: :destroy
      define :record_follower_failure, action: :record_failure
      define :record_follower_success, action: :record_success
    end

    resource KilnCMS.Federation.Delivery do
      define :get_federation_delivery, action: :read, get_by: [:id]
      define :list_federation_deliveries, action: :read
      define :create_federation_delivery, action: :create
      define :settle_federation_delivery, action: :settle
    end
  end

  @doc """
  Whether this **deployment** allows federation at all.

  Read at runtime, not compile time, so a release flips it with a restart and
  no rebuild. Defaults to `false`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc """
  Consecutive failed deliveries before a follower is dropped.

  Dead instances are the normal case in the fediverse, not the exception — a
  server disappears and never says so. Without a ceiling its rows accumulate
  forever and every publish pays for them.
  """
  @spec drop_follower_after() :: pos_integer()
  def drop_follower_after, do: Keyword.get(config(), :drop_follower_after, 12)

  @doc """
  React to an editorial event by enqueuing federation deliveries.

  Called from `KilnCMS.Webhooks.dispatch/3` inside the publish transaction:
  enqueue-only, and it swallows its own errors for the same reason
  `KilnCMS.Automation.handle_event/3` does — a federation fault is not a reason
  to fail someone's publish.
  """
  @spec handle_event(String.t(), map(), Ash.ToTenant.t() | nil) :: :ok
  def handle_event(event, payload, org \\ KilnCMS.Accounts.default_org_id()) do
    if enabled?(), do: KilnCMS.Federation.Announcer.announce(event, payload, org)
    :ok
  rescue
    error ->
      require Logger

      Logger.warning("Federation.handle_event/3 failed for #{event}: #{Exception.message(error)}")

      :ok
  end

  @doc """
  The most followers one site will accept.

  A ceiling rather than none, because a follower row is a **delivery target on
  every publish**: `one_per_actor` dedups an exact actor URI, so a single
  attacker-controlled domain serving many actor URLs becomes many rows, and the
  site's own editorial calendar becomes the trigger for a signed flood. Past
  this, new follows are refused rather than the site becoming an amplifier.
  """
  @spec max_followers() :: pos_integer()
  def max_followers, do: Keyword.get(config(), :max_followers, 50_000)

  @doc """
  Extra `Req` options for outbound federation requests.

  Empty in production. Tests point it at a `Req.Test` stub, which is how the
  signing, delivery and follower bookkeeping get exercised end to end without a
  live fediverse server — the same seam webhooks, oEmbed and link checking use.
  """
  @spec req_options() :: keyword()
  def req_options, do: Keyword.get(config(), :req_options, [])

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
