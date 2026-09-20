defmodule KilnCMSWeb.Plugs.IfMatch do
  @moduledoc """
  Carry a JSON:API write's `If-Match` into the Ash action, where
  `KilnCMS.CMS.Changes.CheckExpectedVersion` compares it with the row it is
  about to change — a 412 on mismatch.

  Only on `PATCH` and `DELETE`, the methods of the routes that act on one
  existing record. A `POST` creates, so there is nothing for it to match; a
  `GET` with `If-Match` is not a pattern the API supports. The header is
  parsed by `KilnCMSWeb.ContentETag.parse_if_match/1` and stored under the
  `:kiln_if_match` context key, merged into whatever context is already on
  the conn.

  Resources whose write actions do not carry `CheckExpectedVersion` ignore the
  key, so the header is a no-op there rather than a promise the server does
  not keep — `docs/json-api.md` names the routes that honour it.
  """
  @behaviour Plug

  alias KilnCMSWeb.ContentETag

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["PATCH", "DELETE"] do
    case Plug.Conn.get_req_header(conn, "if-match") do
      [] ->
        conn

      values ->
        tags = values |> Enum.join(",") |> ContentETag.parse_if_match()
        context = Ash.PlugHelpers.get_context(conn) || %{}
        Ash.PlugHelpers.set_context(conn, Map.put(context, :kiln_if_match, tags))
    end
  end

  def call(conn, _opts), do: conn
end
