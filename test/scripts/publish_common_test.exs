Code.require_file("../../scripts/publish/common.exs", __DIR__)

defmodule KilnCMS.Scripts.PublishCommonTest do
  @moduledoc """
  The parts of `scripts/publish/common.exs` that are not covered through
  `scripts/publish/releases.exs`: the guide-level search description the docs
  publisher sends as `seo_description` (#1876), the schema probe the
  release publisher uses to decide on the index's sign-up (#1870), and a
  guide's screenshots as image blocks backed by uploaded media (#2158).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.HTMLSanitizer
  alias KilnPublish.{API, Markdown}

  defp blocks(markdown, source \\ "docs/guide.md"),
    do: markdown |> Markdown.parse(source) |> Markdown.blocks(source)

  describe "seo_description/1" do
    test "reads the comment, collapsing its line breaks" do
      markdown = """
      # Kiln vs Ghost

      <!-- seo-description: How Kiln compares with Ghost,
           with sources. -->

      Body.
      """

      assert Markdown.seo_description(markdown) == "How Kiln compares with Ghost, with sources."
    end

    test "is nil without one, or with an empty one" do
      assert Markdown.seo_description("# Title\n\nBody.\n") == nil
      assert Markdown.seo_description("<!-- seo-description:   -->\n") == nil
    end

    test "an ordinary comment is not a description" do
      assert Markdown.seo_description("<!-- a maintainer note -->\n") == nil
    end

    test "the comment never reaches the published body" do
      html =
        "<!-- seo-description: Hidden. -->\n\nVisible.\n"
        |> Markdown.parse("test.md")
        |> Markdown.render()

      refute html =~ "Hidden"
      assert html =~ "Visible."
    end
  end

  describe "schema/1" do
    # The client's base URL is `/api/json` and it sends JSON:API's media type;
    # the schema lives at `/api/schema` on the `:api` pipeline, which accepts
    # plain JSON only.
    test "reads /api/schema as plain JSON" do
      req =
        API.client("https://site.test/", "key")
        |> Req.merge(
          plug: fn conn ->
            send(self(), {:request, conn.request_path, Plug.Conn.get_req_header(conn, "accept")})
            Plug.Conn.send_resp(conn, 200, ~s({"$defs":{"block_heading":{}}}))
          end
        )

      assert {:ok, %{"$defs" => %{"block_heading" => %{}}}} = API.schema(req)
      assert_received {:request, "/api/schema", ["application/json"]}
    end
  end

  describe "blocks/2" do
    test "a paragraph holding only a repo image is an image block, in document order" do
      assert [
               {:html, "<h2>Write</h2><p>Open the editor.</p>"},
               {:image,
                %{
                  src: "docs/images/editorial-workflow/1-list.webp",
                  alt: "The content list",
                  caption: "Views on the left"
                }},
               {:html, "<ol><li>Pick a view.</li></ol>"}
             ] =
               blocks("""
               ## Write

               Open the editor.

               ![The content list](images/editorial-workflow/1-list.webp "Views on the left")

               1. Pick a view.
               """)
    end

    test "an image with no title has no caption" do
      assert [{:image, %{caption: nil}}] = blocks("![Alt](images/a.webp)\n")
    end

    test "two images in a row are two blocks" do
      assert [{:image, %{src: "docs/images/a.webp"}}, {:image, %{src: "docs/images/b.webp"}}] =
               blocks("![A](images/a.webp)\n\n![B](images/b.webp)\n")
    end

    # The "Deploy to Render" badge: `<a><img></a>` lost its only content to the
    # sanitizer and published as an empty link.
    test "an image inside a link or a sentence renders as its alt text" do
      assert [{:html, html}] =
               blocks("""
               [![Deploy to Render](https://render.com/button.svg)](https://render.com/deploy)

               See ![the & icon](images/i.webp) here.
               """)

      assert html =~ ~s(<a href="https://render.com/deploy">Deploy to Render</a>)
      assert html =~ "<p>See the &amp; icon here.</p>"
      refute html =~ "<img"
    end

    test "a standalone image at an external URL is a link labelled with its alt text" do
      assert [{:html, ~s(<p><a href="https://example.com/shot.png">A screenshot</a></p>)}] =
               blocks("![A screenshot](https://example.com/shot.png)\n")
    end

    test "a standalone image with an unusable URL keeps only its alt text" do
      assert [{:html, "<p>Bad &lt;one&gt;</p>"}] = blocks("![Bad <one>](javascript:alert(1))\n")
    end

    test "a document with no images is render/1's HTML, as one block" do
      markdown = File.read!("docs/working-copy.md")
      ast = Markdown.parse(markdown, "docs/working-copy.md")

      assert Markdown.blocks(ast, "docs/working-copy.md") == [{:html, Markdown.render(ast)}]
    end

    test "an empty document is one empty rich_text block, as before" do
      assert blocks("") == [{:html, ""}]
    end

    test "the prose around an image survives the rich-text sanitizer" do
      [{:html, before}, {:image, _}, {:html, rest}] =
        blocks("""
        Read [the guide](https://kilncms.dev/docs) first.

        ![Shot](images/a.webp)

        [![Deploy to Render](https://render.com/b.svg)](https://render.com/deploy)
        """)

      assert HTMLSanitizer.sanitize_rich_text(before) =~ ~s(href="https://kilncms.dev/docs")

      assert HTMLSanitizer.sanitize_rich_text(rest) =~
               ~r{<a href="https://render.com/deploy"[^>]*>Deploy to Render</a>}
    end
  end

  describe "block_tree/1" do
    test "prose is rich_text, an image is an image block linked to its media item" do
      assert API.block_tree([
               {:html, "<p>Hi</p>"},
               {:image, %{src: "docs/a.webp", alt: "A", caption: nil, media_id: "m1", url: "/u"}},
               {:image,
                %{src: "docs/b.webp", alt: "B", caption: "Cap", media_id: "m2", url: "/v"}}
             ]) == [
               %{"_type" => "rich_text", "legacy_html" => "<p>Hi</p>"},
               %{"_type" => "image", "media_id" => "m1", "url" => "/u", "alt" => "A"},
               %{
                 "_type" => "image",
                 "media_id" => "m2",
                 "url" => "/v",
                 "alt" => "B",
                 "caption" => "Cap"
               }
             ]
    end

    test "rich_text_tree/1 is the one-block tree it always was" do
      assert API.rich_text_tree("<p>x</p>") == [
               %{"_type" => "rich_text", "legacy_html" => "<p>x</p>"}
             ]
    end
  end

  describe "ensure_media/3" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      path = Path.join(dir, "1-content-list.webp")
      File.write!(path, "RIFF fake webp")
      name = API.media_filename(path, "RIFF fake webp")
      %{path: path, name: name}
    end

    @item %{"id" => "media-1", "attributes" => %{"url" => "/media/media-1/file.webp"}}

    test "names the item after the file and its content hash", %{name: name} do
      assert name =~ ~r/\A1-content-list-[0-9a-f]{12}\.webp\z/
      refute API.media_filename("x/1-content-list.webp", "other bytes") == name
    end

    test "an item already uploaded under that name is reused, with no upload", %{
      path: path,
      name: name
    } do
      req = media_client(fn _conn -> {200, %{"data" => [@item]}} end)

      assert {:ok, :exists, %{media_id: "media-1", url: "/media/media-1/file.webp"}} =
               API.ensure_media(req, path, "The content list")

      assert_received {:request, "GET", "/api/json/media-items", conn}
      assert conn.query_params == %{"filter" => %{"filename" => name}}
      refute_received {:request, "POST", _, _}
    end

    test "a missing item is uploaded to /api/media as multipart, asking for plain JSON", %{
      path: path,
      name: name
    } do
      req =
        media_client(fn
          %{method: "GET"} -> {200, %{"data" => []}}
          %{method: "POST"} -> {201, %{"data" => @item}}
        end)

      assert {:ok, :uploaded, %{media_id: "media-1"}} =
               API.ensure_media(req, path, "The content list")

      assert_received {:request, "POST", "/api/media", conn}
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "multipart/form-data"
      assert %Plug.Upload{filename: ^name, content_type: "image/webp"} = conn.params["file"]
      assert File.read!(conn.params["file"].path) == "RIFF fake webp"
      assert conn.params["alt"] == "The content list"
    end

    test "a refused upload is an error", %{path: path} do
      req =
        media_client(fn
          %{method: "GET"} -> {200, %{"data" => []}}
          %{method: "POST"} -> {422, %{"errors" => [%{"code" => "strip_failed"}]}}
        end)

      assert {:error, message} = API.ensure_media(req, path, "Alt")
      assert message =~ "422"
      assert message =~ "strip_failed"
    end

    test "a refused lookup is an error, and nothing is uploaded", %{path: path} do
      req = media_client(fn _conn -> {403, %{"errors" => []}} end)

      assert {:error, message} = API.ensure_media(req, path, "Alt")
      assert message =~ "403"
      refute_received {:request, "POST", _, _}
    end
  end

  defp media_client(responder) do
    API.client("https://site.test/", "key")
    |> Req.merge(
      plug: fn conn ->
        conn =
          Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))

        send(self(), {:request, conn.method, conn.request_path, conn})
        {status, body} = responder.(conn)
        Plug.Conn.send_resp(conn, status, Jason.encode!(body))
      end
    )
  end
end
