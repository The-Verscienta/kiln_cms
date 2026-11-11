defmodule KilnCMSWeb.Plugs.OnBehalfOf do
  @moduledoc """
  Carry a write's `X-Kiln-On-Behalf-Of` header into the Ash action, where
  `KilnCMS.CMS.Changes.StampDraftWriteProvenance` records it on a draft created
  with a `:draft_write` API key (#2273).

  The value is an opaque label the calling service chooses (typically its own
  user id). It is sanitized here and again where it is stored, kept under the
  `:kiln_on_behalf_of` context key (merged into whatever context is already on
  the conn), and **never used for authorization**. Only `POST` carries it: it
  names who a *new* draft is for, and an update leaves the stored value alone.
  Every other actor and every other action ignore the key.
  """
  @behaviour Plug

  alias KilnCMS.CMS.Changes.StampDraftWriteProvenance

  @header "x-kiln-on-behalf-of"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    with [value | _] <- Plug.Conn.get_req_header(conn, @header),
         text when is_binary(text) <- StampDraftWriteProvenance.sanitize(value) do
      context = Ash.PlugHelpers.get_context(conn) || %{}
      Ash.PlugHelpers.set_context(conn, Map.put(context, :kiln_on_behalf_of, text))
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn
end
