defmodule KilnCMSWeb.Plugs.UploadHeaders do
  @moduledoc """
  Hardens responses for user-uploaded media served from `/uploads`.

  Forces every upload to download rather than render inline
  (`Content-Disposition: attachment`) and disables MIME sniffing
  (`X-Content-Type-Options: nosniff`). Defense-in-depth against stored XSS:
  even if a malicious file (SVG/HTML, or active content mislabelled with an
  image extension) slips past upload validation, the browser will not execute
  it as active content in the app's origin.

  Runs in the endpoint immediately before the `/uploads` `Plug.Static` mount so
  the headers are in place when the static plug sends the file.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["uploads" | _]} = conn, _opts) do
    conn
    |> put_resp_header("content-disposition", "attachment")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  def call(conn, _opts), do: conn
end
