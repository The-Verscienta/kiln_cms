defmodule KilnCMSWeb.Embed do
  @moduledoc """
  Framing policy for **embeddable forms** (`GET /forms/:slug/embed`).

  The embed page is a self-contained document served from the CMS origin and
  designed to be iframed on third-party sites. The site-wide CSP pins
  `frame-ancestors 'self'`, which would block exactly that, so the embed route
  serves its own policy built here.

  Which parents may frame it comes from `:embed_origins` config, read on each
  request from what `config/runtime.exs` resolved `EMBED_ORIGINS` to at boot:

    * `[]` (**the default**, i.e. `EMBED_ORIGINS` unset) — same-origin only
      (`'self'`), so cross-site embedding is off until an operator opts in.
    * `[origin, …]` — an allowlist, e.g.
      `EMBED_ORIGINS=https://acme.com,https://blog.acme.com`. The rendered
      policy **keeps `'self'`** alongside the allowlist, so opting a partner
      site in never takes same-origin framing away.
    * `:all` (`EMBED_ORIGINS=*`) — any site may embed the form.

  ## Why the default is closed (#562)

  It used to be `:all`, on the reasoning that the embed page carries no ambient
  credentials: it is an anonymous public form, and a cross-site iframe never
  receives the `SameSite=Lax` session cookie. That much is still true — there is
  no session to steal here.

  What it misses is that framing is itself the attack. `frame-ancestors *` lets
  any site overlay the form invisibly and harvest into *your* submissions table
  under *your* org's branding, and form submission is deliberately CSRF-free
  (bounded only by the honeypot and the `:form` bucket), so nothing else stands
  behind it. A closed default costs an allowlist entry; an open one is a control
  that has to be remembered rather than one that holds by default.

  ## Malformed settings close, they never widen

  `frame-ancestors` is the last directive `content_security_policy/0` emits, so
  a source carrying a `;` would append arbitrary directives to the header, and
  one carrying whitespace would smuggle in extra sources. A bare `*` among
  otherwise sensible entries — the shape an operator reaches for when reading
  "the default used to be `*`" — would re-open the policy completely while
  looking like an allowlist.

  So an allowlist is **all-or-nothing**: every entry must look like a CSP host
  source (`valid_source?/1`), and if any does not, the whole setting is
  discarded for `'self'` rather than partially applied. `parse_env/1` catches
  the same thing at boot and warns on stderr naming the offending entries, so
  the operator learns from a log line rather than from a blank iframe.

  ## Scope

  `:embed_origins` is **deployment-global**, while forms are org-scoped. On a
  multi-org deployment one allowlist governs every org's embed page — see #648.

  Scripts on the embed page are external files under `script-src 'self'`
  (`/embed-frame.js`), so no nonce or `unsafe-inline` is needed.
  """

  require Logger

  # Same-origin only. Cross-site embedding is opt-in via EMBED_ORIGINS (#562).
  @default_origins []

  # A CSP host source: scheme, host (optionally wildcarded), port, path. Kept
  # deliberately narrow — see "Malformed settings close" above. `'self'` and
  # friends are not accepted here; `frame_ancestors/1` always prepends `'self'`.
  @source_pattern ~r{^[A-Za-z0-9.\-*:/\[\]]+$}

  @doc "The `frame-ancestors` source list for the embed page's CSP."
  @spec frame_ancestors() :: String.t()
  def frame_ancestors, do: frame_ancestors(configured_origins())

  @doc """
  The `frame-ancestors` source list for a given `:embed_origins` setting.

  An allowlist renders as `'self'` plus its entries. Anything unrecognised —
  a non-list, an empty list, or a list with even one entry that is not a valid
  host source — falls back to `'self'`: a malformed setting must not widen the
  policy, and must not be silently applied in part.
  """
  @spec frame_ancestors(:all | [String.t()]) :: String.t()
  def frame_ancestors(:all), do: "*"

  def frame_ancestors(origins) when is_list(origins) do
    if origins != [] and Enum.all?(origins, &valid_source?/1) do
      Enum.join(["'self'" | origins], " ")
    else
      "'self'"
    end
  end

  def frame_ancestors(_other), do: "'self'"

  @doc """
  Whether any site other than the embed page's own origin may frame it.

  Derived from the rendered policy rather than the raw setting, so a malformed
  `EMBED_ORIGINS` — which `frame_ancestors/1` closes — reports as closed here
  too. Note this is the *deployment* answer; it cannot tell an admin whether
  their particular org's site is on the list (#648).
  """
  @spec cross_site?() :: boolean()
  def cross_site?, do: frame_ancestors() != "'self'"

  @doc """
  The configured allowlist as a display string, or `nil` when embedding is
  closed. For admin UI that needs to show *which* origins are permitted.
  """
  @spec allowed_origins_label() :: String.t() | nil
  def allowed_origins_label do
    case configured_origins() do
      :all -> "*"
      origins when is_list(origins) and origins != [] -> Enum.join(origins, ", ")
      _ -> nil
    end
  end

  @doc """
  The full Content-Security-Policy for embed responses (the form page and the
  thank-you page it posts to). Same-origin everything, except `frame-ancestors`.
  """
  @spec content_security_policy() :: String.t()
  def content_security_policy do
    "default-src 'self'; " <>
      "script-src 'self'; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data: blob:; " <>
      "font-src 'self' data:; " <>
      "connect-src 'self'; " <>
      "object-src 'none'; base-uri 'self'; form-action 'self'; " <>
      "frame-ancestors #{frame_ancestors()}"
  end

  @doc """
  Warn once per node when a request is being framed by another site and the
  policy will not allow it (#650).

  #562 flipped the default to same-origin only, which is silent for anyone who
  was relying on the old open one: the CMS logs a healthy 200 for every
  `/forms/:slug/embed` request, and the *browser* discards the response. The
  operator's signals were an Upgrading note they had to read at the right
  moment, a banner two clicks into a form they have no reason to reopen, and a
  CSP violation in somebody else's console. None of them is a server-side
  signal after the fact.

  The request itself carries the evidence. A cross-origin parent sends
  `Sec-Fetch-Dest: iframe` with a `Sec-Fetch-Site` that is not `same-origin`,
  so when that arrives and the policy is closed the app knows with near
  certainty that the response is about to be thrown away.

  `same-site` counts as blocked, not just `cross-site`: `frame-ancestors
  'self'` matches the *origin*, so a sibling subdomain is refused exactly like
  an unrelated host — and a subdomain is the likeliest first thing an operator
  tries.

  At most once an hour per node, via `:persistent_term`, so a busy embed route
  cannot flood the log. Best-effort: a race that logs twice is harmless, and the
  alternative costs a serialization point on a public route.

  Once *ever* per node would be quieter, and was the first shape here — but
  Fetch Metadata is only unspoofable inside a browser. `curl -H 'sec-fetch-dest:
  iframe' -H 'sec-fetch-site: cross-site'` sets it freely, so a single scanner
  hit would claim the one-shot and the operator's own broken embed would then
  say nothing at all until the next deploy. An hour bounds what one probe can
  suppress, and a genuinely broken embed page is being retried anyway.

  Deliberately not a boot check — a boot warning cannot know whether the
  deployment uses embeds at all, so it would fire on every default install and
  become noise, and per #634 it would reach stderr only, never Logger sinks or
  Sentry.
  """
  @spec warn_if_framing_blocked(Plug.Conn.t()) :: :ok
  def warn_if_framing_blocked(conn) do
    if framed_by_another_site?(conn) and not cross_site?() and claim_warning?() do
      Logger.warning(
        "An embed request arrived framed by #{parent_origin(conn) || "another site"}, " <>
          "but EMBED_ORIGINS is unset so the embed page is same-origin only — the " <>
          "browser will discard this response and the form will not appear. Set " <>
          "EMBED_ORIGINS to the parent origins allowed to frame it, e.g. " <>
          "EMBED_ORIGINS=https://acme.com,https://blog.acme.com (or `*` for every " <>
          "site). Logged at most hourly per node; see docs/forms.md."
      )
    end

    :ok
  end

  # Only the browser can say it is framing us, and Fetch Metadata is the header
  # that says it: browser-set and forbidden to scripts, so no page can forge it.
  # A plain `curl` still can — see `claim_warning?/0` for why that only costs an
  # hour. A request with no `Sec-Fetch-Dest` at all — an old browser, a
  # server-side fetch — tells us nothing, so it does not warn.
  #
  # All four embedding destinations, not just `iframe`: `frame-ancestors`
  # governs `<frameset>`, `<embed>` and `<object>` identically, and an operator
  # who reached for one of those is exactly the one who needs telling.
  @framed_dests [["iframe"], ["frame"], ["embed"], ["object"]]

  defp framed_by_another_site?(conn) do
    dest = Plug.Conn.get_req_header(conn, "sec-fetch-dest")
    site = Plug.Conn.get_req_header(conn, "sec-fetch-site")

    dest in @framed_dests and site not in [[], ["same-origin"], ["none"]]
  end

  # The parent's origin, for the message. `Referer` is the only header that
  # carries it, and a strict referrer policy on the parent can strip it — hence
  # the caller's fallback wording. Origin only: userinfo, path and query are
  # dropped, so a credential or a query-string identifier in the parent's URL
  # never reaches the log.
  #
  # `Referer` is attacker-controlled and this string goes into a log line, so it
  # is checked before it is used, not merely parsed. `URI.parse/1` happily
  # returns a host containing ESC — an operator reading `journalctl` would get
  # terminal escapes executed at them. Bandit's HTTP/1 parser rejects CR/LF/NUL,
  # but that is one transport's parser, not a property of the value.
  @origin_charset ~r/\A[a-zA-Z0-9.\-:\[\]_%]+\z/
  @max_host 100

  defp parent_origin(conn) do
    with [referer | _] <- Plug.Conn.get_req_header(conn, "referer"),
         %URI{scheme: scheme, host: host, port: port} <- URI.parse(referer),
         true <- is_binary(scheme) and is_binary(host) and host != "",
         true <- String.length(host) <= @max_host,
         true <- Regex.match?(@origin_charset, scheme <> host) do
      URI.to_string(%URI{scheme: scheme, host: host, port: port})
    else
      _no_usable_referer -> nil
    end
  end

  @warning_key {__MODULE__, :framing_warned_at}
  @rearm_after System.convert_time_unit(3600, :second, :native)

  # Monotonic time, not wall clock: a node whose clock steps backwards would
  # otherwise mute this for as long as the step.
  defp claim_warning? do
    now = System.monotonic_time()
    last = :persistent_term.get(@warning_key, nil)

    if is_integer(last) and now - last < @rearm_after do
      false
    else
      # Replacing a key schedules a global scan, so this must stay rare — which
      # is exactly what the hour buys. The `get` above short-circuits every
      # other request, spoofed or not.
      :persistent_term.put(@warning_key, now)
      true
    end
  end

  @doc false
  # The claim outlives a test, so the suite needs a way to arm it again.
  def reset_framing_warning, do: :persistent_term.erase(@warning_key)

  @doc """
  Parses an `EMBED_ORIGINS` env value. A lone `"*"` → `:all`; a comma-separated
  list → an allowlist; blank or unset → `[]` (same-origin only).

  Entries that are not valid CSP host sources — including a `*` mixed into a
  list, which would re-open the policy — discard the whole value for `[]` and
  warn on stderr, following the fail-to-default-and-say-so rule
  `KilnCMS.Config.Env` sets for the boolean variables.

  The split/trim/wildcard half lives in `KilnCMS.Config.OriginList`, shared with
  `CORS_ORIGINS` (#651); what stays here is the half that is actually about
  CSP — `valid_source?/1`, and the rendering in `frame_ancestors/1`.
  """
  @spec parse_env(String.t() | nil) :: :all | [String.t()]
  def parse_env(value) do
    KilnCMS.Config.OriginList.parse(value,
      name: "EMBED_ORIGINS",
      validator: &valid_source?/1,
      describe: "frame-ancestors source",
      example: "https://acme.com,https://blog.acme.com"
    )
  end

  # A bare `*` is rejected here on purpose: as a lone value `parse_env/1` has
  # already turned it into `:all`, so reaching this means it was mixed into a
  # list, where joining it would silently grant every site.
  defp valid_source?(source) when is_binary(source) do
    source != "*" and Regex.match?(@source_pattern, source)
  end

  defp valid_source?(_source), do: false

  defp configured_origins, do: Application.get_env(:kiln_cms, :embed_origins, @default_origins)
end
