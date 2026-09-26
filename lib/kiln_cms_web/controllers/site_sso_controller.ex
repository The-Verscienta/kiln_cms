defmodule KilnCMSWeb.SiteSsoController do
  @moduledoc """
  The two routes of a site's own single sign-on (#1561):

    * `GET /auth/site-sso` — start: redirect to the site's provider, with the
      state, nonce and PKCE verifier parked in the (encrypted) session, bound
      to this site's org and to a ten-minute window;
    * `GET /auth/site-sso/callback` — finish: the parked parameters are taken
      (single use), the org must be the one that started the flow, and
      `KilnCMS.Accounts.SiteSso.sign_in/4` verifies the ID token and applies
      `KilnCMS.Accounts.SiteSso.Admission`. Success completes through
      `KilnCMSWeb.AuthController.success/4`, so a second factor still applies.

  The callback URL is the site's own base URL (`KilnCMSWeb.Tenant.base_url/1`)
  plus `/auth/site-sso/callback` — what `/editor/site-sso` tells the admin to
  register at the provider. It is derived from the org, never from the request's
  `Host`, so a request arriving under another name cannot choose where the
  provider sends the code.

  Behind `:browser_auth`, so under the same per-IP `:auth` rate limit as every
  other credential endpoint. Failures say little to the browser and log the
  reason: the provider's error text is the provider's, and it is shown to
  whoever started the flow.
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Accounts.SiteSso
  alias KilnCMSWeb.Tenant

  @session_key :site_sso_pending
  @max_age_seconds 600

  # The only callback parameters the protocol reads. Everything else a provider
  # (or a forged link) appends is dropped before it reaches Assent.
  @callback_params ~w(code state error error_description error_uri)

  @doc "Where the site's provider must send the browser back to."
  @spec callback_url(KilnCMS.Accounts.Organization.t()) :: String.t()
  def callback_url(org),
    do: String.trim_trailing(Tenant.base_url(org), "/") <> ~p"/auth/site-sso/callback"

  def request(conn, _params) do
    org = Tenant.current_org(conn)

    case SiteSso.authorize(org.id, callback_url(org)) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(@session_key, %{
          org_id: org.id,
          session_params: session_params,
          started_at: System.system_time(:second)
        })
        |> redirect(external: url)

      {:error, reason} ->
        refuse(conn, org, reason)
    end
  end

  def callback(conn, params) do
    org = Tenant.current_org(conn)
    pending = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    with {:ok, session_params} <- pending_for(pending, org.id),
         {:ok, user} <-
           SiteSso.sign_in(
             org.id,
             callback_url(org),
             Map.take(params, @callback_params),
             session_params
           ) do
      KilnCMSWeb.AuthController.success(
        conn,
        {:site_sso, :callback},
        user,
        user.__metadata__[:token]
      )
    else
      {:error, reason} -> refuse(conn, org, reason)
    end
  end

  # The parked parameters must exist, belong to THIS org, and be fresh. A flow
  # started on one site and finished on another is refused outright, whatever
  # the provider says: the state would otherwise be the only thing binding the
  # code to the site whose rules admit it.
  defp pending_for(
         %{org_id: org_id, session_params: %{} = session_params, started_at: started_at},
         org_id
       )
       when is_integer(started_at) do
    if System.system_time(:second) - started_at <= @max_age_seconds,
      do: {:ok, session_params},
      else: {:error, :flow_expired}
  end

  defp pending_for(nil, _org_id), do: {:error, :no_flow}
  defp pending_for(_other, _org_id), do: {:error, :flow_mismatch}

  defp refuse(conn, org, reason) do
    Logger.warning("Site single sign-on refused on #{org.id}: #{describe(reason)}")

    conn
    |> put_flash(:error, message(reason))
    |> redirect(to: ~p"/sign-in")
  end

  defp describe(reason) when reason in [:no_flow, :flow_mismatch, :flow_expired],
    do: "the sign-in was not started here, or took too long (#{reason})"

  defp describe(reason), do: SiteSso.describe_error(reason)

  defp message(:domain_not_verified),
    do:
      gettext(
        "Your email address isn't in a domain this site's single sign-on may vouch for. Sign in another way."
      )

  defp message(reason)
       when reason in [:access_elsewhere, :unconfirmed_account, :registration_disabled],
       do:
         gettext(
           "This account can't use this site's single sign-on. Sign in with your password or an email link instead."
         )

  defp message(reason) when reason in [:no_flow, :flow_mismatch, :flow_expired],
    do: gettext("That sign-in link has expired. Start again.")

  defp message(reason)
       when reason in [:not_configured, :unavailable, :credentials_unreadable],
       do: gettext("Single sign-on isn't available on this site right now. Sign in another way.")

  defp message(_reason),
    do: gettext("Single sign-on failed. Try again, or sign in another way.")
end
