defmodule KilnCMSWeb.Embed do
  @moduledoc """
  Framing policy for **embeddable forms** (`GET /forms/:slug/embed`).

  The embed page is a self-contained document served from the CMS origin and
  designed to be iframed on third-party sites. The site-wide CSP pins
  `frame-ancestors 'self'`, which would block exactly that, so the embed route
  serves its own policy built here.

  Which parents may frame it comes from **the form's own `embed_origins`**, and
  from `:embed_origins` config for a form that has none — read on each request
  from what `config/runtime.exs` resolved `EMBED_ORIGINS` to at boot:

    * `[]` (**the default**, i.e. `EMBED_ORIGINS` unset) — same-origin only
      (`'self'`), so cross-site embedding is off until somebody opts in. Since
      #648 that somebody is either the operator here or an org admin on the
      form; there is deliberately no operator ceiling over the latter, because
      what a form's `frame-ancestors` governs is who may overlay *that org's*
      form and harvest *that org's* submissions. Nothing it grants crosses a
      tenant boundary.
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

  `frame-ancestors` is the last directive `content_security_policy/1` emits, so
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

  ## Per form, because forms are org-scoped (#648)

  `EMBED_ORIGINS` has no tenant dimension. On a multi-org deployment it is
  necessarily the **union** of every org's embedders — and that union is what
  every org's forms become framable by, which is #562's overlay-and-harvest
  attack one tenant boundary over. It also cannot answer the question the
  builder's Embed tab asks ("may my embedders frame *this* form?"), only the
  deployment-wide approximation of it.

  So `KilnCMS.CMS.Form` carries a nullable `embed_origins`, and every function
  here takes the form:

    * a form with `embed_origins: nil` — inherit `EMBED_ORIGINS`. This is the
      default and the whole single-org story: nothing changes for a deployment
      that never sets it.
    * `embed_origins: []` — same-origin only for that form, whatever the
      deployment allows.
    * `embed_origins: [origin, …]` — that form's allowlist **instead of** the
      deployment's, not on top of it. Union would put the shared list back and
      with it the leak: an org narrowing its own form could not then narrow it
      below whatever another org had needed added globally.

  A form's list is written by an org admin, and validated on write by
  `KilnCMS.CMS.Validations.CspOrigins` — a strictly narrower grammar than
  `valid_source?/1` accepts from the operator (full origin required, no bare
  `*`), so anything stored also passes the render-time check below.

  Passing `nil` in place of a form is the deployment answer, used where there is
  no form to speak for — a 404 on `/forms/:slug/embed`, where naming a policy
  for a form that does not exist would answer a question about whether it does.

  A form's `nil` no longer always means the deployment, though: `KilnCMS.Forms.
  EmbedPolicy` (#1131) resolves a per-org default *before* handing anything to
  this module, for an org whose forms mostly share one allowlist. Every
  function here still means exactly what it says above — the form-vs-deployment
  question — because `EmbedPolicy.effective/1` rewrites a form with no list of
  its own into one already carrying its org's default, when it has one. This
  module has no org-awareness added to it on purpose: the ladder gained a rung,
  not a new data source this half needs to know about.

  Scripts on the embed page are external files under `script-src 'self'`
  (`/embed-frame.js`), so no nonce or `unsafe-inline` is needed.
  """

  require Logger

  # Same-origin only. Cross-site embedding is opt-in via EMBED_ORIGINS (#562).
  @default_origins []

  # A CSP host source: scheme, host (optionally wildcarded), port, path. Kept
  # deliberately narrow — see "Malformed settings close" above. `'self'` and
  # friends are not accepted here; `frame_ancestors/1` always prepends `'self'`.
  #
  # `\A`/`\z`, NOT `^`/`$`. Elixir's `Regex` is PCRE, where `$` matches *before a
  # final newline* — so `"https://ok.example\n"` satisfied the `$`-anchored
  # version and put a newline inside a response header, which is the one input
  # this predicate exists to stop. Same trap, and same fix, as the anchors in
  # `KilnCMS.CMS.Validations.CspOrigins`.
  @source_pattern ~r{\A[A-Za-z0-9.\-*:/\[\]]+\z}

  @doc """
  A form's **own** allowlist, or `:deployment` when it has none (#648).

  The only place the attribute's shape is read. Everything else here — the
  rendered directive, the admin label, the warning — asks this, so "what does
  `nil` mean, and what is `[]`" is answered once. A second reader is how the
  three states drift into two.
  """
  @spec own_origins(map() | nil) :: [String.t()] | :deployment
  def own_origins(nil), do: :deployment

  def own_origins(%{embed_origins: origins}) when is_list(origins), do: origins

  def own_origins(%{embed_origins: nil}), do: :deployment

  # The remaining shape is `%Ash.NotLoaded{}` — a form read with a `select` that
  # omitted the attribute. It must not fall through to the deployment default:
  # a form that had narrowed its own policy (or closed it with `[]`) would
  # silently get the shared union back, which is the leak this whole change
  # exists to close, and a widening no test would notice. It can only be
  # reached by a code change inside this repo, so it says so instead.
  def own_origins(%{embed_origins: not_loaded}) do
    raise ArgumentError,
          "KilnCMSWeb.Embed was handed a form whose :embed_origins is " <>
            "#{inspect(not_loaded)} — a read that did not select it. Select the " <>
            "attribute, or pass nil to ask for the deployment-wide policy on purpose."
  end

  @doc """
  Which origins govern a given form's embed page: its own `embed_origins` when
  it has one, else the deployment's `EMBED_ORIGINS` (#648).

  `nil` in place of a form asks the deployment question directly.
  """
  @spec origins_for(map() | nil) :: :all | [String.t()]
  def origins_for(form) do
    case own_origins(form) do
      :deployment -> configured_origins()
      origins -> origins
    end
  end

  @doc "The `frame-ancestors` source list for one form's embed page (#648)."
  @spec frame_ancestors_for(map() | nil) :: String.t()
  def frame_ancestors_for(form), do: form |> origins_for() |> frame_ancestors()

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

  # A form, not a setting. Without this clause it would reach the catch-all and
  # render `'self'` — a form's own allowlist dropped in silence, which reads on
  # the wire as "this deployment has embedding off" rather than as the bug it is.
  # Keyed on the attribute, not on `%_struct{}`: a plain map carrying
  # `:embed_origins` is a form everywhere else in this module and in its tests,
  # and a guard that only caught structs would let exactly those through.
  def frame_ancestors(form) when is_map(form) and is_map_key(form, :embed_origins) do
    raise ArgumentError,
          "frame_ancestors/1 takes an :embed_origins setting (:all or a list), not " <>
            "a form. Use frame_ancestors_for/1 for a form."
  end

  def frame_ancestors(_other), do: "'self'"

  @doc """
  Whether any site other than the embed page's own origin may frame this form.

  Derived from the rendered policy rather than the raw setting, so a malformed
  setting — which `frame_ancestors/1` closes — reports as closed here too.

  No default argument, deliberately: `nil` means "the deployment-wide answer",
  and that is the widening `own_origins/1` raises rather than guess at. A caller
  that can omit the form is a caller that can *forget* it, in a module whose
  whole job is not to hand one tenant another tenant's policy.
  """
  @spec cross_site?(map() | nil) :: boolean()
  def cross_site?(form), do: frame_ancestors_for(form) != "'self'"

  @doc """
  The origins allowed to frame this form, as a display string, or `nil` when
  embedding is closed. For admin UI that needs to show *which* origins are
  permitted — and since #648 that answer is the one actually served for this
  form, not a deployment-wide approximation of it.

  Gated on `cross_site?/1` rather than read off the raw setting, so the panel
  cannot name an origin the header does not actually grant — the failure #562's
  all-or-nothing rule makes possible, where one bad entry closes a list that
  still *reads* like an allowlist.
  """
  @spec allowed_origins_label(map() | nil) :: String.t() | nil
  def allowed_origins_label(form) do
    if cross_site?(form) do
      case origins_for(form) do
        :all -> "*"
        origins -> Enum.join(origins, ", ")
      end
    end
  end

  @doc """
  The full Content-Security-Policy for one form's embed responses (the form page
  and the thank-you page it posts to). Same-origin everything, except
  `frame-ancestors`, which is this form's policy (#648).
  """
  @spec content_security_policy(map() | nil) :: String.t()
  def content_security_policy(form) do
    "default-src 'self'; " <>
      "script-src 'self'; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data: blob:; " <>
      "font-src 'self' data:; " <>
      "connect-src 'self'; " <>
      "object-src 'none'; base-uri 'self'; form-action 'self'; " <>
      "frame-ancestors #{frame_ancestors_for(form)}"
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

  At most once an hour **per form** per node, via `:persistent_term`, so a busy
  embed route cannot flood the log. Best-effort: a race that logs twice is
  harmless, and the alternative costs a serialization point on a public route.

  Per form, not per node, since #648: the policy is now the form's, so two forms
  can be closed for different reasons and want different fixes. A single node
  claim would let the first one silence the rest for an hour — and a `curl` at a
  slug that does not exist would silence every real form, because a 404 shares
  the deployment-wide claim. The keys are bounded by the number of embeddable
  forms, which is an admin-defined handful.

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
  @spec warn_if_framing_blocked(Plug.Conn.t(), map() | nil) :: :ok
  def warn_if_framing_blocked(conn, form) do
    if framed_by_another_site?(conn) and not cross_site?(form) and claim_warning?(form) do
      Logger.warning(
        "An embed request for #{subject(form)} arrived framed by " <>
          "#{parent_origin(conn) || "another site"}, but #{closed_by(form)}, so the " <>
          "embed page is same-origin only — the browser will discard this response " <>
          "and the form will not appear. #{remedy(form)} Logged at most hourly per " <>
          "form per node; see docs/forms.md."
      )
    end

    :ok
  end

  # Which form, so an operator with a dozen of them can go and fix the right
  # one. The slug is the handle the URL and the builder both use.
  defp subject(nil), do: "a slug that matches no form"
  defp subject(form), do: "the form #{inspect(Map.get(form, :slug))}"

  # Which of the two settings actually closed this page, and therefore which one
  # to go and edit. A form with its own list has taken the deployment variable
  # out of the picture, so naming `EMBED_ORIGINS` there is advice that changes
  # nothing — and vice versa.
  #
  # Both branches say only what has been checked. "Unset" is not claimed: a
  # value that `parse_env/1` refused as malformed also lands here, and sending
  # an operator to look for a variable they know they set is worse than saying
  # neither.
  defp closed_by(form) do
    case own_origins(form) do
      :deployment ->
        "EMBED_ORIGINS allows nobody (unset, blank, or refused as malformed) and " <>
          "this form sets no allowlist of its own"

      _own_list ->
        "this form's own Embed allowlist allows nobody"
    end
  end

  defp remedy(form) do
    case own_origins(form) do
      :deployment ->
        "Allow the parent origins on the form's Embed tab, or set EMBED_ORIGINS " <>
          "deployment-wide, e.g. EMBED_ORIGINS=https://acme.com,https://blog.acme.com " <>
          "(or `*` for every site)."

      _own_list ->
        "Add the parent origins on the form's Embed tab."
    end
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

  @rearm_after System.convert_time_unit(3600, :second, :native)

  # One claim per form (#648), so a form closed for one reason cannot mute a
  # different form closed for another. A request that matched no form shares a
  # single `:deployment` claim — it can only ever be about `EMBED_ORIGINS`, and
  # giving a made-up slug its own key would let a scanner mint unbounded ones.
  defp warning_key(nil), do: {__MODULE__, :framing_warned_at, :deployment}
  defp warning_key(form), do: {__MODULE__, :framing_warned_at, Map.get(form, :id)}

  # Monotonic time, not wall clock: a node whose clock steps backwards would
  # otherwise mute this for as long as the step.
  defp claim_warning?(form) do
    key = warning_key(form)
    now = System.monotonic_time()
    last = :persistent_term.get(key, nil)

    if is_integer(last) and now - last < @rearm_after do
      false
    else
      # Replacing a key schedules a global scan, so this must stay rare — which
      # is exactly what the hour buys. The `get` above short-circuits every
      # other request, spoofed or not, and the key set is bounded by the number
      # of embeddable forms rather than by traffic.
      :persistent_term.put(key, now)
      true
    end
  end

  @doc false
  # The claims outlive a test, so the suite needs a way to arm them again. Every
  # form's key, not just the deployment one — a test that reset only its own
  # would still be muted by whichever form ran before it.
  def reset_framing_warning do
    for {key, _value} <- :persistent_term.get(),
        is_tuple(key),
        tuple_size(key) == 3,
        elem(key, 0) == __MODULE__,
        elem(key, 1) == :framing_warned_at do
      :persistent_term.erase(key)
    end

    :ok
  end

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
