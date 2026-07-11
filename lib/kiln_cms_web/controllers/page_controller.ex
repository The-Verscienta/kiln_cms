defmodule KilnCMSWeb.PageController do
  use KilnCMSWeb, :controller

  def home(conn, _params) do
    render(conn, :home, current_scope: nil, current_user: conn.assigns[:current_user])
  end

  # Served summary of the headless API surfaces (#319): endpoints, auth in
  # brief, and onward links to the Swagger UI / OpenAPI spec / repo docs.
  def developers(conn, _params) do
    render(conn, :developers,
      current_scope: nil,
      current_user: conn.assigns[:current_user],
      page_title: gettext("Developer APIs")
    )
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
