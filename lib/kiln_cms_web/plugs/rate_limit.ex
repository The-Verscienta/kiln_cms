defmodule KilnCMSWeb.Plugs.RateLimit do
  @moduledoc """
  Returns HTTP 429 when a client exceeds per-IP rate limits.

  API pipelines get the JSON error shape; browser pipelines (sign-in, public
  delivery pages) get a small HTML page instead of raw JSON (audit U-M7).
  """
  import Plug.Conn

  use Gettext, backend: KilnCMSWeb.Gettext

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
        |> put_status(429)
        |> render_denial(retry_after_s)
        |> halt()
    end
  end

  # A browser navigation (Accept: text/html) gets a readable page; everything
  # else (API clients, fetch/XHR) keeps the JSON error shape.
  #
  # The XSS.HTML warning is a false positive: `deny_html/1` interpolates only
  # gettext strings and a server-computed integer — no request data.
  # sobelow_skip ["XSS.HTML"]
  defp render_denial(conn, retry_after_s) do
    if html_request?(conn) do
      Phoenix.Controller.html(conn, deny_html(retry_after_s))
    else
      Phoenix.Controller.json(conn, %{errors: [%{detail: "Too many requests"}]})
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

  defp remote_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
