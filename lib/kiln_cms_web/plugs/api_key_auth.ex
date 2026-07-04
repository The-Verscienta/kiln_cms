defmodule KilnCMSWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates headless API requests presenting an **API key** as
  `Authorization: Bearer kiln_…`, setting the owning user as the Ash actor.

  Runs after `:load_from_bearer`/`:set_actor` so JWT and API-key auth share one
  `Authorization: Bearer` scheme, disambiguated by the key's `kiln_` prefix:

    * `Bearer kiln_…` → delegated to `AshAuthentication.Strategy.ApiKey.Plug`,
      which validates the key and assigns `current_user` / the actor. An invalid,
      expired or revoked key is rejected with `401`.
    * anything else (a JWT, or no header) → passed through untouched, so
      `:load_from_bearer` retains sole responsibility for JWT bearer tokens.

  Keeping the two apart matters: the API-key plug treats a present-but-unrecognised
  `Bearer` value as an *invalid key* (401), so it must never see a JWT.
  """
  @behaviour Plug

  @prefix "Bearer " <> KilnCMS.Accounts.ApiKey.prefix() <> "_"

  # `required?: false` so requests *without* a key aren't rejected here (they may
  # be anonymous or JWT-authenticated); we only invoke this plug once we've
  # confirmed the header carries one of our keys, so a bad key still 401s.
  @impl true
  def init(_opts) do
    AshAuthentication.Strategy.ApiKey.Plug.init(
      resource: KilnCMS.Accounts.User,
      required?: false
    )
  end

  @impl true
  def call(conn, opts) do
    if api_key_request?(conn) do
      AshAuthentication.Strategy.ApiKey.Plug.call(conn, opts)
    else
      conn
    end
  end

  defp api_key_request?(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [value | _] -> String.starts_with?(value, @prefix)
      _ -> false
    end
  end
end
