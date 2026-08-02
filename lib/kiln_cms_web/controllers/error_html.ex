defmodule KilnCMSWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use KilnCMSWeb, :html

  # Branded HTML error pages live in error_html/ (currently 404, rendered inside
  # Layouts.public with recovery links — #145). Statuses without a template fall
  # through to the plain-text status message below.
  embed_templates "error_html/*"

  @doc """
  The organization whose branding an error page should wear (#656).

  An error on a tenant's site is still that tenant's page, and `Layouts.public`
  falls back to the **default org's** `site_name` and `logo_url` when handed a
  `nil` — so a 404 on `acme.example.com` used to show another site's identity,
  which is exactly what white-labelling (#48) exists to prevent.

  Read defensively rather than as `@conn.assigns[:current_org]`: an error page
  renders for requests that never reached `Plugs.SetTenant`, and there the
  `:conn` assign is not there to dereference — a template rendered directly, or
  a raise from an endpoint-level or router-pipeline plug, which `Plug.Builder`
  does not wrap and so arrives at the error renderer as the endpoint's *entry*
  conn with its assigns as they were before anything ran.

  For the direct render `nil` is the right answer: there is no tenant, so the
  operator's own defaults are what to show. For the pre-router raise it is the
  only *available* answer — a 500 caused by a bug in `ClientIp` or `RateLimit`
  still wears the default org's identity on a tenant's host, and nothing the
  template can do fixes that. What matters either way is that it must not be a
  second, uglier error.

  Where the assign does survive — a `NoRouteError`, a raise inside a controller
  or a disconnected LiveView mount — Phoenix hands the error renderer the conn
  that already passed through the router, so it carries the resolved tenant.
  """
  @spec error_org(map()) :: struct() | nil
  def error_org(assigns) do
    case assigns do
      %{conn: %Plug.Conn{assigns: %{current_org: org}}} -> org
      _no_resolved_tenant -> nil
    end
  end

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
