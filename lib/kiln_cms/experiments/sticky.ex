defmodule KilnCMS.Experiments.Sticky do
  # Declared ABOVE the moduledoc so the prose can interpolate them. Writing the
  # numbers as literals is how a privacy claim goes stale silently: "an integer
  # in 0..99" is a statement about anonymity, and it has to change when
  # `@buckets` does.

  # 100 buckets: enough that a weighted split lands where it should, few enough
  # that the value is shared by a crowd rather than naming a person.
  @buckets 100

  # Small on purpose: see the moduledoc. A visitor exposed to a fifth
  # content-view experiment loses their oldest exposure rather than carrying a
  # longer, more distinguishing value.
  @max_exposures 4

  @default_max_age_days 30

  @moduledoc """
  Optional sticky assignment for the built-in site (#984, #499 phase 3).

  **Off by default, and that default is the promise.** `docs/data-flows.md`
  states that no cookie is recorded for visitors, and with this unset that stays
  literally true — nothing here runs, no cookie is read, none is written.

      config :kiln_cms, KilnCMS.Experiments, sticky: true

  ## What is stored, and why it is not an identifier

  One cookie holding **a bucket, not an id**: an integer in `0..#{@buckets - 1}`.
  It is
  drawn at random on a visitor's first experimented page and read back on later
  ones, so the same visitor keeps the same arm instead of re-drawing on every
  reload.

  The bucket space is deliberately small. With #{@buckets} possible values, the
  cookie
  cannot single anybody out — on any site with more than #{@buckets} visitors,
  every value is shared by many people — so it cannot be used as a visitor
  identifier even by something that wanted to. Nothing server-side is keyed by
  it: it is read, used to pick an arm, and discarded within the request. Kiln
  stores no row, writes no log line, and joins it to nothing.

  It is also not signed or encrypted, on purpose. A signature would be derived
  from the deployment's secret and would make the value unique-ish and
  attacker-opaque, which is the opposite of what a bucket wants to be. Nothing
  rides in it worth protecting: a visitor who edits it picks their own arm,
  which is exactly the power they already have by clearing it and reloading.

  ## Lifetime

  #{@default_max_age_days} days by default, configurable. Long enough to outlive the experiment a
  visitor is in — which is what makes their behaviour consistent across the
  visit and the return visit — and short enough not to be a standing marker.
  A year is the reflex default and would be one.

      config :kiln_cms, KilnCMS.Experiments, sticky: true, sticky_max_age_days: 14

  ## The exposure cookie

  A bucket alone cannot attribute the `content_view` goal, and the reason is
  worth stating because it is easy to get wrong: *every* visitor has a bucket,
  so a bucket says which arm someone **would** be in, not that they ever saw the
  experiment. Counting a conversion off the bucket alone would count people who
  never encountered the test.

  So a second cookie, `_kiln_ab_x`, records exposure — and only for the goals
  that convert on a later page (`:content_view` and `:funnel_completion`), since
  nothing else needs it. It holds up to
  #{@max_exposures} variant ids, and an id is **removed the moment it
  converts**, so one exposure counts once and the cookie shrinks back to nothing
  on its own.

  This one is closer to an identifier than the bucket is, and the honest
  statement of the cost is: its value space is the set of arms of the running
  later-page experiments, so with one such experiment it distinguishes nothing
  beyond which arm you are in, and with several the *combination* starts to
  narrow a visitor down. That is what the small cap and the shared lifetime are
  for. Nothing server-side is keyed by it either — it is read, a counter is
  incremented, and the id is dropped.
  """

  @cookie_base "_kiln_ab"
  @exposure_base "_kiln_ab_x"

  # `Secure` and the `__Host-` prefix ride ONE expression, and it is the SAME
  # flag `KilnCMSWeb.SessionCookie` uses — a second source of truth is how a
  # deployment ends up with a `Secure` session cookie beside a plaintext bucket.
  #
  # The prefix matters here for the reason it mattered for the session (#686):
  # every org is a sibling origin under one base host, and any of them can write
  # a `Domain=.<base_host>` cookie under a bare name. `Plug.Conn.Cookies` is
  # first-wins and RFC 6265 sends longer paths first, so a planted `_kiln_ab`
  # would outrank the visitor's own — pinning a whole audience to one arm, or
  # planting another org's variant id as an exposure that then converts. A
  # browser refuses to STORE a `__Host-` cookie that carries a `Domain`, so the
  # write never happens.
  @secure Application.compile_env(:kiln_cms, :secure_session_cookie, false) == true
  @host_prefix "__Host-"

  # Separator for the exposure list. Not a comma: a comma is outside RFC 6265's
  # `cookie-octet` and is exactly what intermediaries use to fold several
  # `Set-Cookie` headers into one. Plug round-trips it fine, so this would only
  # ever break in front of a real proxy — and only for a visitor carrying more
  # than one exposure, which is the case no test would build.
  @separator "."

  @doc """
  The bucket cookie's name, exported so tests and docs cannot drift from it.

  `__Host-`-prefixed wherever the deployment's cookies are `Secure` — dev, test
  and e2e run over plain HTTP, where a browser would silently discard a
  prefixed cookie, so those get the bare name.
  """
  @spec cookie() :: String.t()
  def cookie, do: name(@cookie_base)

  @doc "The exposure cookie's name. Prefixed on the same rule as `cookie/0`."
  @spec exposure_cookie() :: String.t()
  def exposure_cookie, do: name(@exposure_base)

  defp name(base), do: if(@secure, do: @host_prefix <> base, else: base)

  @doc "How many distinct buckets exist."
  @spec buckets() :: pos_integer()
  def buckets, do: @buckets

  @doc "Whether the operator turned sticky assignment on. False unless they did."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :sticky, false) == true

  @doc """
  The visitor's bucket for this request, and the conn to answer with.

  Returns `{bucket, conn}`. `bucket` is `nil` when sticky assignment is off, in
  which case the conn comes back untouched and the caller draws per request as
  before.

  A cookie carrying anything that is not a bucket in range — junk, a stale value
  from a deployment with a different bucket count, an attacker's string — is
  replaced rather than trusted, so a malformed value cannot pin a visitor
  outside the split.
  """
  @spec bucket(Plug.Conn.t()) :: {non_neg_integer() | nil, Plug.Conn.t()}
  def bucket(conn) do
    if enabled?(), do: fetch_or_mint(conn), else: {nil, conn}
  end

  defp fetch_or_mint(conn) do
    conn = Plug.Conn.fetch_cookies(conn)

    case parse(conn.cookies[cookie()]) do
      {:ok, bucket} -> {bucket, conn}
      :error -> mint(conn)
    end
  end

  defp mint(conn) do
    bucket = :rand.uniform(@buckets) - 1
    {bucket, Plug.Conn.put_resp_cookie(conn, cookie(), Integer.to_string(bucket), cookie_opts())}
  end

  # One list for both cookies: a future decision about `path` or the prefix must
  # not have to be made twice and get made differently.
  defp cookie_opts do
    [
      max_age: max_age_seconds(),
      # No script needs to read it, and the visitor's own tooling reading it is
      # the thing a bucket is least interesting for.
      http_only: true,
      # Not `Strict`: a visitor arriving from a link elsewhere is the common
      # case for a landing page under test, and `Strict` would drop the cookie
      # exactly there and re-draw their arm.
      same_site: "Lax",
      # The two the `__Host-` prefix depends on alongside the name. Pinned
      # rather than left to Plug's defaults, so a later edit has to state the
      # intent to break them — a browser discards a violating `__Host-` cookie
      # silently.
      secure: @secure,
      path: "/"
    ]
  end

  defp parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {bucket, ""} when bucket >= 0 and bucket < @buckets -> {:ok, bucket}
      _otherwise -> :error
    end
  end

  defp parse(_absent), do: :error

  @doc "How many exposures one visitor can carry."
  @spec max_exposures() :: pos_integer()
  def max_exposures, do: @max_exposures

  @doc """
  The variant ids this visitor has been exposed to, and the conn to answer with.

  `{[], conn}` when sticky assignment is off — no cookie is read at all.

  Reads `conn.cookies`, which is the request's list **updated in place** by any
  `put_resp_cookie/4` already made on this conn (Plug's own `update_cookies/2`).
  That is what makes a read-modify-write within one request safe: a page that is
  one experiment's landing page *and* another's goal document writes an exposure
  and then spends a different one, and the second write sees the first.
  """
  @spec exposures(Plug.Conn.t()) :: {[String.t()], Plug.Conn.t()}
  def exposures(conn) do
    if enabled?() do
      conn = Plug.Conn.fetch_cookies(conn)
      {parse_exposures(conn.cookies[exposure_cookie()]), conn}
    else
      {[], conn}
    end
  end

  @doc """
  Record that this visitor saw `variant_id`.

  Returns `{:new | :repeat, conn}`. `:repeat` is a no-op on the cookie, for two
  reasons: re-setting it on every view would roll its lifetime forward
  indefinitely — how a bounded cookie quietly becomes a permanent one — and the
  caller uses `:new` to count **one impression per exposed visitor** rather than
  one per page view. That distinction is the difference between a conversion
  rate and a ratio of two unrelated numbers: a visitor can convert a
  `content_view` goal at most once, so counting their tenth reload of the
  landing page in the denominator makes a stickier arm look worse than it is.
  """
  @spec remember_exposure(Plug.Conn.t(), String.t()) :: {:new | :repeat, Plug.Conn.t()}
  def remember_exposure(conn, variant_id) do
    {current, conn} = exposures(conn)

    if variant_id in current do
      {:repeat, conn}
    else
      # Newest first, so the cap drops the oldest exposure.
      {:new, put_exposures(conn, Enum.take([variant_id | current], @max_exposures))}
    end
  end

  @doc """
  Replace the exposure list, or delete the cookie when nothing is left.

  Deleting rather than writing an empty value matters: the point of removing a
  converted exposure is that the visitor stops carrying it.
  """
  @spec put_exposures(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def put_exposures(conn, []), do: Plug.Conn.delete_resp_cookie(conn, exposure_cookie())

  def put_exposures(conn, ids) do
    Plug.Conn.put_resp_cookie(conn, exposure_cookie(), Enum.join(ids, @separator), cookie_opts())
  end

  # Only well-formed uuids survive, capped — the cookie is client-controlled, so
  # a hand-written one must not be able to hand us an unbounded list or a value
  # that reaches a query as anything other than a uuid.
  #
  # The CAST value, not the input: `Ecto.UUID.cast/1` also accepts an uppercase
  # uuid and a raw 16-byte binary, normalising both. Keeping the raw string
  # would let a hand-edited cookie carry four entries that pass validation, can
  # never equal a `variant.id`, and so are never spent — permanently occupying
  # the cap and blocking that visitor from ever being counted.
  defp parse_exposures(value) when is_binary(value) do
    value
    |> String.split(@separator, trim: true)
    |> Enum.flat_map(fn entry ->
      case Ecto.UUID.cast(entry) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@max_exposures)
  end

  defp parse_exposures(_absent), do: []

  @doc """
  Cookie lifetime in seconds.

  A non-positive or non-integer setting falls back to the default rather than
  being used. `sticky_max_age_days: 0` would emit `max-age=0`, which a browser
  reads as "expire now" — every request would re-mint, every request would
  re-draw the arm, and the deployment would be back to stateless assignment
  while the operator believed stickiness was on. `runtime.exs` already refuses
  that from the env var; this covers the `config/*.exs` route the moduledoc
  advertises.
  """
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds do
    case Keyword.get(config(), :sticky_max_age_days, @default_max_age_days) do
      days when is_integer(days) and days > 0 -> days * 24 * 60 * 60
      _invalid -> @default_max_age_days * 24 * 60 * 60
    end
  end

  defp config, do: Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
end
