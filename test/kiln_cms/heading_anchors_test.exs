defmodule KilnCMS.HeadingAnchorsTest do
  @moduledoc "Heading ids for `#section` links, slugged the way GitHub does."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.{PortableText, RichText}
  alias KilnCMS.HeadingAnchors

  doctest HeadingAnchors

  describe "slug/1" do
    # Each pair is a heading and the fragment GitHub gives it.
    test "matches GitHub's slugs" do
      for {text, slug} <- [
            {"5. What shipped: the PWA", "5-what-shipped-the-pwa"},
            {"2. Funnels — definitions only, counts derived",
             "2-funnels--definitions-only-counts-derived"},
            {"C++ & Rust", "c--rust"},
            {"snake_case and kebab-case", "snake_case-and-kebab-case"},
            {"Ünïcödé Straße", "ünïcödé-straße"},
            {"Release 🚀 notes", "release--notes"},
            {"  Padded  ", "padded"}
          ] do
        assert HeadingAnchors.slug(text) == slug, inspect(text)
      end
    end

    test "nothing left means no id" do
      assert HeadingAnchors.slug("?!…") == nil
      assert HeadingAnchors.slug("") == nil
      assert HeadingAnchors.slug(nil) == nil
    end
  end

  describe "put_ids/1" do
    test "ids every bare heading from its text content" do
      assert HeadingAnchors.put_ids("<h2>Hello <em>big</em> world</h2><p>x</p><h3>Next</h3>") ==
               ~s(<h2 id="hello-big-world">Hello <em>big</em> world</h2><p>x</p><h3 id="next">Next</h3>)
    end

    test "numbers repeats in document order, as github-slugger does" do
      assert HeadingAnchors.put_ids("<h2>Setup</h2><h3>Setup</h3><h2>Setup-1</h2>") ==
               ~s(<h2 id="setup">Setup</h2><h3 id="setup-1">Setup</h3>) <>
                 ~s(<h2 id="setup-1-1">Setup-1</h2>)
    end

    test "entities: named ones are punctuation and drop, numeric ones decode" do
      assert HeadingAnchors.put_ids("<h2>Q&amp;A &lt;tags&gt;</h2>") ==
               ~s(<h2 id="qa-tags">Q&amp;A &lt;tags&gt;</h2>)

      assert HeadingAnchors.put_ids("<h2>Caf&#233; &#x2014; menu</h2>") ==
               ~s(<h2 id="café--menu">Caf&#233; &#x2014; menu</h2>)
    end

    test "leaves a heading that already has attributes, and one with no slug" do
      html = ~s(<h2 class="x">Kept</h2><h2>!!!</h2>)
      assert HeadingAnchors.put_ids(html) == html
    end

    test "HTML without headings comes back as-is" do
      assert HeadingAnchors.put_ids("<p>no headings</p>") == "<p>no headings</p>"
      assert HeadingAnchors.put_ids("") == ""
    end

    # What public delivery feeds it: both rich-text renderers' output.
    test "takes Portable Text and scrubbed legacy HTML as they render" do
      pt = [%{"_type" => "block", "style" => "h2", "children" => [%{"text" => "Install & run"}]}]
      assert HeadingAnchors.put_ids(PortableText.to_html(pt)) =~ ~s(<h2 id="install--run">)

      # An author-written id is scrubbed first; the slug replaces it.
      legacy = %RichText{legacy_html: ~s{<h2 id="evil" onclick="x()">1. Start</h2>}}

      assert legacy |> RichText.render(:web) |> HeadingAnchors.put_ids() ==
               ~s(<h2 id="1-start">1. Start</h2>)
    end
  end

  describe "anchor_tree/1" do
    test "one numbering across heading blocks, prose and columns, in page order" do
      tree = [
        %{type: "heading", content: "Overview"},
        %{type: "rich_text", content: "<h2>Overview</h2><p>x</p><h3>Details</h3>"},
        %{
          type: "columns",
          columns: [
            %{blocks: [%{type: "heading", content: "Details"}]},
            %{blocks: [%{type: "rich_text", content: "<h4>Overview</h4>"}]}
          ]
        },
        %{type: "image", content: "/a.png"}
      ]

      assert [
               %{anchor: "overview"},
               %{
                 content:
                   ~s(<h2 id="overview-1">Overview</h2><p>x</p><h3 id="details">Details</h3>)
               },
               %{columns: [%{blocks: [%{anchor: "details-1"}]}, %{blocks: [%{content: col2}]}]},
               %{type: "image", content: "/a.png"} = image
             ] = HeadingAnchors.anchor_tree(tree)

      assert col2 == ~s(<h4 id="overview-2">Overview</h4>)
      refute Map.has_key?(image, :anchor)
    end

    test "a heading block with no slug gets no anchor" do
      assert [block] = HeadingAnchors.anchor_tree([%{type: "heading", content: "!!"}])
      refute Map.has_key?(block, :anchor)
    end
  end
end
