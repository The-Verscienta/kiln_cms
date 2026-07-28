defmodule KilnCMSWeb.Plugs.UploadHeadersTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMSWeb.Plugs.UploadHeaders

  describe "call/2" do
    test "stamps download + nosniff headers on /uploads requests" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/uploads/x.png")
        |> Map.put(:path_info, ["uploads", "x.png"])
        |> UploadHeaders.call([])

      assert get_resp_header(conn, "content-disposition") == ["attachment"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "leaves non-upload requests untouched" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/posts")
        |> Map.put(:path_info, ["posts"])
        |> UploadHeaders.call([])

      assert get_resp_header(conn, "content-disposition") == []
      assert get_resp_header(conn, "x-content-type-options") == []
    end
  end

  describe "served through the endpoint" do
    @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
           8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207,
           0, 0, 0, 7, 0, 1, 2, 254, 165, 53, 230, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

    test "uploaded files download with nosniff instead of rendering inline", %{conn: conn} do
      dir = Application.app_dir(:kiln_cms, "priv/uploads")
      File.mkdir_p!(dir)
      name = "headers-#{System.unique_integer([:positive])}.png"
      path = Path.join(dir, name)
      File.write!(path, @png)
      on_exit(fn -> File.rm(path) end)

      conn = get(conn, "/uploads/#{name}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-disposition") == ["attachment"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end
end
