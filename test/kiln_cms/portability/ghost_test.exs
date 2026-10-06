defmodule KilnCMS.Portability.GhostTest do
  @moduledoc """
  Reading a Ghost JSON export (#1876). Pure parsing — no database, no network.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.GhostFixture
  alias KilnCMS.Portability.Ghost

  @site "https://blog.example.com"

  setup do
    {:ok, parsed} = Ghost.parse(GhostFixture.json(), site_url: @site <> "/")
    %{parsed: parsed, records: parsed.records}
  end

  defp record(records, slug), do: Enum.find(records, &(&1.slug == slug))

  describe "the export" do
    test "reads the site, its version and its authors", %{parsed: parsed} do
      assert parsed.site == %{title: "Old Ghost Blog", url: @site, version: "6.68.0"}
      assert [%{login: "jo", email: "jo@old.example.com", name: "Jo Example"}] = parsed.authors
    end

    test "posts and pages are told apart by type", %{records: records} do
      assert record(records, "hello-world").kind == :post
      assert record(records, "about").kind == :page
      assert length(records) == 6
    end

    test "JSON that is not a Ghost export is refused" do
      assert Ghost.parse(~s({"records": []})) == {:error, :not_a_ghost_export}
      assert {:error, {:malformed_json, _}} = Ghost.parse("{not json")
    end

    test "__GHOST_URL__ with no site address is refused, not imported with broken images" do
      assert Ghost.parse(GhostFixture.json()) == {:error, :site_url_required}
    end

    test "an export without the placeholder needs no site address" do
      json = GhostFixture.json(posts: [GhostFixture.post("p1", "plain", "Plain")])

      assert {:ok, %{records: [%{slug: "plain"}]}} = Ghost.parse(json)
    end
  end

  describe "body" do
    test "rendered HTML becomes blocks, with the placeholder expanded", %{records: records} do
      post = record(records, "hello-world")

      prose =
        post.blocks
        |> Enum.filter(&(&1["type"] == "rich_text"))
        |> Enum.map_join("\n", &PortableText.to_plain_text(&1["value"]["body"]))

      assert prose =~ "First paragraph with bold."
      assert post.image_urls == [@site <> "/content/images/2026/01/pic.jpg"]
    end

    test "square brackets are prose, not WordPress shortcodes", %{records: records} do
      text =
        records
        |> record("hello-world")
        |> Map.fetch!(:blocks)
        |> Enum.filter(&(&1["type"] == "rich_text"))
        |> Enum.map_join(&PortableText.to_plain_text(&1["value"]["body"]))

      assert text =~ "[not a shortcode]"
    end

    test "every image in a gallery card survives" do
      gallery =
        ~s(<figure class="kg-card kg-gallery-card"><div class="kg-gallery-container">) <>
          ~s(<div class="kg-gallery-row"><div class="kg-gallery-image"><img src="https://x.test/1.jpg"></div>) <>
          ~s(<div class="kg-gallery-image"><img src="https://x.test/2.jpg"></div></div>) <>
          ~s(<div class="kg-gallery-row"><div class="kg-gallery-image"><img src="https://x.test/3.jpg"></div></div>) <>
          ~s(</div></figure>)

      json =
        GhostFixture.json(posts: [GhostFixture.post("g", "gallery", "Gallery", html: gallery)])

      {:ok, %{records: [post]}} = Ghost.parse(json)

      assert post.image_urls == [
               "https://x.test/1.jpg",
               "https://x.test/2.jpg",
               "https://x.test/3.jpg"
             ]
    end

    test "a mobiledoc-only post is reported, not imported empty" do
      old = GhostFixture.post("m", "old", "Old post", html: nil, lexical: nil, mobiledoc: "{}")
      json = GhostFixture.json(posts: [old, GhostFixture.post("n", "new", "New post")])

      {:ok, parsed} = Ghost.parse(json)

      assert Enum.map(parsed.records, & &1.slug) == ["new"]
      assert [%{title: "Old post", reason: reason}] = parsed.unreadable
      assert reason =~ "mobiledoc"
    end
  end

  describe "metadata" do
    test "SEO comes from posts_meta; canonical_url is never carried", %{records: records} do
      assert record(records, "hello-world").attrs == %{
               "seo_title" => "Hello, SEO",
               "seo_description" => "The search snippet."
             }
    end

    test "the pre-Ghost-4 SEO columns on the post row are read too" do
      old = GhostFixture.post("o", "old-seo", "Old SEO", meta_description: "On the row.")
      {:ok, %{records: [post]}} = Ghost.parse(GhostFixture.json(posts: [old]))

      assert post.attrs == %{"seo_description" => "On the row."}
    end

    test "the feature image is an attachment keyed by its URL, alt included", %{
      parsed: parsed,
      records: records
    } do
      post = record(records, "hello-world")
      cover = @site <> "/content/images/2026/01/cover.jpg"

      assert post.featured_source_id == cover
      assert [%{source_id: ^cover, url: ^cover, alt: "A kiln at dusk"}] = parsed.attachments
    end

    test "public tags in sort order; internal # tags dropped; no category", %{records: records} do
      post = record(records, "hello-world")

      assert Enum.map(post.tags, & &1.slug) == ["news", "how-to"]
      assert post.categories == []
    end

    test "the first author is the byline", %{records: records} do
      assert record(records, "hello-world").author == "jo"
    end

    test "excerpt, date and old permalink", %{records: records} do
      post = record(records, "hello-world")

      assert post.excerpt == "A short summary."
      assert post.published_at == ~U[2026-01-15 09:30:00Z]
      assert post.source_url == "/hello-world/"
    end
  end

  describe "status and visibility" do
    test "only published is live", %{records: records} do
      assert record(records, "hello-world").state == :published
      assert record(records, "a-draft").state == :draft
    end

    test "a scheduled post lands as a draft, its date kept, with a note", %{records: records} do
      post = record(records, "coming-soon")

      assert post.state == :draft
      assert post.published_at == ~U[2027-01-01 00:00:00Z]
      assert post.note =~ "scheduled"
    end

    test "an email-only post is not published to the site", %{records: records} do
      post = record(records, "weekly-letter")

      assert post.state == :draft
      assert post.note =~ "email-only"
    end

    test "the older `sent` status is email-only too" do
      sent = GhostFixture.post("s", "sent", "Sent", status: "sent")
      {:ok, %{records: [post]}} = Ghost.parse(GhostFixture.json(posts: [sent]))

      assert post.state == :draft
    end

    test "a members-only post stays gated", %{records: records} do
      post = record(records, "members-only")

      assert post.state == :published
      assert post.attrs["audience"] == :member
    end

    test "a public post sends no audience at all", %{records: records} do
      refute Map.has_key?(record(records, "hello-world").attrs, "audience")
    end
  end

  describe "older and odder exports (review of #1876)" do
    test "a Ghost 1/2 export, with a `page` boolean and no `type`, still imports" do
      post =
        GhostFixture.post("a", "a-post", "A post") |> Map.delete("type") |> Map.put("page", false)

      page =
        GhostFixture.post("b", "a-page", "A page") |> Map.delete("type") |> Map.put("page", true)

      {:ok, parsed} = Ghost.parse(GhostFixture.json(posts: [post, page]))

      assert Enum.map(parsed.records, &{&1.slug, &1.kind}) == [
               {"a-post", :post},
               {"a-page", :page}
             ]
    end

    test "root-relative image paths need the site address, and are completed by it" do
      old =
        GhostFixture.post("o", "old", "Old",
          html: ~s(<p><img src="/content/images/2019/01/a.jpg"></p>),
          feature_image: "/content/images/2019/01/cover.jpg"
        )

      json = GhostFixture.json(posts: [old])

      assert Ghost.parse(json) == {:error, :site_url_required}

      {:ok, %{records: [post]}} = Ghost.parse(json, site_url: @site)

      assert post.image_urls == [@site <> "/content/images/2019/01/a.jpg"]
      assert post.featured_source_id == @site <> "/content/images/2019/01/cover.jpg"
    end

    test "a protocol-relative image is left alone" do
      cdn = GhostFixture.post("c", "cdn", "CDN", html: ~s(<p><img src="//cdn.test/a.jpg"></p>))

      assert {:ok, _parsed} = Ghost.parse(GhostFixture.json(posts: [cdn]))
    end

    test "links to the site's own pages become root-relative; images stay absolute" do
      html =
        ~s(<p>See <a href="__GHOST_URL__/other-post/">this</a> and <a href="__GHOST_URL__">home</a>.</p>) <>
          ~s(<p><img src="__GHOST_URL__/content/images/a.jpg"></p>)

      {:ok, %{records: [post]}} =
        Ghost.parse(
          GhostFixture.json(posts: [GhostFixture.post("l", "links", "Links", html: html)]),
          site_url: @site
        )

      hrefs =
        for %{"type" => "rich_text", "value" => %{"body" => body}} <- post.blocks,
            %{"markDefs" => defs} <- body,
            %{"href" => href} <- defs,
            do: href

      assert hrefs == ["/other-post/", "/"]
      assert post.image_urls == [@site <> "/content/images/a.jpg"]
    end

    test "video, audio and file cards are reported, not lost silently" do
      html =
        ~s(<figure class="kg-card kg-video-card"><video src="v.mp4"></video></figure>) <>
          ~s(<div class="kg-card kg-file-card"><a href="f.pdf">f</a></div>)

      {:ok, %{records: [post]}} =
        Ghost.parse(
          GhostFixture.json(posts: [GhostFixture.post("v", "video", "Video", html: html)])
        )

      assert post.note =~ "file download, video cards"
    end

    test "a bookmark card is a link to the bookmarked page, not its favicon" do
      html =
        ~s(<figure class="kg-card kg-bookmark-card"><a class="kg-bookmark-container" href="https://x.test/page">) <>
          ~s(<div class="kg-bookmark-content"><div class="kg-bookmark-title">The page</div>) <>
          ~s(<div class="kg-bookmark-metadata"><img class="kg-bookmark-icon" src="https://x.test/fav.png"></div></div>) <>
          ~s(<div class="kg-bookmark-thumbnail"><img src="https://x.test/thumb.jpg"></div></a></figure>)

      {:ok, %{records: [post]}} =
        Ghost.parse(
          GhostFixture.json(posts: [GhostFixture.post("k", "bookmark", "Bookmark", html: html)])
        )

      assert post.image_urls == []
      assert [%{"type" => "rich_text", "value" => %{"body" => body}}] = post.blocks
      assert PortableText.to_plain_text(body) =~ "The page"
      assert [%{"href" => "https://x.test/page"}] = Enum.flat_map(body, & &1["markDefs"])
    end

    test "a paid post with no :paid audience is gated to members, with a note" do
      paid = GhostFixture.post("p", "paid", "Paid", visibility: "paid")
      {:ok, %{records: [post]}} = Ghost.parse(GhostFixture.json(posts: [paid]))

      assert post.attrs["audience"] == :member
      assert post.note =~ "paid-only in Ghost"
    end
  end

  describe "parse_file/2" do
    @tag :tmp_dir
    test "reads a file", %{tmp_dir: dir} do
      path = Path.join(dir, "export.json")
      File.write!(path, GhostFixture.json())

      assert {:ok, %{records: [_ | _]}} = Ghost.parse_file(path, site_url: @site)
    end

    test "a missing file is an error, not a crash" do
      assert {:error, {:unreadable_file, :enoent}} = Ghost.parse_file("/nonexistent/export.json")
    end
  end
end
