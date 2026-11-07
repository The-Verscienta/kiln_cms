defmodule KilnCMSWeb.Plugs.PluginRawBody.DefaultType do
  @moduledoc """
  Gives a body-carrying plugin-route request that sent no `content-type` the
  type `application/octet-stream`. `Plug.Parsers` skips such a request
  entirely, which would leave the 8 MB unauthenticated read open by omission;
  with a type, `KilnCMSWeb.Plugs.PluginRawBody` claims it under the 1 MB cap.
  """
  @behaviour Plug

  alias KilnCMSWeb.Plugs.RawBodyReader

  @methods ~w(POST PUT PATCH DELETE)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @methods do
    if Plug.Conn.get_req_header(conn, "content-type") == [] and
         RawBodyReader.plugin_path?(conn) do
      Plug.Conn.put_req_header(conn, "content-type", "application/octet-stream")
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
