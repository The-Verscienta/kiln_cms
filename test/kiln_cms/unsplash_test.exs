defmodule KilnCMS.UnsplashTest do
  @moduledoc false
  # async: false — enabling the integration merges an access key into the
  # global :unsplash app env.
  use ExUnit.Case, async: false

  alias KilnCMS.Unsplash

  # A minimal valid 1x1 PNG.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207, 0, 0,
         0, 7, 0, 1, 2, 254, 165, 53, 230, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  defp enable_unsplash(_context) do
    previous = Application.get_env(:kiln_cms, :unsplash, [])
    Application.put_env(:kiln_cms, :unsplash, Keyword.put(previous, :access_key, "test-key"))
    on_exit(fn -> Application.put_env(:kiln_cms, :unsplash, previous) end)
    :ok
  end

  describe "enabled?/0 and csp_img_src/0" do
    test "disabled without an access key" do
      refute Unsplash.enabled?()
      assert Unsplash.csp_img_src() == []
    end
  end

  describe "with an access key" do
    setup :enable_unsplash

    test "enabled, and the thumbnail host joins the CSP img-src" do
      assert Unsplash.enabled?()
      assert Unsplash.csp_img_src() == ["https://images.unsplash.com"]
    end

    test "search maps photos and reports whether more pages exist" do
      Req.Test.stub(KilnCMS.Unsplash, fn conn ->
        assert conn.host == "api.unsplash.com"
        assert conn.request_path == "/search/photos"

        params = Plug.Conn.fetch_query_params(conn).query_params
        assert params["query"] == "herbs"
        assert params["page"] == "1"

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Client-ID test-key"]

        Req.Test.json(conn, %{
          "total_pages" => 3,
          "results" => [
            %{
              "id" => "abc123",
              "width" => 4000,
              "height" => 3000,
              "alt_description" => "dried herbs on a table",
              "urls" => %{"small" => "https://images.unsplash.com/photo-abc123?w=400"},
              "links" => %{
                "html" => "https://unsplash.com/photos/abc123",
                "download_location" => "https://api.unsplash.com/photos/abc123/download"
              },
              "user" => %{
                "name" => "Jane Lens",
                "links" => %{"html" => "https://unsplash.com/@janelens"}
              }
            }
          ]
        })
      end)

      assert {:ok, %{photos: [photo], more?: true}} = Unsplash.search("herbs")

      assert photo.id == "abc123"
      assert photo.alt == "dried herbs on a table"
      assert photo.thumb_url == "https://images.unsplash.com/photo-abc123?w=400"
      assert photo.download_location == "https://api.unsplash.com/photos/abc123/download"
      assert photo.photographer == "Jane Lens"
      # Attribution links carry the referral parameters Unsplash requires.
      assert photo.photographer_url =~ "utm_source=kiln_cms"
      assert photo.page_url =~ "utm_source=kiln_cms"
    end

    test "search reports no more pages on the last page" do
      Req.Test.stub(KilnCMS.Unsplash, fn conn ->
        Req.Test.json(conn, %{"total_pages" => 2, "results" => []})
      end)

      assert {:ok, %{photos: [], more?: false}} = Unsplash.search("herbs", 2)
    end

    test "search surfaces HTTP errors" do
      Req.Test.stub(KilnCMS.Unsplash, fn conn ->
        Plug.Conn.send_resp(conn, 401, "unauthorized")
      end)

      assert {:error, {:http_status, 401}} = Unsplash.search("herbs")
    end

    test "download reports the download, then fetches the returned URL to a temp file" do
      Req.Test.stub(KilnCMS.Unsplash, fn conn ->
        case conn.request_path do
          "/photos/abc123/download" ->
            Req.Test.json(conn, %{"url" => "https://images.unsplash.com/file-abc123"})

          "/file-abc123" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png")
            |> Plug.Conn.send_resp(200, @png)
        end
      end)

      photo = %{download_location: "https://api.unsplash.com/photos/abc123/download"}

      assert {:ok, path} = Unsplash.download(photo)
      assert File.read!(path) == @png
      File.rm!(path)
    end

    test "download without a download_location fails cleanly" do
      assert {:error, :bad_download_response} = Unsplash.download(%{download_location: nil})
    end
  end

  describe "attribution/1" do
    test "credits the photographer" do
      assert Unsplash.attribution(%{photographer: "Jane Lens"}) ==
               "Photo by Jane Lens on Unsplash"

      assert Unsplash.attribution(%{photographer: nil}) == "Photo from Unsplash"
    end
  end
end
