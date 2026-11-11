Code.require_file("../../scripts/publish/docs.exs", __DIR__)

defmodule KilnCMS.Scripts.PublishDocsTest do
  @moduledoc """
  `scripts/publish_docs.exs` publishes the guides to kilncms.dev/docs, and
  builds the /docs index from mix.exs's ExDoc groups (#2157). It runs in CI
  without the application compiled, so its logic lives in
  `scripts/publish/docs.exs` and is loaded here directly. These tests read the
  real mix.exs and docs/, so a curation change that would put a plan, an
  audit or a maintainer page in the wrong place fails here rather than on the
  live site after the merge.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.HTMLSanitizer

  @public_groups [
    "Getting started",
    "Compare & migrate",
    "Authoring & editorial",
    "Modeling & extending",
    "APIs & headless",
    "Operations & deployment",
    "Security & access"
  ]
  @contributing "Contributing to Kiln"
  @maintainer_pages [
    "CONTRIBUTING.md",
    "docs/releasing.md",
    "docs/beta-testing.md",
    "docs/design-language.md",
    "docs/design-system.md",
    "docs/frontend-assets.md"
  ]

  setup_all do
    catalogue = PublishDocs.catalogue()

    %{
      catalogue: catalogue,
      index: catalogue |> PublishDocs.render_all() |> PublishDocs.index_html()
    }
  end

  describe "catalogue/1" do
    test "publishes only the public groups and Contributing to Kiln", %{catalogue: catalogue} do
      groups = catalogue |> Enum.map(& &1.group) |> Enum.uniq()

      assert groups == @public_groups ++ [@contributing]
    end

    test "puts the maintainer pages under Contributing to Kiln, and nothing else", %{
      catalogue: catalogue
    } do
      contributing = for doc <- catalogue, doc.group == @contributing, do: doc.path

      assert contributing == @maintainer_pages
      assert Enum.count(catalogue, &(&1.path in @maintainer_pages)) == length(@maintainer_pages)
    end

    test "keeps benchmarks public under its own title, and chain-fold-order off the site", %{
      catalogue: catalogue
    } do
      assert %{group: "Operations & deployment", title: "Benchmarks"} =
               Enum.find(catalogue, &(&1.path == "docs/benchmarks.md"))

      refute Enum.any?(catalogue, &(&1.path == "docs/chain-fold-order.md"))
    end

    test "publishes no plan, spike, audit, deploy checklist, archive or decision record", %{
      catalogue: catalogue
    } do
      internal =
        for %{path: path} <- catalogue,
            Path.basename(path) =~ ~r/(-plan|-spike)\.md$|^audit-|^deploy-p[0-9]/ or
              String.starts_with?(path, ["docs/changelog/", "docs/decisions/"]),
            do: path

      assert internal == []
    end

    test "every mix.exs group is classified, and every extra is in a group" do
      grouped = Enum.flat_map(PublishDocs.groups(), &elem(&1, 1))

      assert PublishDocs.extras() -- grouped == []
    end

    @tag :tmp_dir
    test "raises on a group it has not been told about", %{tmp_dir: dir} do
      mix_exs = Path.join(dir, "mix.exs")

      File.write!(mix_exs, """
      defmodule Fixture.MixProject do
        defp extras, do: ["docs/deploy.md": [], "docs/new.md": []]

        defp groups_for_extras do
          ["Operations & deployment": ["docs/deploy.md"], "Brand new": ["docs/new.md"]]
        end
      end
      """)

      assert_raise RuntimeError, ~r/"Brand new"/, fn -> PublishDocs.catalogue(mix_exs) end
    end
  end

  describe "docs/reading-paths.md" do
    setup %{catalogue: catalogue} do
      ast =
        "docs/reading-paths.md"
        |> File.read!()
        |> KilnPublish.Markdown.parse("docs/reading-paths.md")

      %{tracks: tracks(ast), slugs: Map.new(catalogue, &{&1.path, &1.slug})}
    end

    test "has exactly the Editor, Developer and Operator tracks", %{tracks: tracks} do
      assert Enum.map(tracks, &elem(&1, 0)) == ["Editor", "Developer", "Operator"]
    end

    test "lists four to eight guides per track", %{tracks: tracks} do
      for {role, nodes} <- tracks do
        items = for {list, _, items, _} <- nodes, list in ["ol", "ul"], item <- items, do: item

        assert length(items) in 4..8, "#{role} lists #{length(items)} guides"
      end
    end

    test "links only to published guides, each once", %{tracks: tracks, slugs: slugs} do
      paths =
        for {_role, nodes} <- tracks,
            href <- hrefs(nodes),
            do: repo_path(href)

      assert paths -- Map.keys(slugs) == []
      assert paths -- Enum.uniq(paths) == []
    end
  end

  # Resolved the way `PublishDocs.link/3` resolves it. An absolute or external
  # href stays as it is, so it fails the "published guides only" assertion.
  defp repo_path(href) do
    case KilnPublish.Markdown.repo_path(href, "docs/reading-paths.md") do
      {path, _fragment} -> path
      nil -> href
    end
  end

  describe "index_html/1" do
    test "leads with one Start here: the wedge, then the role tracks, then search", %{
      index: index
    } do
      assert length(String.split(index, "<h2>Start here</h2>")) == 2

      order =
        Enum.map(
          [
            "<h2>Start here</h2>",
            ~s(<a href="/docs/right-everywhere-provably">),
            "<h3>Editor</h3>",
            "<h3>Developer</h3>",
            "<h3>Operator</h3>",
            ~s(<a href="/search?category=documentation">Search the docs</a>),
            "<h2>Getting started</h2>"
          ],
          &position(index, &1)
        )

      assert order == Enum.sort(order)
      # Scoped to the guides by the category every guide is filed under
      # (#2457), and the only search link: no unscoped `/search` beside it.
      refute index =~ ~s(href="/search")
    end

    test "lists the reading paths only once, inlined, not as a Getting started link", %{
      index: index
    } do
      refute index =~ ~s(href="/docs/reading-paths")
      refute index =~ "<h2>Editor</h2>"
    end

    test "ends with Contributing to Kiln, after a rule", %{index: index} do
      [public, contributing] = String.split(index, "<hr>")

      assert contributing =~
               ~r{^<h2>Contributing to Kiln</h2><p>For people working on Kiln itself}

      assert contributing =~ ~s(href="/docs/releasing")
      refute public =~ ~s(href="/docs/releasing")
      refute public =~ ~s(href="/docs/contributing")
      assert public =~ ~s(href="/docs/releasing#updating-a-project-to-a-release")
      refute contributing =~ "<h2>Security"
    end

    test "drops Start here when neither guide is in the catalogue", %{catalogue: catalogue} do
      index =
        catalogue
        |> Enum.reject(
          &(&1.path in ["docs/right-everywhere-provably.md", "docs/reading-paths.md"])
        )
        |> PublishDocs.render_all()
        |> PublishDocs.index_html()

      refute index =~ "Start here"
      refute index =~ "<h3>"
      assert index =~ "<h2>Getting started</h2>"
    end

    test "keeps the role tracks when the wedge guide is gone", %{catalogue: catalogue} do
      index =
        catalogue
        |> Enum.reject(&(&1.path == "docs/right-everywhere-provably.md"))
        |> PublishDocs.render_all()
        |> PublishDocs.index_html()

      assert index =~ "<h2>Start here</h2><h3>Editor</h3>"
    end

    # The site stores the body through the rich-text cast, which sanitizes it
    # (K6): what the index relies on has to survive that, as it does live.
    test "survives the rich-text sanitizer the site applies", %{index: index} do
      clean = HTMLSanitizer.sanitize_rich_text(index)

      for tag <- ["<h2>Start here</h2>", "<h3>Editor</h3>", "<h3>Operator</h3>", "<hr", "<ol>"] do
        assert clean =~ tag, "sanitizer dropped #{tag}"
      end

      for href <- [
            "/search?category=documentation",
            "/docs/editor-shortcuts",
            "/docs/releasing#updating-a-project-to-a-release",
            "/docs/contributing"
          ] do
        assert clean =~ ~s(href="#{href}"), "sanitizer dropped the link to #{href}"
      end
    end
  end

  describe "the editorial workflow guide (#2158)" do
    @guide "docs/editorial-workflow.md"

    test "leads Authoring & editorial, and the Editor track", %{catalogue: catalogue} do
      assert [%{path: @guide, title: "The editorial workflow", slug: "editorial-workflow"} | _] =
               Enum.filter(catalogue, &(&1.group == "Authoring & editorial"))

      assert "docs/reading-paths.md" |> File.read!() |> String.split("## Editor") |> Enum.at(1) =~
               ~r/\A[^\[]*\n1\. \[The editorial workflow\]\(editorial-workflow\.md\)/
    end

    test "publishes its screenshots as image blocks between its prose", %{catalogue: catalogue} do
      [doc] = catalogue |> Enum.filter(&(&1.path == @guide)) |> PublishDocs.render_all()

      images = for {:image, image} <- doc.blocks, do: image
      assert length(images) >= 4
      assert Enum.all?(images, &String.starts_with?(&1.src, "docs/images/editorial-workflow/"))
      assert Enum.all?(images, &(String.trim(&1.alt) != ""))
      assert PublishDocs.validate_images!([doc]) == :ok
      assert match?([{:html, _} | _], doc.blocks)
      refute Enum.any?(doc.blocks, &match?({:html, ""}, &1))

      # --dry-run's page loads them from GitHub.
      assert doc.html =~
               ~s(<img src="https://raw.githubusercontent.com/The-Verscienta/kiln_cms/main/docs/images/editorial-workflow/)
    end

    test "every other guide is one rich_text block, as it was", %{catalogue: catalogue} do
      for doc <- PublishDocs.render_all(catalogue), doc.path != @guide do
        assert [{:html, _}] = doc.blocks, "#{doc.path} grew a block"
      end
    end

    test "a changed screenshot selects the guides that show it, and a dry run sends nothing" do
      image = "docs/images/editorial-workflow/1-content-list.webp"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PublishDocs.main(["--dry-run", image], fn -> flunk("a dry run built a client") end)
        end)

      assert output =~ ~r/^1 of \d+ guides selected/
      assert output =~ "/docs/editorial-workflow  The editorial workflow"
    end

    @tag :tmp_dir
    test "a missing image or an empty alt stops the run before anything is sent", %{tmp_dir: dir} do
      doc =
        fixture_doc(dir, [{:image, %{src: Path.join(dir, "gone.webp"), alt: "A", caption: nil}}])

      assert_raise RuntimeError, ~r/gone\.webp does not exist/, fn ->
        PublishDocs.validate_images!([doc])
      end

      File.write!(Path.join(dir, "here.webp"), "RIFF")

      doc =
        fixture_doc(dir, [{:image, %{src: Path.join(dir, "here.webp"), alt: " ", caption: nil}}])

      assert_raise RuntimeError, ~r/has no alt text/, fn ->
        PublishDocs.validate_images!([doc])
      end
    end

    @tag :tmp_dir
    test "uploads each screenshot once, then writes image blocks pointing at it", %{tmp_dir: dir} do
      path = Path.join(dir, "shot.webp")
      File.write!(path, "RIFF shot")

      doc =
        fixture_doc(dir, [
          {:html, "<p>Before</p>"},
          {:image, %{src: path, alt: "The shot", caption: nil}},
          {:image, %{src: path, alt: "The shot again", caption: nil}}
        ])

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert PublishDocs.publish_all([doc], [doc], fake_site(:accepts_upload)) == :ok
        end)

      assert out =~ "uploaded"
      assert_received {:request, "POST", "/api/media", _}
      refute_received {:request, "POST", "/api/media", _}

      assert_received {:request, "POST", "/api/json/entries",
                       %{"data" => %{"attributes" => attrs}}}

      assert attrs["block_tree"] == [
               %{"_type" => "rich_text", "legacy_html" => "<p>Before</p>"},
               %{
                 "_type" => "image",
                 "media_id" => "m1",
                 "url" => "/media/m1",
                 "alt" => "The shot"
               },
               %{
                 "_type" => "image",
                 "media_id" => "m1",
                 "url" => "/media/m1",
                 "alt" => "The shot again"
               }
             ]
    end

    @tag :tmp_dir
    test "a refused upload publishes no guide", %{tmp_dir: dir} do
      path = Path.join(dir, "shot.webp")
      File.write!(path, "RIFF shot")
      doc = fixture_doc(dir, [{:image, %{src: path, alt: "The shot", caption: nil}}])

      ExUnit.CaptureIO.capture_io(fn ->
        assert_raise RuntimeError, ~r/no guide was published.*422/s, fn ->
          PublishDocs.publish_all([doc], [doc], fake_site(:refuses_upload))
        end
      end)

      refute_received {:request, _, "/api/json/entries", _}
      refute_received {:request, _, "/api/json/pages", _}
    end
  end

  # #2457: the index's search link is `/search?category=documentation`, so
  # every guide has to carry that category for the link to find it.
  describe "the Documentation category" do
    @tag :tmp_dir
    test "is looked up once and written on every guide, on create and update", %{
      tmp_dir: dir
    } do
      docs = [fixture_doc(dir, [{:html, "<p>A</p>"}]), fixture_doc(dir, [{:html, "<p>B</p>"}])]

      ExUnit.CaptureIO.capture_io(fn ->
        assert PublishDocs.publish_all(docs, docs, fake_site(:guides_exist)) == :ok
      end)

      assert_received {:request, "GET", "/api/json/categories/by-slug/documentation", nil}
      refute_received {:request, "GET", "/api/json/categories/by-slug/documentation", _}

      # Both guides already exist: an update still sends the category, which is
      # what overwrites one an editor set on the site.
      for _doc <- docs do
        assert_received {:request, "PATCH", "/api/json/entries/e1",
                         %{"data" => %{"attributes" => %{"category_id" => "c1"}}}}
      end

      # The index page is not a guide, and is not filed under it.
      assert_received {:request, "POST", "/api/json/pages", %{"data" => %{"attributes" => page}}}
      refute Map.has_key?(page, "category_id")
    end

    @tag :tmp_dir
    test "a new guide is created with it", %{tmp_dir: dir} do
      doc = fixture_doc(dir, [{:html, "<p>A</p>"}])

      ExUnit.CaptureIO.capture_io(fn ->
        assert PublishDocs.publish_all([doc], [doc], fake_site(:accepts_upload)) == :ok
      end)

      assert_received {:request, "POST", "/api/json/entries",
                       %{"data" => %{"attributes" => %{"category_id" => "c1"}}}}
    end

    @tag :tmp_dir
    test "a site without it publishes nothing, and says how to create it", %{tmp_dir: dir} do
      doc = fixture_doc(dir, [{:html, "<p>A</p>"}])

      assert_raise RuntimeError, ~r{"documentation" category.*/editor/taxonomy}s, fn ->
        PublishDocs.publish_all([doc], [doc], fake_site(:no_category))
      end

      refute_received {:request, _, "/api/json/entries", _}
      refute_received {:request, _, "/api/json/pages", _}
      refute_received {:request, "POST", "/api/media", _}
    end
  end

  defp fixture_doc(dir, blocks) do
    %{
      path: Path.join(dir, "guide.md"),
      slug: "guide",
      title: "Guide",
      group: "Authoring & editorial",
      seo_description: nil,
      blocks: blocks,
      html: PublishDocs.html(blocks)
    }
  end

  # A site that answers the publisher's requests, recording each as
  # `{:request, method, path, decoded_json_body | nil}`.
  defp fake_site(mode) do
    KilnPublish.API.client("https://site.test/", "key")
    |> Req.merge(
      plug: fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        json = if raw != "" and not String.starts_with?(raw, "--"), do: Jason.decode!(raw)
        send(self(), {:request, conn.method, conn.request_path, json})

        {status, body} = respond(conn.method, conn.request_path, mode)
        Plug.Conn.send_resp(conn, status, Jason.encode!(body))
      end
    )
  end

  defp respond("GET", "/api/json/type-definitions/by-name/doc", _mode),
    do: {200, %{"data" => %{"id" => "t1"}}}

  defp respond("GET", "/api/json/categories/by-slug/documentation", :no_category),
    do: {404, %{"errors" => [%{"code" => "not_found"}]}}

  defp respond("GET", "/api/json/categories/by-slug/documentation", _mode),
    do: {200, %{"data" => %{"id" => "c1"}}}

  # Every guide already exists (the index page does not).
  defp respond("GET", "/api/json/entries", :guides_exist),
    do: {200, %{"data" => [%{"id" => "e1", "attributes" => %{"state" => "published"}}]}}

  defp respond("PATCH", "/api/json/entries/e1", :guides_exist),
    do: {200, %{"data" => %{"id" => "e1", "attributes" => %{"state" => "published"}}}}

  defp respond("POST", "/api/media", :refuses_upload),
    do: {422, %{"errors" => [%{"code" => "strip_failed"}]}}

  defp respond("POST", "/api/media", _mode),
    do: {201, %{"data" => %{"id" => "m1", "attributes" => %{"url" => "/media/m1"}}}}

  # Nothing exists yet: no media item, no guide, no index page.
  defp respond("GET", _path, _mode), do: {200, %{"data" => []}}

  defp respond("POST", _path, _mode),
    do: {201, %{"data" => %{"id" => "r1", "attributes" => %{"state" => "draft"}}}}

  defp respond("PATCH", _path, _mode),
    do: {200, %{"data" => %{"id" => "r1", "attributes" => %{"state" => "published"}}}}

  # `[{role, nodes}]`: each `##` heading and the nodes under it.
  defp tracks(ast) do
    ast
    |> Enum.drop_while(&(not match?({"h2", _, _, _}, &1)))
    |> Enum.chunk_while(
      nil,
      fn
        {"h2", _, title, _}, nil ->
          {:cont, {KilnPublish.Markdown.plain_text(title), []}}

        {"h2", _, title, _}, {role, nodes} ->
          {:cont, {role, Enum.reverse(nodes)}, {KilnPublish.Markdown.plain_text(title), []}}

        node, {role, nodes} ->
          {:cont, {role, [node | nodes]}}
      end,
      fn {role, nodes} -> {:cont, {role, Enum.reverse(nodes)}, nil} end
    )
  end

  defp hrefs(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &hrefs/1)

  defp hrefs({"a", attrs, children, _}) do
    for({"href", href} <- attrs, do: href) ++ hrefs(children)
  end

  defp hrefs({_tag, _attrs, children, _}), do: hrefs(children)
  defp hrefs(_text), do: []

  defp position(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> flunk("index has no #{needle}")
    end
  end
end
