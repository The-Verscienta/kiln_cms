defmodule KilnCMSWeb.RequestLog do
  @moduledoc """
  The endpoint's request-line level, with credential paths redacted (#2449).

  `Phoenix.Logger` writes `GET <request_path>` when a request starts and
  `Sent <status> in <duration>` when it ends, both at the level the
  `Plug.Telemetry` `log:` option returns. This is that option. For a path that
  carries a secret (`KilnCMSWeb.RequestRedaction`) it writes the start line
  itself, with the secret segments as `[FILTERED]`, and returns `false` so
  Phoenix writes none. Every other request gets `:info`, Phoenix's default, and
  logs exactly as before.

  The same callback is asked again for the stop line. That line holds no path,
  so it is left to Phoenix: the start event is the one call made while the conn
  is still `:unset` (the stop event fires from `before_send`, after a response
  has been set), which is how one callback tells the two apart.

  The line is written from the request process, inside Phoenix's own telemetry
  handler, so it carries the same `request_id` metadata Phoenix's would.
  """

  require Logger

  alias KilnCMSWeb.RequestRedaction

  @doc "The `Plug.Telemetry` `log:` callback: `:info`, or `false` after logging a redacted start line."
  @spec level(Plug.Conn.t()) :: Logger.level() | false
  def level(%Plug.Conn{state: :unset} = conn) do
    case RequestRedaction.redact(conn) do
      :unchanged ->
        :info

      {:redacted, path} ->
        Logger.info(fn -> [conn.method, ?\s, path] end)
        false
    end
  end

  def level(%Plug.Conn{}), do: :info
end
