defmodule KilnCMSWeb.SecurityTxtController do
  @moduledoc """
  `/.well-known/security.txt` (RFC 9116, #1873) for the request's site, from
  its `KilnCMS.CMS.SiteSecurityTxt` row (see `KilnCMS.SecurityTxt`).

  404 when the site has no contact configured — the RFC's "no security.txt",
  rather than a file missing its one required field. `Canonical` is the
  request site's own URL, so each tenant host names itself.

  `/security.txt` is the RFC's legacy location (§3): it redirects here rather
  than serving a second copy, so there is only one URL a `Canonical` can name.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.SecurityTxt

  def show(conn, _params) do
    org = KilnCMSWeb.Tenant.current_org(conn)

    case SecurityTxt.resolve(org) do
      {:ok, settings} ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> send_resp(200, SecurityTxt.render(settings, SecurityTxt.canonical_url(org)))

      :unconfigured ->
        conn |> put_resp_content_type("text/plain", "utf-8") |> send_resp(404, "Not Found\n")

      :unavailable ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> put_resp_header("retry-after", "60")
        |> send_resp(503, "Service Unavailable\n")
    end
  end

  def legacy(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/.well-known/security.txt")
  end
end
