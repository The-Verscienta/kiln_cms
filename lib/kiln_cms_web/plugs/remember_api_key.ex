defmodule KilnCMSWeb.Plugs.RememberApiKey do
  @moduledoc """
  Remembers the API key `AshAuthentication.Strategy.ApiKey.Plug` just
  authenticated on this node (`KilnCMS.Security.ApiKeyTrip.remember/2`), so a
  later rate-limit refusal of the same key can alert (#2245). For the `/mcp`
  pipeline, which authenticates with `KilnCMSWeb.Plugs.RequireApiKey`;
  `KilnCMSWeb.Plugs.ApiKeyAuth` does the same itself.

  The key is read the way that plug finds it
  (`KilnCMSWeb.Plugs.ApiKeyAuth.presented_key/1`): the first `kiln_…` token
  under a `Bearer` scheme in any case, across every `authorization` value.
  Anything else is not what it verified, and is ignored. Runs after it, so a
  refused key never gets here.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, key} <- KilnCMSWeb.Plugs.ApiKeyAuth.presented_key(conn) do
      KilnCMS.Security.ApiKeyTrip.remember(key, Ash.PlugHelpers.get_actor(conn))
    end

    conn
  end
end
