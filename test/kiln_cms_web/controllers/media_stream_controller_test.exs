defmodule KilnCMSWeb.MediaStreamControllerTest do
  @moduledoc """
  `/media/:id/stream` (#494) — the playback path for every video/audio block.

  It shares authorization with the download path (covered in
  `MediaDownloadControllerTest`); what's new and worth pinning here is the
  part a player depends on: inline delivery, `Accept-Ranges`, correct 206
  `Content-Range` arithmetic, and the fact that an editor-supplied
  `content_type` cannot turn this route into an inline host for arbitrary
  content on the app's own origin.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Storage

  # Long enough to range over meaningfully, short enough to assert on.
  @body "0123456789abcdefghijklmnopqrstuvwxyz"

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_st_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_st_priv_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(private_root)

    Application.put_env(:kiln_cms, KilnCMS.Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(private_root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    %{root: root, private_root: private_root}
  end

  defp signed_in_user(attrs) do
    email = "st-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now()
        },
        attrs
      )
    )

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => "password123456"
      })

    user
  end

  defp editor, do: signed_in_user(%{role: :editor})
  defp reader(audiences), do: signed_in_user(%{role: :viewer, audiences: audiences})

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp media!(actor, attrs, body \\ @body) do
    key = Storage.generate_key("clip.mp4")
    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(src, body)
    {:ok, ^key} = Storage.store(key, src)

    CMS.create_media_item!(
      Map.merge(
        %{
          filename: "clip.mp4",
          content_type: "video/mp4",
          storage_key: key,
          url: Storage.url(key)
        },
        attrs
      ),
      actor: actor
    )
  end

  defp gated!(actor, audience) do
    item = media!(actor, %{})
    {:ok, gated} = CMS.update_media_item(item, %{audience: audience}, actor: actor)
    gated
  end

  describe "a plain (un-ranged) request" do
    test "serves the whole file inline, advertising range support", %{conn: conn} do
      item = media!(editor(), %{})

      conn = get(conn, "/media/#{item.id}/stream")

      assert conn.status == 200
      assert conn.resp_body == @body
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      # Inline, NOT `attachment` — a <video> can't play a response the browser
      # is told to save.
      assert get_resp_header(conn, "content-disposition") == []
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "video/mp4"
    end

    test "playback does not bump the download counter", %{conn: conn} do
      item = media!(editor(), %{})

      get(conn, "/media/#{item.id}/stream")

      # A single scrub through a video is dozens of ranged requests; counting
      # those as downloads would make the number meaningless.
      assert {:ok, %{download_count: 0}} = CMS.get_media_item(item.id, authorize?: false)
    end
  end

  describe "Range requests" do
    test "a bounded range comes back as a 206 with the right slice and Content-Range", %{
      conn: conn
    } do
      item = media!(editor(), %{})

      conn =
        conn
        |> put_req_header("range", "bytes=5-9")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 206
      assert conn.resp_body == "56789"

      assert get_resp_header(conn, "content-range") == [
               "bytes 5-9/#{byte_size(@body)}"
             ]
    end

    test "an open-ended range runs to the end of the file", %{conn: conn} do
      item = media!(editor(), %{})
      last = byte_size(@body) - 1

      conn =
        conn
        |> put_req_header("range", "bytes=30-")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 206
      assert conn.resp_body == binary_part(@body, 30, byte_size(@body) - 30)
      assert get_resp_header(conn, "content-range") == ["bytes 30-#{last}/#{byte_size(@body)}"]
    end

    test "a range running past the end is clamped, not an error", %{conn: conn} do
      item = media!(editor(), %{})
      last = byte_size(@body) - 1

      conn =
        conn
        |> put_req_header("range", "bytes=30-99999")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 30-#{last}/#{byte_size(@body)}"]
    end

    test "a range starting past the end is 416, not an empty 206", %{conn: conn} do
      item = media!(editor(), %{})

      conn =
        conn
        |> put_req_header("range", "bytes=99999-")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 416
      # RFC 9110 §14.4: the 416 must state the resource's real length. `*` in
      # the LENGTH position is not valid syntax, only in the range position.
      assert get_resp_header(conn, "content-range") == ["bytes */#{byte_size(@body)}"]
    end

    test "malformed range syntax falls back to the full representation" do
      item = media!(editor(), %{})

      for value <- ["bytes=abc", "bytes=9-5", "bytes=-500", "items=0-5", ""] do
        conn =
          Phoenix.ConnTest.build_conn()
          |> put_req_header("range", value)
          |> get("/media/#{item.id}/stream")

        assert conn.status == 200, "expected a 200 fallback for range #{inspect(value)}"
        assert conn.resp_body == @body
      end
    end

    test "a multi-range request is answered whole rather than half-served", %{conn: conn} do
      # No media player asks for one, and a partial answer to a multi-range
      # request would be a corrupt file.
      item = media!(editor(), %{})

      conn =
        conn
        |> put_req_header("range", "bytes=0-4,10-14")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 200
      assert conn.resp_body == @body
    end
  end

  describe "the memory cap" do
    # `@max_chunk` in the controller. A body larger than it is the only way to
    # tell a capped response from an uncapped one — with a 36-byte fixture,
    # deleting the cap entirely would leave every other test in this file green.
    @big_size 9 * 1024 * 1024
    @chunk 8 * 1024 * 1024

    test "a ranged request never returns more than one chunk, however much it asks for", %{
      conn: conn
    } do
      item = media!(editor(), %{}, :binary.copy("x", @big_size))

      conn =
        conn
        |> put_req_header("range", "bytes=0-")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 206
      assert byte_size(conn.resp_body) == @chunk

      assert get_resp_header(conn, "content-range") == [
               "bytes 0-#{@chunk - 1}/#{@big_size}"
             ]
    end

    test "an un-ranged request streams the whole body chunked rather than buffering it", %{
      conn: conn
    } do
      # This is the path an attacker picks by simply omitting `Range`, so the
      # cap has to hold here too — the response is complete, but assembled a
      # chunk at a time rather than read into one binary.
      item = media!(editor(), %{}, :binary.copy("x", @big_size))

      conn = get(conn, "/media/#{item.id}/stream")

      assert conn.status == 200
      assert byte_size(conn.resp_body) == @big_size
      assert conn.state == :chunked
    end

    test "an unparseable Range can't be used to ask for an unbounded read", %{conn: conn} do
      item = media!(editor(), %{}, :binary.copy("x", @big_size))

      conn =
        conn
        |> put_req_header("range", "bytes=0-0,1-1")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 200
      assert byte_size(conn.resp_body) == @big_size
      assert conn.state == :chunked
    end

    test "a small file is sent whole, not chunked", %{conn: conn} do
      # `:sent` rather than `:chunked` is what gives the response a
      # Content-Length (Plug's adapter derives it from a single-shot body), so
      # anything that fits in one chunk keeps the simpler, measurable response.
      item = media!(editor(), %{})

      conn = get(conn, "/media/#{item.id}/stream")

      assert conn.status == 200
      assert conn.state == :sent
    end

    test "a zero-byte blob is an empty 200, not a 404", %{conn: conn} do
      item = media!(editor(), %{}, "")

      conn = get(conn, "/media/#{item.id}/stream")

      assert conn.status == 200
      assert conn.resp_body == ""
    end
  end

  describe "authorization" do
    test "a gated item 404s for an anonymous viewer" do
      item = gated!(editor(), :member)
      conn = get(Phoenix.ConnTest.build_conn(), "/media/#{item.id}/stream")
      assert conn.status == 404
    end

    test "a gated item 404s for a reader without the audience", %{conn: conn} do
      item = gated!(editor(), :member)
      conn = conn |> log_in(reader([])) |> get("/media/#{item.id}/stream")
      assert conn.status == 404
    end

    test "a gated item streams from PRIVATE storage for a reader who holds the audience", %{
      conn: conn,
      private_root: private_root
    } do
      item = gated!(editor(), :member)
      assert File.exists?(Path.join(private_root, item.storage_key))

      conn = conn |> log_in(reader([:member])) |> get("/media/#{item.id}/stream")

      assert conn.status == 200
      assert conn.resp_body == @body
    end

    test "a gated item honours Range from private storage too", %{conn: conn} do
      item = gated!(editor(), :member)

      conn =
        conn
        |> log_in(reader([:member]))
        |> put_req_header("range", "bytes=0-3")
        |> get("/media/#{item.id}/stream")

      assert conn.status == 206
      assert conn.resp_body == "0123"
    end

    test "an unknown id 404s rather than raising" do
      conn = get(Phoenix.ConnTest.build_conn(), "/media/#{Ash.UUID.generate()}/stream")
      assert conn.status == 404
    end
  end

  describe "the inline allowlist" do
    test "a PDF falls back to the attachment path rather than being served inline", %{conn: conn} do
      item = media!(editor(), %{content_type: "application/pdf", filename: "doc.pdf"})

      conn = get(conn, "/media/#{item.id}/stream")

      assert conn.status == 200

      assert get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"doc.pdf\""
             ]
    end

    test "an editor-set text/html content_type is never echoed into an inline response", %{
      conn: conn
    } do
      # `content_type` is in MediaItem's default_accept — an editor with API
      # access can set it to anything. If that reached an inline response on
      # this origin, an uploaded file would become stored XSS.
      item =
        media!(
          editor(),
          %{content_type: "text/html", filename: "payload.html"},
          "<script>alert(1)</script>"
        )

      conn = get(conn, "/media/#{item.id}/stream")

      assert get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"payload.html\""
             ]

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "a WebVTT track streams inline so a <track> can load it", %{conn: conn} do
      item = media!(editor(), %{content_type: "text/vtt", filename: "captions.vtt"}, "WEBVTT\n")

      conn = get(conn, "/media/#{item.id}/stream")

      assert conn.status == 200
      assert get_resp_header(conn, "content-disposition") == []
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/vtt"
    end
  end
end
