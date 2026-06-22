defmodule KilnCMSWeb.Plugs.RateLimit do
  @moduledoc """
  Returns HTTP 429 when a client exceeds per-IP rate limits.
  """
  import Plug.Conn

  alias KilnCMSWeb.RateLimit

  def init(bucket) when is_atom(bucket), do: bucket

  def call(conn, bucket) do
    case RateLimit.check(bucket, remote_ip(conn)) do
      :allow ->
        conn

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000)))
        |> put_status(429)
        |> Phoenix.Controller.json(%{errors: [%{detail: "Too many requests"}]})
        |> halt()
    end
  end

  defp remote_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
