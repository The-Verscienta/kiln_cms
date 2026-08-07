defmodule KilnCMS.RateLimitHelpers do
  @moduledoc """
  Test-only helpers for the files that assert on `KilnCMSWeb.RateLimit`'s
  counters rather than merely on its refusals (#715, #724, #877).

  ## Why a test may not measure the loopback bucket (#877)

  `Phoenix.ConnTest.build_conn/0` peers from `127.0.0.1`, so `auth:127.0.0.1`
  is the bucket every plain `ConnTest` request in the suite charges. A test
  that brackets an action with

      before = spent("auth", "127.0.0.1")
      # …do the thing…
      assert spent("auth", "127.0.0.1") == before + 1

  is therefore reading a counter the whole run writes to, and it is flaky —
  but *not* for the reason it looks like. The reachable mechanism is not
  another test file racing it: ExUnit runs every `async: true` module to
  completion before the first `async: false` one starts, and sync modules run
  one at a time, so nothing else is executing. It is Hammer's cleaner.

  `KilnCMSWeb.RateLimit` is started with `clean_period: :timer.minutes(1)`
  (`KilnCMS.Application`), and `Hammer.ETS.FixWindow.clean/1` is a blanket
  `:ets.select_delete` of every row whose window has closed. Counts are stored
  one row per `{key, window}` and `spent/2` sums them, so a key that has been
  charged across many one-minute windows — which `auth:127.0.0.1` has, by the
  time the sync phase runs — carries a stack of closed rows awaiting the next
  tick. When that tick lands *between* the two reads, the sum drops by a whole
  window's count and the assertion fails low. No concurrency required, and it
  disappears on a re-run, which is the signature #877 reported.

  `client_conn/1` is the fix: an address minted per test has exactly one row,
  written seconds ago, and no closed window for the cleaner to take.

  Residual, and deliberately not closed here: if the submit crosses a window
  boundary *and* a clean tick lands in that same gap, the baseline's row is
  taken and the delta reads short. That is the fixed-window-rollover family
  tracked as #697, not this one, and it needs a scale change rather than a key
  change.
  """

  alias KilnCMSWeb.RateLimit

  @doc """
  A client address no other test — and no other file — is spending.

  Returned as the string `RateLimit` keys buckets on, formatted through
  `RateLimit.client_key/1` rather than by hand so a test asserting against a
  key the *application* produced is comparing one spelling, not two.

  Spread wide because `rem(n, 250)` on a single octet is not enough:
  `System.unique_integer/1` is increasing but not contiguous (it strides by
  scheduler), so a one-octet scheme collides long before it looks like it
  should — and a collision does not necessarily self-heal. A caller that
  widens its bucket's *scale* to keep a fixed window from rolling mid-test
  (`credential_form_budget_test.exs` uses `{2, :timer.hours(1)}`) leaves rows
  the cleaner will not touch for an hour, so a reused address stays spent for
  the rest of the run rather than for the next minute.
  """
  @spec client_ip() :: String.t()
  def client_ip, do: RateLimit.client_key(client_address())

  @doc """
  The same address as `client_ip/0`, as an `:inet.ip_address/0` tuple.

  Confined to `10.128.0.0/9`, which keeps it clear of `KilnCMSWeb.Plugs.
  RateLimitTest`: that file drives `10.1.0.x`, `10.3.0.x`, `10.7.0.x` and
  `10.9.0.x` to *exhaustion* to prove the limiter refuses. Being handed one of
  those would 429 a page test's disconnected render and fail `live/2` with a
  `MatchError` naming nothing. Cheap insurance rather than a race anyone has
  hit: ExUnit fixes no order *within* the async phase, so those minute-scale
  buckets have usually expired and been swept before the sync phase reaches
  this helper's callers. It costs one octet of range to stop depending on
  that.

  The offset goes on the **second** octet, not the third, and that matters:
  the low 24 bits of `n` must survive untouched, or the map stops being
  injective. Folding an octet mod 255 to skip a value costs exactly that —
  `n` and `n + 65_280` then collide (`25` and `65_305` both give
  `10.0.1.25`), which hands two tests one bucket and reintroduces #877 by a
  different route. As written, `n` and `n'` collide only 2^23 apart.
  """
  @spec client_address() :: :inet.ip4_address()
  def client_address do
    n = System.unique_integer([:positive])
    {10, 128 + rem(div(n, 65_536), 128), rem(div(n, 256), 256), rem(n, 256)}
  end

  @doc """
  A conn whose client address is this test's own, and the address it will be
  charged under.

  Both halves are needed, and they are needed for different doors:

    * `put_peer_data/2` is what a **socket** handshake reads.
      `Phoenix.LiveViewTest` hands the dispatched conn to the view as its
      `connect_info`, and `get_connect_info(socket, :peer_data)` resolves it
      through `Plug.Conn.get_peer_data/1` — the adapter payload this writes.
      `KilnCMSWeb.SignInLive` reads exactly that.

    * `remote_ip` is what the **plug** door reads. A LiveView's disconnected
      render is a plain HTTP GET, and on `:browser_auth` that GET passes
      `KilnCMSWeb.Plugs.AuthRateLimit` (which delegates to
      `KilnCMSWeb.Plugs.RateLimit`, charging `:register` only on the
      registration POST and `:auth` on everything else). Left at loopback,
      merely loading the page spends the shared bucket this exists to avoid.

  Both are set to the *same* address on purpose: the property the callers
  assert is that the two doors agree on one client. That also means this
  helper cannot express a trusted-proxy request, where the peer is the proxy
  and `remote_ip` is the rewritten client — a test for `Plugs.ClientIp`'s
  forwarding rule needs to set the two apart itself.
  """
  @spec client_conn(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  def client_conn(%Plug.Conn{} = conn) do
    address = client_address()

    # Rematched on `%Plug.Conn{}` rather than piped: `put_peer_data/2` is typed
    # as a bare map (it only reaches into `:adapter`), so the struct update
    # below is a type error without it — and this file compiles under
    # `--warnings-as-errors` in CI.
    %Plug.Conn{} =
      conn = Plug.Test.put_peer_data(conn, %{address: address, port: 111, ssl_cert: nil})

    {%Plug.Conn{conn | remote_ip: address}, RateLimit.client_key(address)}
  end

  @doc """
  How much of an address's budget has been charged on `bucket`.

  Reads Hammer's own table because nothing else can distinguish "charged once"
  from "charged eleven times" below the limit — `check/2` answers `:allow`
  either way. Rows are `{{key, window}, count, expiry}` and a key accumulates
  one row per window, so every window is summed.

  Selected rather than `:ets.tab2list/1`-then-filtered: the table is node-wide
  and holds every bucket the whole suite has touched, and this is called on
  both sides of every assertion.
  """
  @spec spent(String.t() | atom(), String.t()) :: non_neg_integer()
  def spent(bucket, ip) do
    key = "#{bucket}:#{ip}"

    RateLimit
    |> :ets.select([{{{key, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.sum()
  end
end
