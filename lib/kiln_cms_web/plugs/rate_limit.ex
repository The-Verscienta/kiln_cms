defmodule KilnCMSWeb.Plugs.RateLimit do
  @moduledoc """
  Returns HTTP 429 when a client exceeds per-IP rate limits.

  API pipelines get the JSON error shape; browser pipelines (sign-in, public
  delivery pages) get a small HTML page instead of raw JSON (audit U-M7).

  ## `:delivery` is charged per client class (#2243)

  The request's `User-Agent` is classified (`KilnCMS.BotClass`) and the one
  per-address `:delivery` counter is charged against that class's ceiling
  (`KilnCMS.BotBudgets`). The operator's ceiling is charged first, without a
  database read, so a request it refuses never reaches the site's row; only an
  allowed non-browser request looks up the site's (cached) lower ceiling and is
  refused if the count is past it. The refusal is this plug's ordinary 429 and
  never names the class. Every `:delivery` check emits
  `[:kiln_cms, :delivery, :client_class]` with `%{class, result}` and nothing
  else: no user agent, address or org.

  Classification happens only here, on the `:delivery` pipeline. robots.txt,
  llms.txt, sitemaps, feeds and the health probes are on `:probe` and never
  classified.

  ## A search-engine claim is checked against DNS or a published list (#2254, #2586)

  A user agent that names a search engine is checked with
  `KilnCMS.CrawlerVerification.check/3`, which never waits on DNS, and the
  answer decides what the request is charged as:

    * `:verified`, or `:disabled` (verification is off): a search engine, at
      the search-engine ceiling.
    * `{:unverified, :failed}`, the claim is **proven** false (by DNS, or for
      DuckDuckBot by an address outside DuckDuckGo's fresh published list):
      charged as `:empty`, a client that will not say what it is.
    * any other `{:unverified, reason}` (the lookup is pending, was skipped or
      got no answer to its PTR or forward query, the engine cannot be
      verified, or the address is not one
      whose PTR record says anything about the client): a search engine, but
      with the operator's ceiling held to the `:delivery` limit
      (`KilnCMS.BotBudgets.unverified_search_limit/0`). A search-engine
      percentage above 100 is spent only on proven addresses; a site's lower
      value still applies.

  Every unverified claim also emits `[:kiln_cms, :delivery, :unverified_crawler]`
  with `%{engine, reason}`. The `:client_class` event's `class` is the class
  **charged**, so a proven spoof is reported as `:empty`. No other class is
  ever checked: a browser never reaches the verifier.
  """
  import Plug.Conn

  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.BotBudgets
  alias KilnCMS.BotClass
  alias KilnCMS.CrawlerVerification
  alias KilnCMS.Security.ApiKeyTrip
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Plugs.ClientIp
  alias KilnCMSWeb.RateLimit

  def init(bucket) when is_atom(bucket), do: bucket

  def call(conn, :delivery) do
    {class, operator_limit} = client_class(conn)

    case RateLimit.check_limit(:delivery, remote_ip(conn), operator_limit) do
      {:deny, retry_after_ms} ->
        conn |> record(class, :throttled) |> deny(retry_after_ms)

      {:allow, count} ->
        if within_site_ceiling?(conn, class, count) do
          record(conn, class, :allowed)
        else
          conn |> record(class, :throttled) |> deny(RateLimit.window_remaining_ms(:delivery))
        end
    end
  end

  # A refusal of a verified API key is noted for the platform's alert
  # (`KilnCMS.Security.ApiKeyTrip`, which ignores the buckets it does not
  # cover and costs no database read for a key it has not verified).
  def call(conn, bucket) do
    case RateLimit.check(bucket, remote_ip(conn)) do
      :allow ->
        conn

      {:deny, retry_after_ms} ->
        ApiKeyTrip.note(conn, bucket)
        deny(conn, retry_after_ms)
    end
  end

  @doc """
  Answers `conn` with this plug's 429 and halts it. Public for a plug that
  charges a bucket again after this one has (`KilnCMSWeb.Plugs.GraphqlBatchLimit`),
  so its refusal is the same response.
  """
  @spec deny(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def deny(conn, retry_after_ms) do
    # Rounded up: `div/2` told a client refused in the last second of
    # a fixed window to retry in 0 seconds — back into the closed window. The
    # docs publisher, which honours the header, spent all its retries in a few
    # milliseconds and failed the v0.11.0 sync a moment before the reopen.
    retry_after_s = AccountThrottle.retry_after_seconds(retry_after_ms)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> render_denial(retry_after_s)
    |> halt()
  end

  # A browser navigation (Accept: text/html) gets a readable page; everything
  # else (API clients, fetch/XHR) keeps the JSON error shape.
  #
  # That JSON goes through `ApiError` like every other headless refusal (#744).
  # This plug fronts the `:api`, `:auth`, `:form` and `:preview` pipelines — so
  # a 429 here is the one error *every* headless surface shares, and it used to
  # be the one that answered `detail` alone. A client branching on
  # `errors[].code` got `undefined` on the single refusal that has a defined
  # recovery, next to a `retry-after` telling it exactly how to take it. Worse
  # on `/api/auth/sign_in/verify`, which could answer 429 in two shapes for the
  # same URL depending on whether the per-IP bucket or the per-account budget
  # refused it.
  #
  # The XSS.HTML warning is a false positive: `deny_html/1` interpolates only
  # gettext strings and a server-computed integer — no request data.
  # sobelow_skip ["XSS.HTML"]
  defp render_denial(conn, retry_after_s) do
    if html_request?(conn) do
      conn |> put_status(429) |> Phoenix.Controller.html(deny_html(retry_after_s))
    else
      ApiError.send(conn, :too_many_requests, "too_many_requests", "Too many requests.")
    end
  end

  defp html_request?(conn) do
    conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  # Deliberately dependency-light (no layout/components): this renders while
  # the request is being refused, so it must not be able to fail itself.
  defp deny_html(retry_after_s) do
    title = gettext("Too many requests")

    message =
      gettext("You've made too many requests in a short time. Try again in %{seconds} seconds.",
        seconds: retry_after_s
      )

    back = gettext("Back to the homepage")

    """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{title}</title>
        <style>
          body { font-family: system-ui, sans-serif; display: grid; place-items: center; min-height: 100vh; margin: 0; }
          main { text-align: center; padding: 2rem; }
          a { color: inherit; }
        </style>
      </head>
      <body>
        <main>
          <h1>#{title}</h1>
          <p>#{message}</p>
          <p><a href="/">#{back}</a></p>
        </main>
      </body>
    </html>
    """
  end

  # The one place a request becomes a client class: `{charged_class,
  # operator_ceiling}`. Only a search-engine claim is checked against DNS
  # (#2254); see the moduledoc for what each answer is charged as.
  defp client_class(conn) do
    case get_req_header(conn, "user-agent") do
      [user_agent | _rest] ->
        case BotClass.classify(user_agent) do
          :search_engine -> search_engine_class(conn, BotClass.search_engine(user_agent))
          class -> {class, BotBudgets.operator_limit(class)}
        end

      [] ->
        {:empty, BotBudgets.operator_limit(:empty)}
    end
  end

  defp search_engine_class(conn, engine) do
    forwarded_untrusted? = ClientIp.untrusted_forwarding?(conn.req_headers)

    case CrawlerVerification.check(engine, conn.remote_ip,
           forwarded_untrusted?: forwarded_untrusted?
         ) do
      status when status in [:verified, :disabled] ->
        {:search_engine, BotBudgets.operator_limit(:search_engine)}

      # Proven false: a client lying about what it is gets the ceiling of one
      # that says nothing.
      {:unverified, :failed} ->
        unverified_crawler(engine, :failed)
        {:empty, BotBudgets.operator_limit(:empty)}

      # Not proven either way: the search-engine class, but never above what
      # a browser gets.
      {:unverified, reason} ->
        unverified_crawler(engine, reason)
        {:search_engine, BotBudgets.unverified_search_limit()}
    end
  end

  defp unverified_crawler(engine, reason) do
    :telemetry.execute([:kiln_cms, :delivery, :unverified_crawler], %{count: 1}, %{
      engine: engine,
      reason: reason
    })
  end

  # A browser's ceiling IS the `:delivery` limit, which the charge already
  # applied; a site may only lower the other classes.
  defp within_site_ceiling?(_conn, :browser, _count), do: true

  defp within_site_ceiling?(conn, class, count),
    do: count <= BotBudgets.limit(conn.assigns[:current_org], class)

  defp record(conn, class, result) do
    :telemetry.execute([:kiln_cms, :delivery, :client_class], %{count: 1}, %{
      class: class,
      result: result
    })

    conn
  end

  # Through `RateLimit.client_key/1` rather than formatted here, so this and the
  # socket path (`KilnCMSWeb.SignInLive`) cannot spell one client two ways and
  # split the `:auth` bucket they are meant to share (#715).
  defp remote_ip(conn), do: RateLimit.client_key(conn.remote_ip)
end
