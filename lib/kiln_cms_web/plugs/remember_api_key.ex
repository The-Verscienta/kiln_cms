defmodule KilnCMSWeb.Plugs.RememberApiKey do
  @moduledoc """
  Remembers the API key `AshAuthentication.Strategy.ApiKey.Plug` just
  authenticated on this node (`KilnCMS.Security.ApiKeyTrip.remember/2`), so a
  later rate-limit refusal of the same key can alert (#2245). For the `/mcp`
  pipeline, which uses that plug directly; `KilnCMSWeb.Plugs.ApiKeyAuth` does
  the same itself.

  The token is read the way that plug reads it: the first `authorization`
  value, with the exact `Bearer ` prefix, trimmed. Anything else is not what
  it verified, and is ignored. Runs after it, so a refused key never gets here.
  """
  @behaviour Plug

  @prefix "Bearer "

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with [@prefix <> rest | _] <- Plug.Conn.get_req_header(conn, "authorization") do
      KilnCMS.Security.ApiKeyTrip.remember(String.trim(rest), Ash.PlugHelpers.get_actor(conn))
    end

    conn
  end
end
