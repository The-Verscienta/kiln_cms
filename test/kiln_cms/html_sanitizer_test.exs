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

    test "keeps Makeup highlight markup intact (#503)" do
      # The first-party delivery path re-sanitizes fired PT→HTML, so the exact
      # markup KilnCMS.Highlight emits must survive the allowlist.
      {:ok, html} = KilnCMS.Highlight.highlight("IO.puts(1)", "elixir")

      assert HTMLSanitizer.sanitize_rich_text(html) == html
    end

    test "keeps the language class on plain code blocks (#503)" do
      html = ~s|<pre><code class="language-python">print(1)</code></pre>|

      assert HTMLSanitizer.sanitize_rich_text(html) == html
    end

    test "keeps <u> — the PT renderer emits it for underline marks" do
      html = "<p><u>emphasized</u></p>"

      assert HTMLSanitizer.sanitize_rich_text(html) == html
    end

    test "keeps the table scroll wrapper but strips every other div class (#475)" do
      html =
        ~s|<div class="kiln-table-wrap"><table><tbody><tr><td>a</td></tr></tbody></table></div>|

      assert HTMLSanitizer.sanitize_rich_text(html) == html

      assert HTMLSanitizer.sanitize_rich_text(~s|<div class="fixed inset-0">x</div>|) ==
               "<div>x</div>"
    end

    test "keeps accessible table markup, strips out-of-range spans (#475)" do
      html =
        "<table><thead><tr>" <>
          ~s(<th scope="col">H</th>) <>
          "</tr></thead><tbody><tr>" <>
          ~s(<td colspan="2" rowspan="3">a</td>) <>
          "</tr></tbody></table>"

      assert HTMLSanitizer.sanitize_rich_text(html) == html

      hostile =
        ~s(<table onclick="x"><tr><th scope="evil">H</th>) <>
          ~s(<td colspan="0" rowspan="99999">a</td></tr></table>)

      assert HTMLSanitizer.sanitize_rich_text(hostile) ==
               "<table><tr><th>H</th><td>a</td></tr></table>"
    end

    test "strips class values outside the highlight allowlists (#503)" do
      html =
        ~s(<pre class="fixed inset-0"><code class="language-x y">a</code>) <>
          ~s(<span class="btn btn-primary">b</span></pre>)

      assert HTMLSanitizer.sanitize_rich_text(html) ==
               "<pre><code>a</code><span>b</span></pre>"
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

    test "strips dangerous link schemes but keeps the text (#148)" do
      js = "javascript" <> @colon <> "alert(1)"
      data = "data" <> @colon <> "text/plain;base64,ABC"
      ftp = "ftp" <> @colon <> "//files.example/x"

      for href <- [js, data, ftp] do
        html = ["<p><a href=", @quote, href, @quote, ">click</a></p>"] |> Enum.join()
        sanitized = HTMLSanitizer.sanitize_rich_text(html)

        refute sanitized =~ href, "expected unsafe href #{href} to be stripped"
        assert sanitized =~ "click"
      end
    end

    # The scrubber used to carry its own *scheme* allowlist, which disagreed
    # with `safe_href/1` in both directions — every row here was a link that
    # survived one surface and died on the other. Now it delegates, so this
    # asserts the two verdicts are the same rather than asserting either one.
    test "the <a href> rule agrees with safe_href/1, case for case" do
      http = "http" <> @colon <> "//insecure.example"
      https = "https" <> @colon <> "//example.com"
      mailto = "mailto" <> @colon <> "hi@example.com"
      js = "javascript" <> @colon <> "alert(1)"

      cases = [
        # {href, kept?} — the four that used to disagree, marked.
        {"/blog/post", true},
        {"#section", true},
        {https, true},
        {mailto, true},
        # was: scrubber REJECTED, PT path served it happily
        {http, true},
        # was: scrubber ACCEPTED — reads same-origin, resolves off-site
        {"//evil.example.com", false},
        # was: scrubber ACCEPTED
        {"/a/../../etc/passwd", false},
        # was: scrubber REJECTED — a colon in the QUERY is not a scheme, and
        # the old regex read it as one, dropping ordinary internal links
        {"/redirect?to=" <> https, true},
        {js, false},
        {"tel" <> @colon <> "+15551234", false}
      ]

      for {href, kept?} <- cases do
        html = ["<p><a href=", @quote, href, @quote, ">t</a></p>"] |> Enum.join()
        sanitized = HTMLSanitizer.sanitize_rich_text(html)
        by_scrubber = sanitized =~ "href="
        by_safe_href = not is_nil(HTMLSanitizer.safe_href(href))

        assert by_scrubber == kept?, "scrubber verdict for #{href} changed"
        assert by_safe_href == kept?, "safe_href/1 verdict for #{href} changed"
        # The text always survives; only the anchor is dropped.
        assert sanitized =~ ">t</a>" or sanitized =~ "t"
      end
    end

    # The upstream URI scrubber carried a regex for entity-encoded protocol
    # separators. Delegating drops that regex, so prove the replacement fails
    # closed on the same inputs: `safe_href/1` is an allowlist of URL *shapes*,
    # and none of these parse into one.
    test "entity-encoded schemes are refused, not pattern-matched" do
      for href <- [
            "java&#58;script" <> @colon <> "alert(1)",
            "javascript&#58;alert(1)",
            "java&#0000058script" <> @colon <> "alert(1)",
            "&#47;&#47;evil.example.com",
            "JaVaScRiPt" <> @colon <> "alert(1)",
            "  javascript" <> @colon <> "alert(1)  "
          ] do
        html = ["<p><a href=", @quote, href, @quote, ">t</a></p>"] |> Enum.join()
        sanitized = HTMLSanitizer.sanitize_rich_text(html)

        refute sanitized =~ "href=", "expected #{href} to lose its href"
        assert sanitized =~ "t"
      end
    end

    test "target, rel and event handlers never survive on a link" do
      html =
        ["<p><a href=", @quote, "/ok", @quote, " target=", @quote, "_blank", @quote] ++
          [" rel=", @quote, "me", @quote, " onclick=", @quote, "alert(1)", @quote] ++
          [" id=", @quote, "x", @quote, ">t</a></p>"]

      assert HTMLSanitizer.sanitize_rich_text(Enum.join(html)) ==
               ["<p><a href=", @quote, "/ok", @quote, ">t</a></p>"] |> Enum.join()
    end
  end

  # `safe_href/1` had no describe of its own while it was one policy among two.
  # It is now *the* policy — the editor, the block cast, the PT renderer and the
  # legacy-HTML scrubber all defer to it — so its verdicts are pinned here.
  describe "safe_href/1" do
    test "accepts the four shapes Kiln stores, trimmed" do
      https = "https" <> @colon <> "//example.com/x"
      mailto = "mailto" <> @colon <> "hi@example.com"

      assert HTMLSanitizer.safe_href("/blog/post") == "/blog/post"
      assert HTMLSanitizer.safe_href("#section") == "#section"
      assert HTMLSanitizer.safe_href(https) == https
      assert HTMLSanitizer.safe_href(mailto) == mailto

      assert HTMLSanitizer.safe_href("http" <> @colon <> "//x.test") ==
               "http" <> @colon <> "//x.test"

      assert HTMLSanitizer.safe_href("  /blog/post  ") == "/blog/post"
    end

    test "refuses anything that isn't one of them" do
      for href <- [
            nil,
            "",
            "   ",
            42,
            # reads same-origin, resolves off-site
            "//evil.example.com",
            "/a/../../etc/passwd",
            "javascript" <> @colon <> "alert(1)",
            "data" <> @colon <> "text/html,x",
            "ftp" <> @colon <> "//files.test/x",
            "tel" <> @colon <> "+15551234",
            # a host is required — "https://" alone names nothing
            "https" <> @colon <> "//"
          ] do
        assert HTMLSanitizer.safe_href(href) == nil, "expected #{inspect(href)} to be refused"
      end
    end

    test "a mailto: smuggling a javascript: body is refused" do
      href = "mailto" <> @colon <> "a@b.test?body=javascript" <> @colon <> "alert(1)"
      assert HTMLSanitizer.safe_href(href) == nil
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
