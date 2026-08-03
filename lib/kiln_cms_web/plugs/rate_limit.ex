defmodule KilnCMSWeb.Plugs.RateLimit do
  @moduledoc """
  Returns HTTP 429 when a client exceeds per-IP rate limits.

  API pipelines get the JSON error shape; browser pipelines (sign-in, public
  delivery pages) get a small HTML page instead of raw JSON (audit U-M7).
  """
  import Plug.Conn

  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.RateLimit

  def init(bucket) when is_atom(bucket), do: bucket

  def call(conn, bucket) do
    case RateLimit.check(bucket, remote_ip(conn)) do
      :allow ->
        conn

      {:deny, retry_after_ms} ->
        retry_after_s = div(retry_after_ms, 1000)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> render_denial(retry_after_s)
        |> halt()
    end
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

  # Through `RateLimit.client_key/1` rather than formatted here, so this and the
  # socket path (`KilnCMSWeb.SignInLive`) cannot spell one client two ways and
  # split the `:auth` bucket they are meant to share (#715).
  defp remote_ip(conn), do: RateLimit.client_key(conn.remote_ip)
end
