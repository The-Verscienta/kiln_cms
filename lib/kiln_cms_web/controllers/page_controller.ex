defmodule KilnCMSWeb.PageController do
  use KilnCMSWeb, :controller

  # `current_org` is forwarded so the header renders THIS site's logo and name.
  # Without it `Layouts.app`'s `default: nil` attr falls through to
  # `Branding.for_org(nil)`, so a tenant host showed the DEFAULT org's identity.
  # The `SetTenant` plug already resolved it; these two actions just dropped it.
  #
  # Not routed directly: `/` goes to `ContentController.home/2`, which calls
  # this for a site that has no published Home page of its own.
  # `locale` keeps the delivery chrome's nav links prefixed for the request's
  # locale. No `locale_links`: the switcher needs a URL per locale, and the site
  # root has none — `Plugs.SetLocale` strips a locale prefix only when a segment
  # follows it, so `/fr` is a page slug and `/fr/` 404s. Every OTHER delivery
  # page has a real per-locale URL, which is why they pass the links and this
  # one draws no switcher rather than a row of dead links.
  def home(conn, _params) do
    render(conn, :home,
      current_user: conn.assigns[:current_user],
      current_org: KilnCMSWeb.Tenant.current_org(conn),
      locale: conn.assigns[:locale] || KilnCMS.I18n.default_locale()
    )
  end

  # Served summary of the headless API surfaces (#319): endpoints, auth in
  # brief, and onward links to the Swagger UI / OpenAPI spec / repo docs.
  #
  # The curl examples carry this site's own base URL (#1872), so each one can be
  # pasted as it stands: `https://kilncms.dev/...` there, `http://localhost:4000`
  # on a dev checkout, an org's own host on a multi-org deployment.
  def developers(conn, _params) do
    current_org = KilnCMSWeb.Tenant.current_org(conn)

    render(conn, :developers,
      current_scope: nil,
      current_user: conn.assigns[:current_user],
      current_org: current_org,
      site_url: KilnCMSWeb.Tenant.base_url(current_org),
      page_title: gettext("Developer APIs")
    )
  end

  def api(conn, _params) do
    redirect(conn, to: "/developers")
  end

  # GET /gql. Absinthe supports GET-based queries (`?query=…`), so those are
  # re-dispatched to it with the same options as the router's forward; a bare
  # browser GET lands on the developer docs instead of Absinthe's 400 (#319).
  def gql_get(conn, %{"query" => _}) do
    Absinthe.Plug.call(conn, Absinthe.Plug.init(KilnCMSWeb.Router.graphql_opts()))
  end

  def gql_get(conn, _params) do
    redirect(conn, to: "/developers#graphql")
  end
end
