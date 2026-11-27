defmodule KilnCMSWeb.CollabSocket do
  @moduledoc """
  Socket for the collaborative-editing CRDT prototype (`KilnCMS.Collab.Crdt`).

  Connections authenticate with a `Phoenix.Token` minted by the content
  editor's LiveView mount — which is itself editor/admin-gated — so only
  signed-in editors can ever hold a valid token. No token, no socket.

  The token names a **user**, not a document: it is minted once per editor
  session and outlives a working day. So it establishes *who*, and nothing
  more — `KilnCMSWeb.CollabChannel` decides *what* they may join, per topic
  (#655). Resolving the user here rather than carrying a bare id also means a
  token naming a since-deleted account is refused at the next connect, instead
  of reaching the channel as an id nothing will look up.

  An *already-established* session used to keep whatever it was granted, since
  `join/3` runs once and nothing dropped the socket. `KilnCMS.Accounts.SessionEviction`
  now does, from the actions that demote, erase, or narrow a scope — the `id/1`
  below is the topic it broadcasts on (#675). The change nobody wired an
  eviction into is caught by `KilnCMSWeb.CollabChannel`'s own periodic re-check
  (#775), which reloads the actor this module resolved and re-runs the join.

  The tenant comes from the connect URI's host, the same source `SetTenant`
  uses for HTTP (epic #336, #563). Sockets bypass the plug pipeline, so
  `connect_info: [:uri]` in the endpoint is what makes the host reachable at
  all; without it every collab session resolved to the default org.

  ## The token names the session it was minted for (#2490)

  Besides the user, the token carries the jti of the browser session whose
  editor minted it (`"j"`), and the connection lives no longer than that
  session. Without it, signing one session out — from the settings page, by
  the site's idle timeout or "sign out everyone", or with the browser's own
  Sign out — closed that session's pages but left its open rooms editing for
  up to a day, since only per-user eviction reached this socket.

    * At connect the session's token row is read and must be a live sign-in
      (`Token.user_purpose/0`, unexpired) of this account that the site would
      let a page through on (`KilnCMS.Accounts.IdleTimeout.check_row/3`, no
      use noted): an idle, revoked, foreign-site or pre-"sign out everyone"
      session is refused, and so is a jti that names another account's row, a
      held two-factor sign-in or a remember-me cookie. A row that cannot be
      read fails open, as the HTTP and LiveView checks do.
    * A connection that passes subscribes to
      `KilnCMS.Accounts.SessionEviction.session_socket_topic/1`, so every
      per-session sign-out drops it at once. The subscription is made only
      after the last refusal: a refused upgrade leaves the HTTP/1 process
      alive for keep-alive, and a stray subscription would outlive the refusal
      into a later upgrade on that connection.
    * `KilnCMSWeb.CollabChannel`'s periodic re-check repeats the session check,
      for a revocation no broadcast reached.

  `id/1` stays per user, so per-user eviction still reaches the socket.

  A token minted before #2490 has no `"j"`: it is still accepted, with the
  per-user semantics it always had, for this release only (it lives a day).
  """
  use Phoenix.Socket

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Token

  require Logger

  channel "collab:*", KilnCMSWeb.CollabChannel

  # Editor sessions are long-lived; tokens outlive a working day.
  @max_age 60 * 60 * 24

  @impl true
  def connect(%{"token" => token}, socket, connect_info) when is_binary(token) do
    # Charged first, ahead of token verification (threat-model item 11's
    # `/ws/*` gap — see `KilnCMSWeb.SocketJoinBudget`): a connect this
    # deployment is about to refuse anyway still cost a handshake, so it
    # still has to count.
    with :ok <- KilnCMSWeb.IpBlock.check_connect(:collab, connect_info),
         :ok <- KilnCMSWeb.SocketJoinBudget.charge(:collab_join, connect_info),
         {:ok, claims} <-
           Phoenix.Token.verify(KilnCMSWeb.Endpoint, "collab", token, max_age: @max_age),
         {user_id, verified?, session_jti} = claims(claims),
         # The struct match matters: a `not_found_error?: false` interface would
         # return `{:ok, nil}`, and an anonymous actor reads published content.
         {:ok, %{} = actor} <- fetch_actor(user_id),
         {:ok, org} <- fetch_org(connect_info),
         # The session the token was minted for (#2490): signed out, idle,
         # bound to another site, or not this account's sign-in at all.
         false <- session_refused?(session_jti, actor, org),
         # The token is minted for a day, possibly during the grace period of
         # a site that requires a second factor: an account the site now
         # holds for one it has not set up is refused (#2247), and so is a
         # passkey-only account past its deadline whose token came from a
         # session that never passed the passkey. The channel's periodic
         # re-check closes a socket that crosses the deadline.
         false <- refused?(actor, org.id, verified?),
         # The admin allowlist (#2248): the console's own socket. After the
         # site is resolved, so an unserved host is refused (and alerted) there
         # first; the address is kept for the channel's periodic re-check.
         {:ok, client_ip} <- KilnCMSWeb.AdminAllowlist.check_connect(:collab, connect_info) do
      # After every refusal above, never before: see the moduledoc on why a
      # refused connect must leave no subscription behind.
      subscribe_session(session_jti)

      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:org, org)
       |> assign(:client_ip, client_ip)
       |> assign(:second_factor_verified?, verified?)
       |> assign(:session_jti, session_jti)}
    else
      _refused -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @doc """
  The token for `user`'s collab socket, bound to the browser session
  `session_jti` it is minted for (#2490). `second_factor_verified?` is whether
  that session passed a second factor at sign-in
  (`KilnCMSWeb.SecondFactorGate.session_verified?/1`), which a passkey-only
  account past its deadline needs (#2247).

  There is no clause without a session: a page that cannot name its session
  gets no token, and edits on its own.
  """
  @spec token(KilnCMS.Accounts.User.t(), boolean(), String.t()) :: String.t()
  def token(user, second_factor_verified?, session_jti) when is_binary(session_jti) do
    # Signed, not encrypted, so the jti is readable in the page's DOM. That
    # is deliberate: a node still running the previous release must be able
    # to verify this token during a rolling deploy, and a jti authenticates
    # nothing on its own — every use of one checks the row's subject against
    # the account that presents it.
    Phoenix.Token.sign(KilnCMSWeb.Endpoint, "collab", %{
      "u" => user.id,
      "sf" => second_factor_verified? == true,
      "j" => session_jti
    })
  end

  defp claims(%{"u" => user_id, "sf" => verified?, "j" => jti}) when is_binary(jti),
    do: {user_id, verified? == true, jti}

  # Legacy tokens, minted before #2490 with no session (and before #2247 with
  # the id alone, no second factor shown): accepted, per user as they always
  # were, for this release only — they live a day, so none survives the next
  # upgrade. Remove both clauses in the next release (#2490 follow-up).
  defp claims(%{"u" => user_id, "sf" => verified?} = claims) when not is_map_key(claims, "j"),
    do: legacy({user_id, verified? == true, nil})

  defp claims(user_id) when is_binary(user_id), do: legacy({user_id, false, nil})

  defp claims(_malformed), do: {nil, false, nil}

  defp legacy(claims) do
    Logger.info("Collab socket connect with a legacy collab token (no session)")
    claims
  end

  @doc """
  Whether the session `session_jti` refuses a collab connection of `actor` on
  `org` (#2490): its token row is not a live, unexpired sign-in of `actor`, or
  `KilnCMS.Accounts.IdleTimeout` signs it out on this site (idle, revoked,
  bound to another site, older than the site's last "sign out everyone").
  Never notes a use. An idle session is expired here, recorded with surface
  `"collab"`, and evicted.

  `nil` — a legacy token that names no session — is not refused. A row that
  cannot be read is not refused either (fails open, as every other idle check
  does). Shared with `KilnCMSWeb.CollabChannel`'s periodic re-check.
  """
  @spec session_refused?(String.t() | nil, KilnCMS.Accounts.User.t(), struct()) :: boolean()
  def session_refused?(nil, _actor, _org), do: false

  def session_refused?(session_jti, actor, org) when is_binary(session_jti) do
    policy = IdleTimeout.policy(org.id)

    case IdleTimeout.read(session_jti, policy) do
      {:ok, row} -> row_refused?(row, actor, org, policy)
      :error -> false
    end
  end

  # `IdleTimeout`'s verdict reads only `"revocation"` as signed out, so a held
  # two-factor sign-in or a remember-me row would pass it; and it ignores
  # `expires_at`. Both are judged here, from the same read.
  defp row_refused?(nil, _actor, _org, _policy), do: true

  defp row_refused?(%Token{} = row, actor, org, policy) do
    if row.purpose == Token.user_purpose() and unexpired?(row) do
      opts = [
        policy: policy,
        subject: AshAuthentication.user_to_subject(actor),
        touch?: false,
        tier: fn -> KilnCMS.Accounts.Scoping.effective_tier(actor, org.id) end,
        user: actor,
        surface: "collab"
      ]

      match?({:signed_out, _why}, IdleTimeout.check_row(row, org.id, opts))
    else
      true
    end
  end

  defp unexpired?(%Token{expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) == :gt

  defp unexpired?(_row), do: false

  # `connect/3` runs in the transport process, which becomes the socket's
  # (`Phoenix.Transports.WebSocket` upgrades in place), so this subscription
  # is the socket's own and `Phoenix.Socket` closes on the `"disconnect"`
  # broadcast it delivers. `KilnCMSWeb.GraphqlSocket`'s `close_at/1` relies on
  # the same.
  defp subscribe_session(nil), do: :ok

  defp subscribe_session(session_jti),
    do: KilnCMSWeb.Endpoint.subscribe(SessionEviction.session_socket_topic(session_jti))

  @doc """
  Whether a collab connection of `actor` is refused on `org_id`: the site
  holds the account, or it is a passkey-only account past its deadline and
  the token's session never passed a second factor. Shared with
  `KilnCMSWeb.CollabChannel`'s periodic re-check.
  """
  @spec refused?(KilnCMS.Accounts.User.t(), Ash.UUID.t(), boolean()) :: boolean()
  def refused?(actor, org_id, second_factor_verified?) do
    if second_factor_verified?,
      do: KilnCMSWeb.SecondFactorGate.held?(actor, org_id, fresh?: true),
      else: KilnCMSWeb.SecondFactorGate.bearer_refused?(actor, org_id)
  end

  @impl true
  # Phoenix drops every socket whose `id/1` matches a `"disconnect"` broadcast,
  # which is how `KilnCMS.Accounts.SessionEviction` reaches this one. Built by
  # that module rather than spelled here, so the two cannot drift onto different
  # strings — a mismatch would leave the socket connected while the caller
  # believed it dropped (#675).
  def id(socket), do: KilnCMS.Accounts.SessionEviction.topic(socket.assigns.actor.id)

  # A token outlives the account it names by up to a day. Resolving now means a
  # deleted editor cannot keep collaborating on the strength of a token minted
  # before they were removed.
  defp fetch_actor(user_id) when is_binary(user_id) do
    # authorize?: false — pre-auth — this read IS what produces the actor, so no
    # actor exists yet, and `User`'s read policy is admin-or-self anyway. The id
    # comes from a verified `Phoenix.Token`, not from the client.
    Accounts.get_user(user_id, authorize?: false)
  end

  defp fetch_actor(_other), do: :error

  # The refusal alerts (#678) — from here, the decision point, not from
  # `Tenant.fetch_org_from_connect_info/1` itself.
  defp fetch_org(connect_info) do
    case KilnCMSWeb.Tenant.fetch_org_from_connect_info(connect_info) do
      {:ok, org} ->
        {:ok, org}

      :error ->
        KilnCMSWeb.TenantRefusalAlert.notify(
          :collab,
          KilnCMSWeb.Tenant.connect_info_host(connect_info)
        )

        :error

      # A failed lookup, not an unserved host: refused the same way (a socket
      # has no 503 to send) but never alerted — the alert counts hosts this
      # deployment does not serve, and this may be one it does.
      :unavailable ->
        :error
    end
  end
end
