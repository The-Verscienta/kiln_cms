defmodule KilnCMSWeb.RateLimit do
  @moduledoc """
  ETS-backed rate limiter for API and auth endpoints (Hammer fixed window).
  """
  use Hammer, backend: :ets

  @default_limits %{
    gql: {60, :timer.minutes(1)},
    api: {120, :timer.minutes(1)},
    # Doubled from the original 20/min (#747). A two-factor sign-in is *two*
    # requests through this bucket — `POST /sign-in` (or `/api/auth/sign_in`)
    # for the password, then `/sign-in/verify` (or `.../sign_in/verify`) for
    # the code — and every mistyped code costs another. 20/min was sized when
    # a sign-in was one request; 40 keeps the same "twenty sign-ins a minute
    # from one address" headroom now that a 2FA account spends two per attempt,
    # without changing what actually bounds credential guessing — that is the
    # per-account budget (`KilnCMS.Accounts.AccountThrottle`), not this one.
    # This bucket stays the *volume* bound rather than the guessing bound
    # precisely because it is per-IP and shared addresses (an office or CI
    # runner's egress NAT) are expected to collide on it — the per-account
    # budget is what has to hold up under that collision, same reasoning as
    # `:register`'s own bucket above.
    auth: {40, :timer.minutes(1)},
    # Account creation (#724). Its own bucket rather than a share of `:auth`,
    # so a burst of legitimate sign-ups from one office NAT cannot lock
    # *sign-in* for everyone behind it. Tighter in absolute terms because
    # registering is rarer and more expensive than attempting a sign-in: a
    # bcrypt hash and a confirmation mail per request.
    register: {5, :timer.minutes(1)},
    # Public HTML delivery — generous, just a flood/abuse ceiling per IP.
    delivery: {300, :timer.minutes(1)},
    # Signed preview links — tight, to slow token enumeration / draft scraping.
    preview: {30, :timer.minutes(1)},
    # Passphrase attempts against locked content (#496). Tighter than `:form`
    # and separate from `:auth`, because this is the one bucket standing between
    # a shared secret and a brute force: the passphrase is chosen by an editor
    # for convenience, so it is short and guessable far more often than a
    # password is, and there is no account to lock out instead.
    unlock: {10, :timer.minutes(1)},
    # Public form submissions — tight per IP; a human fills a handful of
    # forms a minute, a spammer fills hundreds.
    form: {20, :timer.minutes(1)},
    # Always-on Swagger UI explorer (#225) — generous for human browsing, caps
    # crawler/abuse traffic against the docs UI.
    docs: {60, :timer.minutes(1)},
    # Infra/SEO endpoints (`/up`, `/sitemap.xml`, `/robots.txt`). Generous so
    # legitimate load-balancer probes and crawlers are never throttled, while
    # still bounding a flood that would otherwise run an unthrottled DB query
    # (`/up`) or table scan (sitemap cache-miss) per hit.
    probe: {600, :timer.minutes(1)},
    # Inbound payment-provider webhooks. The provider delivers from a small egress
    # IP set and can burst (a dunning run, a redelivery backfill), so the tight
    # `:form` bucket would silently drop real events — and a dropped entitlement
    # event is a paying member locked out. Generous per IP; the real authorization
    # is the HMAC signature, not the rate limit.
    billing_webhook: {300, :timer.minutes(1)},
    # `/live` root joins per client address (#1183, `KilnCMSWeb.LiveJoinBudget`).
    # A flood ceiling, not a usage cap: a root join happens once per page LOAD
    # (patch/navigate inside a live_session does not remount), so twenty editors
    # behind one office NAT reloading a few times a minute stay far under it,
    # while a scripted replay of one scraped `data-phx-session` token is over
    # it in seconds. Sized like `:delivery` — the same "one address, one
    # minute" shape — rather than like `:auth`, because a mount is not a guess.
    live_join: {300, :timer.minutes(1)},
    # Frames from one ACCOUNT over `/ws/collab` (#1305,
    # `KilnCMSWeb.SocketEventBudget`) — every `handle_in/3` and the `join/3`
    # that opened the channel, keyed on the actor rather than the address
    # (legitimate collaboration is itself a high-frequency stream and one
    # office NAT holds many editors) or the connection (a reconnect must not
    # mint a fresh budget, and the honest recovery from a refusal IS a
    # reconnect). Sized against the fastest human, given what the client emits:
    # one Yjs update per keystroke (~15/s at the very fastest), and awareness
    # frames COALESCED client-side to at most ten a second (`assets/js/collab.js`
    # — without that, a mouse-drag selection re-announced the caret at the
    # browser's event rate and one long drag could reach this on its own). A
    # furious minute is therefore ~900 + 600 + the 15s heartbeat, well under
    # 2,000; a script is over 6,000 in seconds. It is a flood ceiling per
    # account: what it bounds is the per-frame work — a `DocServer` apply and a
    # room fan-out per update, and a full re-authorization (three DB reads)
    # every `SocketReauth.update_floor/0` of them — that one credential could
    # otherwise cause without limit. Over it, the connection is closed and the
    # account's rejoins are refused until the window turns; the client
    # reconciles what it typed meanwhile on the join that succeeds.
    collab_event: {6_000, :timer.minutes(1)},
    # `/ws/gql`, `/ws/bridge`, `/ws/collab` connects per client address
    # (`KilnCMSWeb.SocketJoinBudget`) — the `/ws/*` half of the same
    # threat-model item `:live_join` closed the `/live` half of. Same "one
    # address, one minute" flood-ceiling shape and size; three separate
    # buckets rather than one shared with each other (or with `:live_join`/
    # `:gql`) so a flood against the one of the three that is anonymous by
    # default (`/ws/gql`) cannot spend a budget a signed-in editor's
    # `/ws/collab` session then pays for from the same office NAT.
    gql_join: {300, :timer.minutes(1)},
    bridge_join: {300, :timer.minutes(1)},
    collab_join: {300, :timer.minutes(1)}
  }

  @doc false
  # Test seam: the shipped limits, before the test env's overrides. Nothing in
  # production should read this — `limits/0` is the effective policy. It exists
  # so the suite can still pin the numbers the threat model states for the
  # buckets it also has to raise in order to run (#715).
  @spec default_limits() :: %{atom() => {pos_integer(), pos_integer()}}
  def default_limits, do: @default_limits

  @doc """
  Effective per-bucket limits: the defaults, with any per-bucket overrides from
  `config :kiln_cms, KilnCMSWeb.RateLimit, limits: %{bucket => {limit, scale}}`
  merged over them. Production leaves this unset (the defaults apply); the test
  env raises the buckets the broad controller suites hammer (`:api` etc.) so a
  fast full-suite run doesn't saturate one per-IP window and 429 unrelated tests.
  """
  def limits do
    case configured_limits() do
      # No override (production default): return the constant, no per-request
      # merge/allocation on this hot-path plug.
      empty when map_size(empty) == 0 -> @default_limits
      overrides -> Map.merge(@default_limits, overrides)
    end
  end

  defp configured_limits do
    Application.get_env(:kiln_cms, __MODULE__, []) |> Keyword.get(:limits, %{})
  end

  # A client whose address the transport did not report. Not an address, so it
  # cannot collide with one — every such caller shares one budget, which is the
  # safe reading of "we do not know who this is".
  @unknown_client "unknown"

  @doc """
  The bucket key for a client address.

  One function so that every caller spells an address the same way: the plug
  keys on `conn.remote_ip`, and `KilnCMSWeb.SignInLive` keys on an address
  resolved from a socket handshake (#715). Those two must produce the same
  string for the same client, or the shared `:auth` bucket is two buckets.
  """
  @spec client_key(:inet.ip_address() | nil) :: String.t()
  def client_key(nil), do: @unknown_client

  def client_key(address) do
    # `:inet.ntoa/1` answers `{:error, :einval}` rather than raising on anything
    # that is not an address tuple. This runs on a public page's hot path, so
    # the miss shares the unknown bucket instead of 500ing the request.
    case :inet.ntoa(address) do
      formatted when is_list(formatted) -> to_string(formatted)
      _invalid -> @unknown_client
    end
  end

  @doc """
  Returns `:allow` or `{:deny, retry_after_ms}` for the given bucket key.

  The key is a client address from `client_key/1` for every address-keyed
  bucket, and an account (or connection) key from
  `KilnCMSWeb.SocketEventBudget.key/1` for the socket event buckets (#1305).
  Whichever it is, one function spells it, so two charges for the same client
  land on the same key.
  """
  def check(bucket, key) when is_atom(bucket) and is_binary(key) do
    {limit, scale} = Map.fetch!(limits(), bucket)

    case hit(bucket_key(bucket, key), scale, limit) do
      {:allow, _count} -> :allow
      {:deny, retry_after} -> {:deny, retry_after}
    end
  end

  defp bucket_key(bucket, key), do: "#{bucket}:#{key}"
end
