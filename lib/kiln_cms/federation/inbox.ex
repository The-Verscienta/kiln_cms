defmodule KilnCMS.Federation.Inbox do
  @moduledoc """
  Handles the inbound activities phase 1 supports: `Follow` and
  `Undo{Follow}` (#491).

  These are in phase 1 because without them the feature is inert — the issue's
  own success criterion is "follow a Kiln site from Mastodon", and a site with
  no inbox can never gain the followers the outbox and delivery machinery
  exist to serve.

  ## Everything is authenticated, nothing is trusted

  A `Follow` is a request to subscribe *somebody else's server* to this site's
  firehose. Accepting an unsigned one would let anyone sign up any instance for
  traffic it never asked for, which is a spam amplifier with this site's name
  on it. So every activity must carry a valid HTTP Signature, and:

    * the key is fetched from the **actor named in the activity**, not from
      wherever the `keyId` points, and the two must agree
      (`RemoteActor.owns_key?/2`). Otherwise a valid signature over one's own
      key would authorize a follow on behalf of a different account;
    * `object` on a `Follow` must be *this* site's actor. A `Follow` addressed
      elsewhere that arrives here is either a misdelivery or someone probing.

  ## Unsupported activities are accepted, not rejected

  `Like`, `Announce`, `Create` (a reply) and the rest return `:ok` and do
  nothing. A 4xx would make the sending server retry for days over something
  that is simply not built yet, and filling strangers' retry queues is a way to
  get an instance blocked. Moderated replies are phase 3 (#491).

  ## Nothing is fetched for an activity that changes nothing

  Authentication needs the sender's key, and the key lives in the sender's actor
  document — so verifying *anything* costs an outbound HTTPS GET to a host the
  unauthenticated caller named. That is a ~200-byte POST turned into a fetch of
  up to `RemoteActor`'s byte cap, aimed wherever the caller likes, occupying a
  web-tier process for as long as the fetch takes (#966).

  So the fetch is not the first thing that happens. `needs_actor?/2` answers,
  from the activity and this site's own identity alone, whether the actor
  document could change the outcome: only a `Follow` or an `Undo{Follow}`
  **addressed to this site's actor** can. Everything else — every `Like`, every
  `Announce`, every misdelivered `Follow` — is accepted and ignored without a
  single byte leaving the server.

  The trade is that "which activity types this software acts on" becomes
  observable before authentication. That is a property of the release, not of
  the site: it is in this module's docs, and a prober could equally read them.

  What survives is the case that has to: a `Follow` naming us. `RemoteActor`
  caches what it fetches, so a repeat from the same actor is answered from
  memory rather than re-fetched.
  """

  alias KilnCMS.Federation
  alias KilnCMS.Federation.Activity
  alias KilnCMS.Federation.Actor
  alias KilnCMS.Federation.DeliveryWorker
  alias KilnCMS.Federation.Follower
  alias KilnCMS.Federation.HttpSignature
  alias KilnCMS.Federation.RemoteActor

  require Ash.Query
  require Logger

  @doc """
  Verify and act on one inbound activity.

  `:ok` means "handled or deliberately ignored" — both answer 202.
  `{:error, reason}` is an authentication failure and answers 401.
  """
  @spec handle(map(), map(), [{String.t(), String.t()}], binary(), Ash.UUID.t(), keyword()) ::
          :ok | {:error, String.t()}
  def handle(settings, activity, headers, raw_body, org_id, _opts \\ []) do
    identity = Actor.identity(settings)

    if needs_actor?(activity, identity) do
      with {:ok, actor_uri} <- actor_uri(activity),
           {:ok, remote} <- RemoteActor.fetch(actor_uri),
           :ok <- verify(settings, remote, headers, raw_body) do
        act(settings, activity, remote, org_id)
      end
    else
      Logger.debug("Federation inbox ignoring #{inspect(activity["type"])} without a fetch")
      :ok
    end
  end

  # Whether the sender's actor document could change what this request does —
  # see the moduledoc. Deliberately the *whole* precondition `act/4` applies,
  # not just the type: a `Follow` addressed to somebody else is dropped there
  # whatever the document says, so fetching one buys nothing.
  #
  # Every clause must stay in step with `act/4` below in one direction only: it
  # is safe for this to say `true` where `act/4` ignores (a wasted fetch), and a
  # bug for it to say `false` where `act/4` acts (an unauthenticated write).
  # Keep the patterns identical and the pair cannot drift silently.
  defp needs_actor?(%{"type" => "Follow"} = activity, identity),
    do: object_uri(activity) == identity.actor_id

  defp needs_actor?(%{"type" => "Undo", "object" => %{"type" => "Follow"} = follow}, identity),
    do: object_uri(follow) == identity.actor_id

  defp needs_actor?(_activity, _identity), do: false

  # ── authentication ──────────────────────────────────────────────────────────

  # `host` comes from the site's **pinned origin**, never from the request.
  # `conn.host` is the client's own `Host` header (or HTTP/2 `:authority`), so
  # verifying against it binds a signature to nothing: the same signed request
  # replays against any other Kiln deployment by setting `Host:` to the original
  # target. Binding to the origin the actor id was minted under is what makes a
  # signature mean "for this site".
  defp verify(settings, remote, headers, raw_body) do
    host = settings |> Actor.identity() |> Map.fetch!(:origin) |> Actor.host()

    with {:ok, key_id} <- HttpSignature.key_id(headers),
         true <- RemoteActor.owns_key?(remote, key_id),
         pem when is_binary(pem) <- remote.public_key_pem do
      HttpSignature.verify("post", inbox_path(), headers, raw_body, pem, host: host)
    else
      false -> {:error, "signature key does not belong to the sending actor"}
      nil -> {:error, "sending actor publishes no public key"}
      {:error, reason} -> {:error, reason}
    end
  end

  # The path the signature's `(request-target)` covers. Fixed because the route
  # is fixed — deriving it from the request would let a caller choose what was
  # verified.
  defp inbox_path, do: "/actor/inbox"

  defp actor_uri(%{"actor" => actor}) when is_binary(actor), do: {:ok, actor}
  defp actor_uri(%{"actor" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp actor_uri(_activity), do: {:error, "activity names no actor"}

  # ── acting ──────────────────────────────────────────────────────────────────

  # `needs_actor?/2` has already established that this Follow names us — but the
  # check is repeated rather than assumed. It is the rule that keeps a stranger
  # from signing this site up to somebody else's firehose, and a caller that
  # reaches `act/4` by another path (a future one, a test) must meet it too.
  defp act(settings, %{"type" => "Follow"} = activity, remote, org_id) do
    identity = Actor.identity(settings)

    if object_uri(activity) == identity.actor_id do
      record_follow(activity, identity, remote, org_id)
    else
      # Not addressed to us. Not an authentication failure, so it is accepted
      # and dropped rather than argued with.
      Logger.debug("Federation inbox ignoring Follow addressed to #{object_uri(activity)}")
      :ok
    end
  end

  # Only an `Undo` that names a **Follow**, and only one addressed to *this*
  # site. Two separate reasons:
  #
  #   * `Undo{Like}`/`Undo{Announce}` are far more common and carry `object` as
  #     a bare URI string, so a catch-all clause would silently delete a
  #     follower for un-liking one post;
  #   * an `Undo{Follow}` produced legitimately for another instance would
  #     otherwise be accepted here, which is the payload that makes a replay
  #     across deployments useful.
  defp act(
         settings,
         %{"type" => "Undo", "object" => %{"type" => "Follow"} = follow},
         remote,
         org_id
       ) do
    if object_uri(follow) == settings |> Actor.identity() |> Map.fetch!(:actor_id) do
      unfollow(remote.id, org_id)
    else
      Logger.debug("Federation inbox ignoring an Undo{Follow} addressed elsewhere")
      :ok
    end
  end

  defp act(_settings, %{"type" => type}, _remote, _org_id) do
    Logger.debug("Federation inbox accepted and ignored a #{type}")
    :ok
  end

  defp act(_settings, _activity, _remote, _org_id), do: :ok

  # Every write here is soft. `FederationController.inbox/2` promises never to
  # 5xx on an inbound activity, and a 500 is exactly what makes a remote server
  # retry for days — so a racing upsert or a database hiccup must not raise.
  defp record_follow(activity, identity, remote, org_id) do
    with :ok <- check_inbox_host(remote),
         :ok <- check_follower_ceiling(org_id) do
      do_record_follow(activity, identity, remote, org_id)
    else
      {:error, reason} ->
        Logger.info("Federation inbox refused a follow: #{reason}")
        :ok
    end
  end

  # A follower's inbox is a URL from the follower's own document, and every
  # publish POSTs to it. Without this, one actor can name a victim's server as
  # its inbox and turn the site's editorial calendar into a signed flood aimed
  # at a third party.
  defp check_inbox_host(remote) do
    if RemoteActor.same_host?(remote.inbox, remote.id) and
         (is_nil(remote.shared_inbox) or RemoteActor.same_host?(remote.shared_inbox, remote.id)) do
      :ok
    else
      {:error, "inbox host does not match the actor's"}
    end
  end

  # `one_per_actor` dedups an exact URI, so one attacker domain serving N actor
  # URLs is N rows — each one a delivery target on every publish, forever. The
  # ceiling is what stops a follower list from becoming an amplifier.
  defp check_follower_ceiling(org_id) do
    if Ash.count!(Follower, authorize?: false, tenant: org_id) < Federation.max_followers() do
      :ok
    else
      {:error, "this site is at its follower ceiling"}
    end
  end

  defp do_record_follow(activity, identity, remote, org_id) do
    case Federation.follow(remote.id, remote.inbox, %{shared_inbox_uri: remote.shared_inbox},
           authorize?: false,
           tenant: org_id
         ) do
      {:ok, follower} ->
        enqueue_accept(activity, identity, follower, org_id)

      {:error, reason} ->
        Logger.warning("Federation inbox could not record a follow: #{inspect(reason)}")
        :ok
    end
  end

  defp unfollow(actor_uri, org_id) do
    Follower
    |> Ash.Query.filter(actor_uri == ^actor_uri)
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> Enum.each(&Ash.destroy(&1, authorize?: false, tenant: org_id))

    :ok
  rescue
    error ->
      Logger.warning("Federation inbox could not remove a follower: #{Exception.message(error)}")
      :ok
  end

  # The `Accept` goes out through the ordinary delivery machinery, so it gets
  # the same signing, retries and ledger row every other activity does. A
  # follow that is never accepted silently does not stick on Mastodon.
  defp enqueue_accept(activity, identity, follower, org_id) do
    accept = Activity.accept_follow(activity, identity)

    case Federation.create_federation_delivery(
           %{
             follower_id: follower.id,
             inbox_uri: Follower.delivery_inbox(follower),
             activity_type: :accept,
             activity: accept
           },
           authorize?: false,
           tenant: org_id
         ) do
      {:ok, delivery} ->
        %{"org_id" => org_id, "delivery_id" => delivery.id}
        |> DeliveryWorker.new()
        |> Oban.insert()

        :ok

      {:error, reason} ->
        Logger.warning("Federation inbox could not enqueue an Accept: #{inspect(reason)}")
        :ok
    end
  end

  defp object_uri(%{"object" => object}) when is_binary(object), do: object
  defp object_uri(%{"object" => %{"id" => id}}) when is_binary(id), do: id
  defp object_uri(_activity), do: nil

  @doc "Whether federation is on for this deployment and this site."
  @spec settings(Ash.UUID.t()) :: {:ok, struct()} | :error
  def settings(org_id) do
    if Federation.enabled?() do
      case Ash.read(KilnCMS.Federation.SiteFederation, authorize?: false, tenant: org_id) do
        {:ok, [%{enabled: true, origin: origin} = settings]} when is_binary(origin) ->
          {:ok, settings}

        _other ->
          :error
      end
    else
      :error
    end
  end
end
