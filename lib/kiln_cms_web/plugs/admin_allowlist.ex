defmodule KilnCMSWeb.Plugs.AdminAllowlist do
  @moduledoc """
  The HTTP gate of a site's admin allowlist (#2248): refuses a request to the
  console, `/setup`, a sign-in route or the security posture
  (`GET /api/security/posture`, #2521) from an address the site has not
  listed. The socket half is `KilnCMSWeb.AdminAllowlist`; the list is
  `KilnCMS.Security.AdminAllowlist`.

  It is a router pipeline, `:admin_allowlist` (HTML) and `:admin_allowlist_api`
  (JSON: `POST /api/auth/sign_in*` and `GET /api/security/posture`), not an
  endpoint plug with path prefixes: which routes are gated is a fact on each
  route (`pipe_through`), pinned by
  `test/kiln_cms_web/admin_allowlist_routes_test.exs`, and public delivery
  never runs it. It comes **first** in each gated `pipe_through`, ahead of the
  session, so a refused request reads no session and is never signed in by a
  remember-me cookie (whose `Set-Cookie` it would otherwise carry).

  The address is `conn.remote_ip`, already resolved by
  `KilnCMSWeb.Plugs.ClientIp`; the endpoint's `KilnCMSWeb.Plugs.IpBlock` has
  already run, so a block always wins over the allowlist.

  ## What a refused request gets

    * HTML: a `403` page saying the site only allows sign-in and its console
      from approved networks, showing the visitor their own address (most
      people refused here are the site's own admins on the wrong network, or
      behind a proxy Kiln does not trust), with a strict CSP of its own,
      `cache-control: no-store` and `x-robots-tag: noindex`.
    * JSON: `403` `network_not_allowed` in the API's error envelope, with
      `cache-control: no-store` and `x-robots-tag: noindex` too. The detail is
      the HTML page's neutral heading, since it answers more than sign-in.
    * When the list cannot be read: `503` with `retry-after: 30`
      (`temporarily_unavailable`), and no address.

  Every refusal emits `kiln_cms.admin_allowlist.refused.count`; one from
  outside the list also records `admin_access_refused`, sampled.

  A request it lets through carries the admitted address on to the page's
  LiveView session (`KilnCMSWeb.AdminAllowlist.stamp_conn/2`), which is how the
  page's socket knows what the HTTP gate saw.
  """
  @behaviour Plug

  use Gettext, backend: KilnCMSWeb.Gettext

  import Plug.Conn

  alias KilnCMS.Security.AdminAllowlist
  alias KilnCMSWeb.AdminAllowlist, as: Gate

  @csp "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; " <>
         "form-action 'none'; frame-ancestors 'none'"

  @impl true
  def init(format) when format in [:html, :json], do: format

  @impl true
  def call(%Plug.Conn{assigns: %{current_org: %{id: org_id} = org}} = conn, format)
      when is_binary(org_id) do
    case AdminAllowlist.check(org_id, conn.remote_ip) do
      :allowed -> Gate.stamp_conn(conn, org_id)
      reason -> refuse(conn, format, reason, org)
    end
  end

  # `SetTenant` assigns a site to every request it lets through; without one
  # there is no list to apply.
  def call(conn, _format), do: conn

  defp refuse(conn, format, reason, org) do
    surface = if format == :json, do: :api, else: :http
    Gate.count_refusal(surface, reason)

    if reason == :not_listed do
      Gate.record_refusal(
        org.id,
        conn.remote_ip,
        KilnCMS.Security.Recorder.request_context(conn),
        surface
      )
    end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex")
    |> respond(format, reason, org)
    |> halt()
  end

  defp respond(conn, :json, :not_listed, _org) do
    KilnCMSWeb.ApiError.send(
      conn,
      :forbidden,
      "network_not_allowed",
      gettext("Not available from this network")
    )
  end

  defp respond(conn, :json, :unavailable, _org) do
    conn
    |> put_resp_header("retry-after", "30")
    |> KilnCMSWeb.ApiError.send(
      :service_unavailable,
      "temporarily_unavailable",
      gettext("Temporarily unavailable")
    )
  end

  defp respond(conn, :html, reason, org) do
    status = if reason == :unavailable, do: 503, else: 403

    conn = if status == 503, do: put_resp_header(conn, "retry-after", "30"), else: conn

    # Rendered through the view like any page (HEEx escapes every value),
    # without the app's layouts: the gate runs ahead of the session and the
    # CSP nonce they need.
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_status(status)
    |> Phoenix.Controller.put_format("html")
    |> Phoenix.Controller.put_root_layout(false)
    |> Phoenix.Controller.put_layout(false)
    |> Phoenix.Controller.put_view(html: KilnCMSWeb.AdminAllowlistHTML)
    |> Phoenix.Controller.render(:refused,
      reason: reason,
      ip: ip_text(conn.remote_ip),
      site_url: KilnCMSWeb.Plugs.ConsoleHost.site_url(org),
      locale: Gettext.get_locale(KilnCMSWeb.Gettext)
    )
  end

  defp ip_text(ip), do: ip |> :inet.ntoa() |> to_string()
end
