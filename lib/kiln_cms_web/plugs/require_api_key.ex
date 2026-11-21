defmodule KilnCMSWeb.Plugs.RequireApiKey do
  @moduledoc """
  The `/mcp` pipeline's authentication: an API key is required, and a missing
  or invalid one is AshAuthentication's own `401`.

  The key is found the way `KilnCMSWeb.Plugs.ApiKeyAuth` finds it on `/api`
  (`KilnCMSWeb.Plugs.ApiKeyAuth.presented_key/1`): under a `Bearer` scheme in
  any case (RFC 7235, #2632), in any `authorization` value, the first key
  deciding. Without one the request goes to
  `AshAuthentication.Strategy.ApiKey.Plug` as it came, which refuses it.
  """
  @behaviour Plug

  alias AshAuthentication.Strategy.ApiKey
  alias KilnCMSWeb.Plugs.ApiKeyAuth

  @impl true
  def init(_opts), do: ApiKey.Plug.init(resource: KilnCMS.Accounts.User, required?: true)

  @impl true
  def call(conn, key_opts) do
    case ApiKeyAuth.presented_key(conn) do
      {:ok, key} -> ApiKeyAuth.verify_key(conn, key, key_opts)
      :error -> ApiKey.Plug.call(conn, key_opts)
    end
  end
end
