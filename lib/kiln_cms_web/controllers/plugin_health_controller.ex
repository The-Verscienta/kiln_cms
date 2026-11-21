defmodule KilnCMSWeb.PluginHealthController do
  @moduledoc """
  `GET /api/security/plugin-health` (#2571): the installed plugins' health for
  monitoring, from this node's cache, as JSON (`KilnCMSWeb.PluginHealthJSON`
  has the shape and its contract).

  ## Who may read it

  A platform administrator, with a bearer JWT or an API key they own. The
  `KilnCMS.Security.PluginHealthReport` `:cached` action's policy is the only
  gate, so this controller checks no tier itself. A site administrator is
  refused: the report describes the whole deployment, and is the same on
  every site's host.

  ## What a request meets, in order

    1. The host site's admin allowlist (`KilnCMSWeb.Plugs.AdminAllowlist`,
       JSON): `403` `network_not_allowed` off the list, `503`
       `temporarily_unavailable` (`retry-after: 30`) when the list cannot be
       read. First, so an off-list caller learns nothing about its credential.
    2. The `:api` rate limit, per address: `429` with `retry-after`.
    3. The credential: a bearer that does not verify is `401` `invalid_token`
       (`KilnCMSWeb.Plugs.ApiKeyAuth`); none at all is `401`
       `unauthenticated` here, with `www-authenticate: Bearer`.
    4. The policy: anyone but a platform administrator, or a `:draft_write`
       key whoever owns it, is `403` `forbidden`.

  Otherwise `200`, from the cache only: this never asks hex.pm or the notices
  feed anything, and never starts a check in the background. A node with no
  fresh check answers `state: "not_checked"`. Every answer, refusals
  included, is `cache-control: private, no-store` (the router's `:no_store`
  pipeline; the allowlist's refusals set `no-store` themselves).
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.PluginHealthJSON

  @doc "The installed plugins' cached health, or the refusal the request has earned."
  def show(conn, _params) do
    case Ash.PlugHelpers.get_actor(conn) do
      nil ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> ApiError.send(
          :unauthorized,
          "unauthenticated",
          "Plugin health needs a platform administrator's bearer token or API key."
        )

      actor ->
        %{}
        |> KilnCMS.Security.cached_plugin_health(actor: actor)
        |> respond(conn)
    end
  end

  defp respond({:ok, report}, conn), do: json(conn, PluginHealthJSON.show(%{report: report}))

  defp respond({:error, %Ash.Error.Forbidden{}}, conn) do
    ApiError.send(
      conn,
      :forbidden,
      "forbidden",
      "Only a platform administrator can read plugin health."
    )
  end

  defp respond({:error, error}, conn) do
    # The error's class only: never the report.
    Logger.error(
      "Plugin health read failed: #{inspect(Ash.Error.to_error_class(error).__struct__)}"
    )

    ApiError.send(
      conn,
      :internal_server_error,
      "internal_server_error",
      "Plugin health could not be read."
    )
  end
end
