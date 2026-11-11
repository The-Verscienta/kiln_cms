defmodule KilnCMSWeb.Plugs.PluginRawBody do
  @moduledoc """
  Gives a plugin plug route (`c:Kiln.Plugin.plug_routes/0`, #2272) the exact
  request bytes whatever the content type — a parser here, and `PluginRawBody.DefaultType` ahead of it.

  `Plug.Parsers` reads a body only for the types it has a parser for
  (`pass: ["*/*"]` leaves the rest unread), so on its own a `text/plain`,
  `application/octet-stream` or `application/xml` webhook would reach the
  plugin unread, and a plugin reading it would get Plug's default 8 MB on a route
  nobody has authenticated yet. Here:

    * as a **parser** (last in the endpoint's list) it claims a body none of the
      earlier parsers took, on a plugin path only, and reads it through
      `KilnCMSWeb.Plugs.RawBodyReader` — the same 1 MB cap, the same
      `conn.private[:raw_body]`. Over the cap it answers `:too_large`, which
      `Plug.Parsers` raises as a `413`. Params stay empty: `raw_body` is the
      payload.
    * `DefaultType`, a **plug** ahead of `Plug.Parsers`: it gives a body-carrying plugin
      request that sent no `content-type` the type `application/octet-stream`,
      because `Plug.Parsers` skips such a request entirely and would otherwise
      leave the same 8 MB hole open by omission.

  Not covered, by design: `multipart/*` (parsed to disk by `Plug.Parsers`, no
  raw bytes) and every path that is not a plugin route.
  """
  @behaviour Plug.Parsers
  alias KilnCMSWeb.Plugs.RawBodyReader

  # `Plug.Parsers` passes the endpoint's root options (`:length`, `:body_reader`…)
  # to the parser's `init/1`; the reader applies the plugin cap itself.
  @impl Plug.Parsers
  def init(opts), do: opts

  @impl Plug.Parsers
  def parse(conn, "multipart", _subtype, _params, _opts), do: {:next, conn}

  def parse(conn, _type, _subtype, _params, opts) do
    if RawBodyReader.plugin_path?(conn) do
      case RawBodyReader.read_body(conn, Keyword.delete(opts, :body_reader)) do
        {:ok, _body, conn} ->
          {:ok, %{}, conn}

        {:more, _partial, conn} ->
          {:error, :too_large, conn}

        {:error, :timeout} ->
          raise Plug.TimeoutError

        {:error, reason} ->
          raise Plug.BadRequestError, "could not read the body: #{inspect(reason)}"
      end
    else
      {:next, conn}
    end
  end
end
