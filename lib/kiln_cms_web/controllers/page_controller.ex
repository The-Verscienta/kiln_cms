defmodule KilnCMSWeb.PageController do
  use KilnCMSWeb, :controller

  def home(conn, _params) do
    render(conn, :home, current_scope: nil, current_user: conn.assigns[:current_user])
  end
end
