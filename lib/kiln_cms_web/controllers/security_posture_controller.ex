defmodule KilnCMSWeb.SecurityPostureController do
  @moduledoc """
  `GET /api/security/posture` (#2521): the site's security posture for
  monitoring, the same checks the Security posture page runs, as JSON
  (`KilnCMSWeb.SecurityPostureJSON` has the shape and its contract).

  ## Who may read it

  An administrator of the request's site, with a bearer JWT or an API key
  they own; a platform administrator also gets the deployment's checks. The
  `KilnCMS.Security.PostureReport` `:snapshot` action's policy is the only
  gate (the page's own rule, `KilnCMS.Security.Posture.scopes_for/1`, decides
  the checks), so this controller checks no tier itself.

  ## What a request meets, in order

    1. The site's admin allowlist (`KilnCMSWeb.Plugs.AdminAllowlist`, JSON):
       `403` `network_not_allowed` off the list, `503`
       `temporarily_unavailable` (`retry-after: 30`) when the list cannot be
       read. First, so an off-list caller learns nothing about its credential.
    2. The `:api` rate limit, per address: `429` with `retry-after`.
    3. The credential: a bearer that does not verify is `401` `invalid_token`
       (`KilnCMSWeb.Plugs.ApiKeyAuth`); none at all is `401`
       `unauthenticated` here, with `www-authenticate: Bearer`.
    4. The policy: anyone but an administrator of this site, or a
       `:draft_write` key whoever owns it, is `403` `forbidden`.
    5. The site's report slots (`KilnCMS.Security.Posture.with_slot/2`): `503`
       `temporarily_unavailable` with `retry-after: 5` while they are full.

  Otherwise `200`. The checks run at most once per site and scope set every
  30 seconds on each node (`KilnCMS.Security.Posture.snapshot/2`), so
  `generated_at` may be up to that old. Every answer, refusals included, is
  `cache-control: private, no-store` (the router's `:no_store` pipeline; the
  allowlist's refusals set `no-store` themselves).
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Security.Errors.PostureBusy
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.SecurityPostureJSON

  @busy_retry_after "5"

  @doc "The site's posture, or the refusal the request has earned."
  def show(conn, _params) do
    case Ash.PlugHelpers.get_actor(conn) do
      nil ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> ApiError.send(
          :unauthorized,
          "unauthenticated",
          "The security posture needs a site administrator's bearer token or API key."
        )

      actor ->
        org = KilnCMSWeb.Tenant.current_org(conn)

        %{}
        |> KilnCMS.Security.posture_snapshot(actor: actor, tenant: org)
        |> respond(conn)
    end
  end

  defp respond({:ok, report}, conn), do: json(conn, SecurityPostureJSON.show(%{report: report}))

  defp respond({:error, %Ash.Error.Forbidden{}}, conn) do
    ApiError.send(
      conn,
      :forbidden,
      "forbidden",
      "Only an administrator of this site can read its security posture."
    )
  end

  defp respond({:error, error}, conn) do
    if PostureBusy.in?(error) do
      conn
      |> put_resp_header("retry-after", @busy_retry_after)
      |> ApiError.send(
        :service_unavailable,
        "temporarily_unavailable",
        "This site's security checks are already running. Try again in a few seconds."
      )
    else
      # The error's class only: never the report, nor anything a check said.
      Logger.error(
        "Security posture snapshot failed: #{inspect(Ash.Error.to_error_class(error).__struct__)}"
      )

      ApiError.send(
        conn,
        :internal_server_error,
        "internal_server_error",
        "The security posture could not be produced."
      )
    end
  end
end
