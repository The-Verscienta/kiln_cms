defmodule KilnCMSWeb.FeedStream.JoinBudget do
  @moduledoc """
  Charges a `GET /api/feed` connect to the `:feed_join` bucket
  (`KilnCMSWeb.RateLimit`), keyed on the client address, first in the `:feed`
  pipeline — ahead of the `:api` bucket and the credential plugs, like the
  `/ws/*` joins (`KilnCMSWeb.SocketJoinBudget`).

  A refused connect is not the `429` `KilnCMSWeb.Plugs.RateLimit` answers: a
  native `EventSource` stops for good on any non-200 response, and a client
  that reconnected too eagerly once would never come back. It is the stream's
  own refusal instead (`KilnCMSWeb.FeedStream.busy/3`, reason `rate_limited`):
  a `200`, a `retry:` of the bucket's `retry_after` plus up to as much again
  (so a refused crowd does not return together), and `event: busy`.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMSWeb.FeedStream
  alias KilnCMSWeb.RateLimit

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RateLimit.check(:feed_join, RateLimit.client_key(conn.remote_ip)) do
      :allow ->
        conn

      {:deny, retry_after_ms} ->
        retry_after_ms = max(retry_after_ms, 1_000)

        conn
        |> FeedStream.busy("rate_limited", retry_after_ms + :rand.uniform(retry_after_ms))
        |> halt()
    end
  end
end
