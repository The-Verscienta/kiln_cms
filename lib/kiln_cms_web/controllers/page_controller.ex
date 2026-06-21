defmodule KilnCMSWeb.PageController do
  use KilnCMSWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
