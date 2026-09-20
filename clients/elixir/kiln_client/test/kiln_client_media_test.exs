defmodule KilnClientMediaTest do
  # `async: false`: the direct-upload test configures an API key, which is
  # global app env the async suite's header assertions would see.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  @parsers Plug.Parsers.init(
             parsers: [:multipart, :json],
             pass: ["*/*"],
             json_decoder: Jason,
             body_reader: {__MODULE__, :read_body, []}
           )

  # Plug's JSON parser only claims `application/json` and `+json` types —
  # `application/vnd.api+json` included — so both write shapes parse here.
  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp parse(conn), do: Plug.Parsers.call(conn, @parsers)

  defp created(conn, attributes \\ %{}, processing \\ false) do
    Req.Test.json(conn |> Plug.Conn.put_status(201), %{
      "data" => %{
        "type" => "media_item",
        "id" => "m1",
        "attributes" => Map.merge(%{"filename" => "cat.png"}, attributes),
        "relationships" => %{"tags" => %{"data" => [%{"type" => "tag", "id" => "t1"}]}},
        "meta" => %{"processing" => processing}
      }
    })
  end

  defp tmp_file(bytes) do
    path = Path.join(System.tmp_dir!(), "kiln-client-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "upload_media/2" do
    test "POSTs the file as multipart with its metadata, and flattens the item" do
      path = tmp_file("pngbytes")

      Req.Test.stub(KilnClient, fn conn ->
        conn = parse(conn)
        send(self(), {:request, conn.method, conn.request_path, conn.body_params})
        created(conn, %{"alt" => "A cat"})
      end)

      assert {:ok, item} =
               KilnClient.upload_media(path,
                 filename: "cat.png",
                 alt: "A cat",
                 focal_x: 0.25,
                 decorative: false,
                 tag_ids: ["t1", "t2"]
               )

      assert_received {:request, "POST", "/api/media", params}
      assert %Plug.Upload{filename: "cat.png", path: upload_path} = params["file"]
      assert File.read!(upload_path) == "pngbytes"
      assert params["alt"] == "A cat"
      assert params["focal_x"] == "0.25"
      assert params["decorative"] == "false"
      assert params["tag_ids"] == ["t1", "t2"]

      assert item["id"] == "m1"
      assert item["alt"] == "A cat"
      assert item["relationships"]["tags"] == [%{"type" => "tag", "id" => "t1"}]
      assert item["processing"] == false
    end

    test "a refusal comes back as the HTTP status and body" do
      Req.Test.stub(KilnClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"errors" => [%{"code" => "forbidden"}]})
      end)

      assert {:error, {:http_status, 403, %{"errors" => [%{"code" => "forbidden"}]}}} =
               KilnClient.upload_media(tmp_file("x"))
    end
  end

  test "import_media/2 POSTs the URL and metadata as JSON" do
    Req.Test.stub(KilnClient, fn conn ->
      conn = parse(conn)
      send(self(), {:request, conn.request_path, conn.body_params})
      created(conn)
    end)

    assert {:ok, %{"id" => "m1"}} =
             KilnClient.import_media("https://example.com/cat.png", caption: "Imported")

    assert_received {:request, "/api/media/import-url",
                     %{"url" => "https://example.com/cat.png", "caption" => "Imported"} = body}

    refute Map.has_key?(body, "filename")
  end

  test "update_media/3 PATCHes the JSON:API route with only the metadata attributes" do
    Req.Test.stub(KilnClient, fn conn ->
      conn = parse(conn)

      send(
        self(),
        {:request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "content-type"),
         conn.body_params}
      )

      Req.Test.json(conn, %{
        "data" => %{"type" => "media_item", "id" => "m1", "attributes" => %{"alt" => "New"}}
      })
    end)

    assert {:ok, %{"alt" => "New"}} =
             KilnClient.update_media("m1", alt: "New", add_tag_ids: ["t3"], url: "ignored")

    assert_received {:request, "PATCH", "/api/json/media-items/m1", [content_type], body}
    assert content_type =~ "application/vnd.api+json"

    assert body["data"] == %{
             "type" => "media_item",
             "id" => "m1",
             "attributes" => %{"alt" => "New", "add_tag_ids" => ["t3"]}
           }
  end

  test "upload_media_direct/2 begins, PUTs the file to the presigned URL, then completes" do
    path = tmp_file("0123456789")

    Req.Test.stub(KilnClient, fn conn ->
      case {conn.method, conn.host, conn.request_path} do
        {"POST", "kiln.test", "/api/media/uploads"} ->
          conn = parse(conn)
          send(self(), {:begin, conn.body_params})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "data" => %{
              "token" => "tok",
              "upload_url" => "https://bucket.test/private/direct-uploads/abc?X-Amz-Signature=s",
              "method" => "PUT",
              "headers" => %{"content-length" => "10"},
              "expires_at" => "2026-09-19T12:15:00Z",
              "max_bytes" => 500_000_000
            }
          })

        {"PUT", "bucket.test", "/private/direct-uploads/abc"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            self(),
            {:put, body, Plug.Conn.get_req_header(conn, "content-length"),
             Plug.Conn.get_req_header(conn, "authorization")}
          )

          Plug.Conn.send_resp(conn, 200, "")

        {"POST", "kiln.test", "/api/media/uploads/complete"} ->
          conn = parse(conn)
          send(self(), {:complete, conn.body_params})
          created(conn, %{"alt" => "Big"})
      end
    end)

    Application.put_env(:kiln_client, :api_key, "kiln_rw")
    on_exit(fn -> Application.delete_env(:kiln_client, :api_key) end)

    assert {:ok, %{"alt" => "Big"}} =
             KilnClient.upload_media_direct(path, filename: "big.mp4", alt: "Big")

    assert_received {:begin, %{"filename" => "big.mp4", "byte_size" => 10}}
    # The bucket gets the bytes and the signed length — and no Kiln key.
    assert_received {:put, "0123456789", ["10"], []}
    assert_received {:complete, %{"token" => "tok", "alt" => "Big"}}
  end
end
