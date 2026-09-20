defmodule KilnCMSWeb.Plugs.MultipartParserTest do
  @moduledoc """
  The endpoint's multipart parser leaves exactly one route's body unread — the
  upload API's, whose controller parses it only after authorizing — and
  parses every other multipart body exactly as `:multipart` did.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  # The endpoint's own parser configuration, minus the parsers irrelevant to
  # a multipart body.
  @parsers Plug.Parsers.init(
             parsers: [:urlencoded, KilnCMSWeb.Plugs.MultipartParser, :json],
             pass: ["*/*"],
             json_decoder: Jason,
             length: 8_000_000
           )

  defp multipart_conn(method, path) do
    boundary = "b#{System.unique_integer([:positive])}"

    body =
      "--#{boundary}\r\ncontent-disposition: form-data; name=\"alt\"\r\n\r\nhello\r\n--#{boundary}--\r\n"

    method
    |> conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
  end

  test "POST /api/media is left unread for its controller" do
    conn = "POST" |> multipart_conn("/api/media") |> Plug.Parsers.call(@parsers)

    assert %Plug.Conn.Unfetched{} = conn.body_params
    refute Map.has_key?(conn.params, "alt")
  end

  test "any other multipart request is parsed as before" do
    for {method, path} <- [
          {"POST", "/forms/contact"},
          {"POST", "/api/media/import-url"},
          {"PUT", "/api/media"}
        ] do
      conn = method |> multipart_conn(path) |> Plug.Parsers.call(@parsers)
      assert conn.body_params == %{"alt" => "hello"}, "#{method} #{path} was not parsed"
    end
  end
end
