defmodule KilnCMSWeb.Plugs.MultipartParser do
  @moduledoc """
  The endpoint's multipart parser: `Plug.Parsers.MULTIPART`, except that it
  leaves one route's body unread — `POST /api/media`, the media upload API.

  The endpoint parses every body before routing, under one 8 MB cap. An upload
  endpoint needs a far larger one (the media library accepts 500 MB video), and
  raising the endpoint-wide cap would let every anonymous request to every
  route spool that much to disk. Raising it for one path *in the endpoint*
  would still spool it before authentication: the parser runs ahead of the
  router, so an anonymous client could fill the temp directory with bodies the
  API was always going to refuse.

  So for that one route this parser answers `{:next, conn}` — "not mine" — and
  `Plug.Parsers`' `pass: ["*/*"]` leaves the body unread. The route's
  controller (`KilnCMSWeb.MediaUploadController`) authenticates, rate-limits
  and asks the create policy first, and only then parses the body itself with
  the upload limit. Every other multipart request is parsed here exactly as
  before. This is the extension point `Plug.Parsers.MULTIPART` documents for
  per-request configuration (a parser that wraps it).
  """
  @behaviour Plug.Parsers

  @multipart Plug.Parsers.MULTIPART

  @impl true
  def init(opts), do: @multipart.init(opts)

  @impl true
  def parse(
        %Plug.Conn{method: "POST", path_info: ["api", "media"]} = conn,
        "multipart",
        _sub,
        _headers,
        _opts
      ),
      do: {:next, conn}

  def parse(conn, type, subtype, headers, opts),
    do: @multipart.parse(conn, type, subtype, headers, opts)
end
