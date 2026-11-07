defmodule KilnDepFixture.FeedRouter do
  @moduledoc """
  A `Plug.Router` the fixture plugin `forward`s to from `plug_routes/0`
  (#2272): the mount point is stripped, so `/fixture-forward/hello` reaches
  the `/hello` clause here.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/hello" do
    send_resp(conn, 200, "hello from the forward")
  end

  match _ do
    send_resp(conn, 404, "no such feed")
  end
end
