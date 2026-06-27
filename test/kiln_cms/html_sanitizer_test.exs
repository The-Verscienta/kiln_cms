defmodule KilnCMS.HTMLSanitizerTest do
  use ExUnit.Case, async: true

  alias KilnCMS.HTMLSanitizer

  @quote <<34>>
  @colon <<58>>

  describe "sanitize_rich_text/1" do
    test "preserves TipTap StarterKit markup" do
      html = "<p>Hi <strong>there</strong></p><ul><li>one</li></ul>"

      assert HTMLSanitizer.sanitize_rich_text(html) == html
    end

    test "strips script tags and event handlers" do
      html =
        [
          "<p onclick=",
          @quote,
          "alert(1)",
          @quote,
          ">Hi</p><script>alert(",
          @quote,
          "xss",
          @quote,
          ")</script>"
        ]
        |> Enum.join()

      sanitized = HTMLSanitizer.sanitize_rich_text(html)

      assert sanitized =~ "<p>Hi</p>"
      refute sanitized =~ "<script"
      refute sanitized =~ "onclick"
    end

    test "strips disallowed tags like iframe" do
      src = URI.to_string(%URI{scheme: "https", host: "evil.example"})

      html =
        ["<p>Safe</p><iframe src=", @quote, src, @quote, "></iframe>"]
        |> Enum.join()

      assert HTMLSanitizer.sanitize_rich_text(html) == "<p>Safe</p>"
    end

    test "handles nil and empty input" do
      assert HTMLSanitizer.sanitize_rich_text(nil) == ""
      assert HTMLSanitizer.sanitize_rich_text("") == ""
    end

    test "preserves safe https / mailto / relative hyperlinks (#148)" do
      https = "https" <> @colon <> "//example.com/read-more"
      mailto = "mailto" <> @colon <> "hi@example.com"

      for href <- [https, mailto, "/blog/post", "#section"] do
        html = ["<p><a href=", @quote, href, @quote, ">link</a></p>"] |> Enum.join()
        sanitized = HTMLSanitizer.sanitize_rich_text(html)

        assert sanitized =~ "href=" <> @quote <> href <> @quote,
               "expected href #{href} to survive sanitization"

        assert sanitized =~ ">link</a>"
      end
    end

    test "strips dangerous / disallowed link schemes but keeps the text (#148)" do
      js = "javascript" <> @colon <> "alert(1)"
      data = "data" <> @colon <> "text/plain;base64,ABC"
      # bare http is not on the https/mailto allowlist
      http = "http" <> @colon <> "//insecure.example"

      for href <- [js, data, http] do
        html = ["<p><a href=", @quote, href, @quote, ">click</a></p>"] |> Enum.join()
        sanitized = HTMLSanitizer.sanitize_rich_text(html)

        refute sanitized =~ href, "expected unsafe href #{href} to be stripped"
        assert sanitized =~ "click"
      end
    end
  end

  describe "safe_embed_url/1" do
    test "normalizes YouTube watch URLs to embed src" do
      url =
        URI.to_string(%URI{
          scheme: "https",
          host: "www.youtube.com",
          path: "/watch",
          query: "v=abc123"
        })

      assert HTMLSanitizer.safe_embed_url(url) == "https://www.youtube.com/embed/abc123"
    end

    test "allows Vimeo player URLs" do
      url = URI.to_string(%URI{scheme: "https", host: "player.vimeo.com", path: "/video/12345"})

      assert HTMLSanitizer.safe_embed_url(url) == "https://player.vimeo.com/video/12345"
    end

    test "rejects unknown embed hosts" do
      assert HTMLSanitizer.safe_embed_url("https://evil.example/embed") == nil
    end
  end

  describe "safe_image_src/1" do
    test "allows relative upload paths" do
      assert HTMLSanitizer.safe_image_src("/uploads/abc.jpg") == "/uploads/abc.jpg"
    end

    test "allows https URLs" do
      url = URI.to_string(%URI{scheme: "https", host: "cdn.example.com", path: "/photo.png"})

      assert HTMLSanitizer.safe_image_src(url) == url
    end

    test "rejects unsafe and traversal URLs" do
      assert HTMLSanitizer.safe_image_src(["javascript", @colon, "alert(1)"] |> Enum.join()) ==
               nil

      assert HTMLSanitizer.safe_image_src(["data", @colon, "image/png;base64,abc"] |> Enum.join()) ==
               nil

      assert HTMLSanitizer.safe_image_src("/uploads/../etc/passwd") == nil
      assert HTMLSanitizer.safe_image_src("//evil.example/img.png") == nil
    end

    test "rejects nil and blank input" do
      assert HTMLSanitizer.safe_image_src(nil) == nil
      assert HTMLSanitizer.safe_image_src(<<32, 32>>) == nil
    end
  end
end
