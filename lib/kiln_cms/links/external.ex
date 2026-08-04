defmodule KilnCMS.Links.External do
  @moduledoc """
  Asks whether one outbound URL is still there (#474).

  The external half of the broken-link checker. `KilnCMS.Links.Internal` answers
  the same question for same-origin paths with a database query; this one has to
  leave the building, which changes almost everything about how the answer is
  treated.

  ## The rule is the internal half's rule, under worse conditions

  "I could not resolve it" is not "it is broken". Internally that meant refusing
  to judge paths outside a namespace Kiln owns. Here it means the web is full of
  servers that answer a checker differently from a browser: bot walls return
  403, paywalls 401, CDNs 429, and a great many hosts refuse `HEAD` outright.
  None of that is evidence a *reader* would hit a dead link, so none of it is
  reported.

  Four outcomes, and only one of them ever reaches an author:

    * `:ok` — a 2xx, possibly after redirects.
    * `:broken` — 404 or 410, or a redirect chain that never lands. Definitive.
    * `:transient` — a 5xx, a timeout, a refused connection, a name that did not
      resolve. **Retried before it is flagged**, by the caller
      (`KilnCMS.Links.CheckWorker`), which is what stops a five-minute outage at
      a popular host from marking every page that cites it as broken.
    * `:undetermined` — 401/403/429 and every other 4xx, and any address the SSRF
      guard refuses to dial. Never shown to anyone, never escalates.

  A dead domain arrives as `:transient` (nothing resolves it) rather than
  `:broken`, and that is deliberate: DNS fails for a minute quite often and
  permanently rather rarely, so the consecutive-failure counter is what
  distinguishes them. It is the single most common genuinely-broken external
  link, and the one classification most worth being patient about.

  ## HEAD first, and why the answer is not believed

  A `HEAD` costs the far end nothing to answer, so it goes first. But a
  meaningful minority of servers return 403, 405 or even 404 to a `HEAD` and
  serve the same URL perfectly to a `GET`, so those statuses are re-asked with a
  `GET` rather than believed. That doubles traffic for some broken links, which
  is the right way round: a false "broken" costs an author a search for a fault
  that does not exist, and a checker that does that twice is one nobody reads.

  ## Egress, safety and pacing

  Every request goes through `KilnCMS.SafeFetch` — address-pinned against DNS
  rebinding, size-capped, and following redirects **by hand** so each hop is
  re-validated (`:max_redirects`; see that module). URLs here are author-typed,
  which is exactly the input class the pinning exists for.

  This module does not pace itself. `KilnCMS.Links.Throttle` is consulted by the
  worker, which is the only caller able to give the slot back while it waits.
  """

  alias KilnCMS.Links.Throttle
  alias KilnCMS.SafeFetch

  require Logger

  @type outcome :: :ok | :broken | :transient | :undetermined

  @typedoc """
  One check's verdict.

  `status` is the final HTTP status when there was one (`nil` for a failure that
  never got that far), and `reason` a short diagnostic for the report — English
  and untranslated on purpose: it is `Req.TransportError` text and status
  phrases, aimed at whoever has to fix the link.
  """
  @type result :: %{outcome: outcome(), status: integer() | nil, reason: String.t() | nil}

  # Enough of the response to see the status line. The body is discarded, but
  # `truncate_body: true` means a large page comes back as a truncated 200
  # rather than as an error — without it every long article would read as a
  # failed check.
  @max_bytes 32 * 1024
  @max_redirects 5

  # Statuses that are re-asked with GET rather than believed. 404 is in the list
  # because some servers genuinely do serve one to HEAD and a 200 to GET, and
  # the false positive is the expensive direction.
  @head_unreliable [400, 403, 404, 405, 406, 501]

  # The only statuses this module is willing to call broken.
  @definitely_gone [404, 410]

  @doc """
  Whether `url` is something this checker can even ask about.

  Absolute `http(s)` only. `mailto:`, `tel:`, `javascript:`, fragments and
  same-origin paths are all *links*, but none of them are a request — and a
  checker that reported them as unverifiable would fill the report with rows
  nobody can act on. Same-origin paths belong to `KilnCMS.Links.Internal`.
  """
  @spec checkable?(term()) :: boolean()
  def checkable?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _other ->
        false
    end
  end

  def checkable?(_url), do: false

  @doc "The host `url` addresses, downcased — the throttle's bucket key."
  @spec host(String.t()) :: String.t() | nil
  def host(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _other -> nil
    end
  end

  def host(_url), do: nil

  @doc """
  Check one URL. See `t:result/0`.

  Options are passed to `KilnCMS.SafeFetch`; `:req_options` is the seam a test
  uses to answer from a `Req.Test` stub instead of the network.
  """
  @spec check(String.t(), keyword()) :: result()
  def check(url, opts \\ [])

  def check(url, opts) when is_binary(url) do
    if checkable?(url) do
      url |> String.trim() |> request(opts) |> classify(url)
    else
      undetermined("not an absolute http(s) URL")
    end
  end

  def check(_url, _opts), do: undetermined("not an absolute http(s) URL")

  defp request(url, opts) do
    case fetch(:head, url, opts) do
      {:ok, %{status: status}} when status in @head_unreliable -> fetch(:get, url, opts)
      result -> result
    end
  end

  defp fetch(method, url, opts) do
    options =
      Keyword.merge(
        [
          max_bytes: @max_bytes,
          max_redirects: @max_redirects,
          truncate_body: true,
          headers: [{"user-agent", user_agent()}, {"accept", "*/*"}],
          # The test seam, in config rather than threaded through every caller:
          # the worker is three layers above this and has no business knowing
          # that a `Req.Test` stub exists.
          req_options: Keyword.get(config(), :req_options, [])
        ],
        opts
      )

    apply(SafeFetch, method, [url, options])
  end

  defp classify({:ok, %{status: status}}, _url) when status in 200..299,
    do: %{outcome: :ok, status: status, reason: nil}

  # Still a 3xx after `@max_redirects` hops: a loop, or a chain longer than any
  # real link. A visitor's browser gives up on this too, so it is broken.
  defp classify({:ok, %{status: status}}, _url) when status in 300..399 do
    %{
      outcome: :broken,
      status: status,
      reason: "redirect chain did not resolve within #{@max_redirects} hops"
    }
  end

  defp classify({:ok, %{status: status}}, _url) when status in @definitely_gone,
    do: %{outcome: :broken, status: status, reason: "HTTP #{status}"}

  # Every other 4xx. A bot wall, a paywall, a rate limiter, a WAF — all of which
  # a reader with a browser sails past.
  defp classify({:ok, %{status: status}}, _url) when status in 400..499,
    do: undetermined("HTTP #{status} (not conclusive from a checker)", status)

  defp classify({:ok, %{status: status}}, _url) when status >= 500,
    do: %{outcome: :transient, status: status, reason: "HTTP #{status}"}

  defp classify({:ok, %{status: status}}, url) do
    Logger.debug("link check: unexpected status #{inspect(status)} for #{url}")
    undetermined("unexpected HTTP status #{status}", status)
  end

  defp classify({:error, reason}, _url) when is_binary(reason), do: classify_error(reason)

  # Reasons `SafeFetch` returns as strings. Matching on their text is a real
  # coupling — `KilnCMS.Webhooks.SafeUrl` writes them and nothing enforces the
  # wording — so `test/kiln_cms/links/external_test.exs` pins every branch. The
  # split matters: a name that does not resolve is a link that may genuinely be
  # dead and must be allowed to escalate, while an address the guard refuses is
  # a decision about *us* and must never become an author's problem.
  defp classify_error(reason) do
    cond do
      String.contains?(reason, "could not be resolved") ->
        transient("hostname could not be resolved")

      String.contains?(reason, "resolution timed out") ->
        transient("hostname resolution timed out")

      String.starts_with?(reason, "blocked URL:") or
          String.starts_with?(reason, "blocked redirect") ->
        undetermined(reason)

      true ->
        # Timeouts, refused connections, TLS failures and anything else the
        # transport reports. Transient by default, because the caller retries
        # before flagging and the cost of being patient is one more night.
        transient(reason)
    end
  end

  defp transient(reason), do: %{outcome: :transient, status: nil, reason: reason}

  defp undetermined(reason, status \\ nil),
    do: %{outcome: :undetermined, status: status, reason: reason}

  @doc """
  The user-agent every check sends.

  Identifying, and deliberately **version-less**. A link checker announces
  itself to every site an author has ever cited, so the string is a permanent
  broadcast of what this deployment runs — the same disclosure argument that
  keeps `Kiln.Updates` on a bare `KilnCMS`. What a site operator needs is a name
  to allow or block and a URL explaining the traffic; a build number tells them
  nothing and tells an attacker which advisories to try.

  Operators who want to be reachable append their own contact:

      config :kiln_cms, KilnCMS.Links.External,
        user_agent: "KilnCMS-LinkCheck (+https://acme.example/bots)"
  """
  @spec user_agent() :: String.t()
  def user_agent do
    Keyword.get(
      config(),
      :user_agent,
      "KilnCMS-LinkCheck (+https://github.com/The-Verscienta/kiln_cms)"
    )
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])

  @doc """
  Whether a host may be dialled now, or how long to wait.

  A thin pass-through to `KilnCMS.Links.Throttle` so callers do not have to know
  both modules; see that module on why waiting is the worker's job.
  """
  @spec throttle(String.t() | nil) :: :ok | {:error, {:rate_limited, non_neg_integer()}}
  defdelegate throttle(host), to: Throttle, as: :check
end
