defmodule KilnCMS.Docs.GuideImagesTest do
  @moduledoc """
  Every guide's screenshots share one budget (#2460): a guide read in a few
  minutes, whose pictures load quickly on GitHub, in ExDoc and on kilncms.dev.

  A guide in `mix.exs` extras keeps its screenshots in `docs/images/<guide>/`,
  named after its own basename, and links them relative to `docs/`
  (`![alt](images/editorial-workflow/2-draft.webp)`), each on a paragraph of
  its own. For every such guide:

    * each image exists, has alt text, is a WebP file, is at most
      1600 px wide and at most 90 KB;
    * the guide has at most 8 images, 600 KB in all;
    * every file in its folder is one the guide shows.

  And for `docs/images/` itself: nothing sits directly in it, and every folder
  in it belongs to a guide in the extras. So a second guide with screenshots
  is checked the moment it links one, with nothing to copy.

  Images at an `http(s)` URL (the "Deploy to Render" badge) are not ours to
  budget, and the publisher shows them as a link. An image inside a sentence
  or a link, or an HTML `<img>`, is refused: kilncms.dev would publish only
  its alt text, or nothing.

  The Markdown is parsed with `EarmarkParser`, as the publisher and ExDoc
  parse it, so an image written inside code is not an image.
  """
  use ExUnit.Case, async: true

  @extras Mix.Project.config()[:docs][:extras] |> Enum.map(fn {path, _} -> to_string(path) end)

  # Budgets: a guide read in five minutes, whose pictures load quickly.
  @max_images 8
  @max_image_bytes 90_000
  @max_guide_bytes 600_000
  @max_width 1600

  test "every guide's screenshots are described WebP files within budget, none left over" do
    %{problems: problems} = check(File.cwd!(), @extras)

    assert problems == [],
           """
           Guide screenshots that break the shared budget:

           #{Enum.join(problems, "\n")}

           CONTRIBUTING.md, "Adding screenshots to a guide", has the rules;
           `scripts/optimize_home_images.sh docs <guide>` re-derives the files.
           """
  end

  # Without a guide to check, a broken parser would read as "all good".
  test "finds the guides that have screenshots" do
    assert "docs/editorial-workflow.md" in check(File.cwd!(), @extras).guides
  end

  @not_block " is not published as an image: it is not alone in a top-level paragraph " <>
               "(kilncms.dev would publish only its alt text)"

  @tag :tmp_dir
  test "the check can fail", %{tmp_dir: root} do
    write!(root, "docs/ok.md", """
    # OK

    ![A described screen.](images/ok/1-shot.webp)

    [![Badge](https://example.com/badge.svg)](https://example.com)

    `![not an image](images/ok/nope.webp)`
    """)

    webp!(root, "docs/images/ok/1-shot.webp", 800)

    write!(root, "docs/bad.md", """
    # Bad

    ![](images/bad/1-no-alt.webp)

    ![Too wide.](images/bad/2-wide.webp)

    ![Not a WebP.](images/bad/3-png.webp)

    ![Gone.](images/bad/4-gone.webp)

    ![Elsewhere.](images/ok/1-shot.webp)

    In a sentence ![inline](images/bad/5-inline.webp) here.

    <img src="images/bad/6-html.webp" alt="HTML">

    - ![In a list.](images/bad/8-list.webp)

    > ![In a quote.](images/bad/9-quote.webp)

    ![Rooted.](/docs/images/bad/1-no-alt.webp)

    ![Queried.](images/bad/1-no-alt.webp?v=2)
    """)

    webp!(root, "docs/images/bad/1-no-alt.webp", 100)
    webp!(root, "docs/images/bad/2-wide.webp", @max_width + 1)
    write!(root, "docs/images/bad/3-png.webp", "\x89PNG\r\n\x1a\n")
    webp!(root, "docs/images/bad/5-inline.webp", 100)
    webp!(root, "docs/images/bad/6-html.webp", 100)
    webp!(root, "docs/images/bad/7-unused.webp", 100)
    webp!(root, "docs/images/bad/8-list.webp", 100)
    webp!(root, "docs/images/bad/9-quote.webp", 100)

    write!(root, "docs/nested/deep.md", "![Deep.](../images/deep/1.webp)\n")
    webp!(root, "docs/images/deep/1.webp", 100)

    write!(
      root,
      "docs/many.md",
      Enum.map_join(1..9, "\n\n", &"![Shot #{&1}.](images/many/#{&1}.webp)")
    )

    for n <- 1..9, do: webp!(root, "docs/images/many/#{n}.webp", 100)

    # Not every extra is `.md`; its folder is named after the basename all the same.
    write!(root, "docs/cheat.cheatmd", "![A described card.](images/cheat/1.webp)\n")
    webp!(root, "docs/images/cheat/1.webp", 100)

    write!(root, "docs/images/stray.webp", "")
    webp!(root, "docs/images/orphan/1.webp", 100)

    %{guides: guides, problems: problems} =
      check(root, ~w(docs/ok.md docs/bad.md docs/nested/deep.md docs/many.md docs/cheat.cheatmd))

    assert guides ==
             ~w(docs/ok.md docs/bad.md docs/nested/deep.md docs/many.md docs/cheat.cheatmd)

    assert problems == [
             "  docs/bad.md: images/bad/1-no-alt.webp has no alt text",
             "  docs/bad.md: images/bad/2-wide.webp is 1601 px wide, over #{@max_width}",
             "  docs/bad.md: images/bad/3-png.webp is not a WebP file",
             "  docs/bad.md: images/bad/4-gone.webp does not exist",
             "  docs/bad.md: images/ok/1-shot.webp is not in docs/images/bad/",
             "  docs/bad.md: images/bad/5-inline.webp" <> @not_block,
             "  docs/bad.md: an HTML <img> is not checked or published; " <>
               "write ![alt](images/bad/…) on a paragraph of its own",
             "  docs/bad.md: images/bad/8-list.webp" <> @not_block,
             "  docs/bad.md: images/bad/9-quote.webp" <> @not_block,
             "  docs/bad.md: /docs/images/bad/1-no-alt.webp is not a file in the repo " <>
               "(kilncms.dev would publish only its alt text)",
             "  docs/bad.md: images/bad/1-no-alt.webp?v=2 does not exist",
             "  docs/nested/deep.md: only a guide directly under docs/ may have screenshots " <>
               "(in docs/images/deep/)",
             "  docs/many.md: 9 images, over #{@max_images}",
             "  docs/images/bad/7-unused.webp is not shown by docs/bad.md",
             "  docs/images/deep/ belongs to no guide: no docs/deep.* is in mix.exs extras",
             "  docs/images/orphan/ belongs to no guide: no docs/orphan.* is in mix.exs extras",
             "  docs/images/stray.webp belongs to no guide: put it in docs/images/<guide>/"
           ]
  end

  @tag :tmp_dir
  test "the byte budgets can fail", %{tmp_dir: root} do
    # Random pixels do not compress, so each file is large at a small width.
    write!(
      root,
      "docs/heavy.md",
      Enum.map_join(1..8, "\n\n", &"![Shot #{&1}.](images/heavy/#{&1}.webp)")
    )

    for n <- 1..8, do: noise_webp!(root, "docs/images/heavy/#{n}.webp")

    sizes = for n <- 1..8, do: File.stat!(Path.join(root, "docs/images/heavy/#{n}.webp")).size

    assert Enum.all?(sizes, &(&1 > @max_image_bytes)),
           "the fixture is too small: #{inspect(sizes)}"

    %{problems: problems} = check(root, ["docs/heavy.md"])

    assert "  docs/heavy.md: images/heavy/1.webp is #{hd(sizes)} bytes, over #{@max_image_bytes}" in problems

    assert "  docs/heavy.md: #{Enum.sum(sizes)} bytes of images, over #{@max_guide_bytes}" in problems
  end

  # ── The check ──────────────────────────────────────────────────────────────

  # `%{guides: [guide], problems: [line]}` for the extras under `root`, where
  # `guides` are those that show at least one image of their own.
  defp check(root, extras) do
    shown = Map.new(extras, &{&1, images(root, &1)})
    guides = for extra <- extras, shown[extra] != [], do: extra

    problems =
      Enum.flat_map(guides, &guide_problems(root, &1, shown[&1])) ++
        folder_problems(root, extras, shown)

    %{guides: guides, problems: problems}
  end

  defp guide_problems(root, guide, images) do
    folder = folder(guide)

    placement =
      if Path.dirname(guide) == "docs",
        do: [],
        else: ["only a guide directly under docs/ may have screenshots (in #{folder}/)"]

    per_image = Enum.flat_map(images, &image_problems(root, guide, folder, &1))

    files =
      for %{path: path} <- images,
          path != nil and File.regular?(Path.join(root, path)),
          uniq: true,
          do: path

    bytes = files |> Enum.map(&File.stat!(Path.join(root, &1)).size) |> Enum.sum()

    budget =
      if(length(files) > @max_images,
        do: ["#{length(files)} images, over #{@max_images}"],
        else: []
      ) ++
        if bytes > @max_guide_bytes,
          do: ["#{bytes} bytes of images, over #{@max_guide_bytes}"],
          else: []

    for problem <- placement ++ per_image ++ budget, do: "  #{guide}: #{problem}"
  end

  defp image_problems(_root, guide, _folder, %{html?: true}),
    do: [
      "an HTML <img> is not checked or published; write ![alt](images/#{Path.basename(folder(guide))}/…) on a paragraph of its own"
    ]

  defp image_problems(_root, _guide, _folder, %{path: nil} = image),
    do: ["#{image.src} is not a file in the repo (kilncms.dev would publish only its alt text)"]

  defp image_problems(root, _guide, folder, image) do
    file = Path.join(root, image.path)

    cond do
      Path.dirname(image.path) != folder ->
        ["#{image.src} is not in #{folder}/"]

      not File.regular?(file) ->
        ["#{image.src} does not exist"]

      true ->
        Enum.reject(
          [
            String.trim(image.alt) == "" && "#{image.src} has no alt text",
            not image.standalone? &&
              "#{image.src} is not published as an image: it is not alone in a top-level " <>
                "paragraph (kilncms.dev would publish only its alt text)"
            | file_problems(image.src, file)
          ],
          &(&1 == false)
        )
    end
  end

  defp file_problems(src, file) do
    bytes = File.stat!(file).size

    size =
      if bytes > @max_image_bytes,
        do: ["#{src} is #{bytes} bytes, over #{@max_image_bytes}"],
        else: []

    with <<"RIFF", _::binary-size(4), "WEBP", _::binary>> <- File.read!(file),
         {:ok, image} <- Image.open(file) do
      width = Image.width(image)

      if width > @max_width,
        do: ["#{src} is #{width} px wide, over #{@max_width}" | size],
        else: size
    else
      _ -> ["#{src} is not a WebP file" | size]
    end
  end

  # Everything under `docs/images/`: folders of a guide in the extras, holding
  # only what that guide shows.
  defp folder_problems(root, extras, shown) do
    images_dir = Path.join(root, "docs/images")
    entries = if File.dir?(images_dir), do: images_dir |> File.ls!() |> Enum.sort(), else: []

    Enum.flat_map(entries, fn entry ->
      folder = "docs/images/#{entry}"
      # The guide `folder/1` gives this folder to: directly under docs/, with
      # whatever extension it has.
      guide = Enum.find(extras, &(Path.dirname(&1) == "docs" and folder(&1) == folder))

      cond do
        not File.dir?(Path.join(root, folder)) ->
          ["  #{folder} belongs to no guide: put it in docs/images/<guide>/"]

        guide == nil ->
          ["  #{folder}/ belongs to no guide: no docs/#{entry}.* is in mix.exs extras"]

        true ->
          unreferenced(root, folder, guide, shown[guide])
      end
    end)
  end

  defp unreferenced(root, folder, guide, images) do
    referenced = for %{path: path} <- images, do: path

    for file <- root |> Path.join(folder) |> File.ls!() |> Enum.sort(),
        path = Path.join(folder, file),
        path not in referenced,
        do: "  #{path} is not shown by #{guide}"
  end

  # The folder a guide's screenshots live in: `docs/images/<basename>`.
  defp folder(guide), do: "docs/images/" <> Path.basename(guide, Path.extname(guide))

  # Every image of the guide that is not at a URL, as
  # `%{src, alt, path, standalone?, html?}`, where `path` is the file it names,
  # resolved against the guide to a repo-root-relative path.
  defp images(root, extra) do
    {_, ast, _} =
      root
      |> Path.join(extra)
      |> File.read!()
      |> EarmarkParser.as_ast(gfm: true, breaks: false, pure_links: true, math: true)

    for image <- collect_top(ast),
        not external?(image.src),
        do: Map.put(image, :path, repo_path(image.src, extra))
  end

  # `{"img", …}` nodes, noting whether each is the only thing in a top-level
  # paragraph — the publisher's test for an image block: `Markdown.blocks/2`
  # maps over the top-level nodes only, so an image in a list item or a
  # blockquote publishes as its alt text — and raw HTML `<img>` wherever it
  # appears outside code.
  defp collect_top(ast) do
    Enum.flat_map(ast, fn
      {"p", _attrs, children, _meta} = paragraph ->
        case Enum.reject(children, &(is_binary(&1) and String.trim(&1) == "")) do
          [{"img", _, _, _} = only] -> collect(only, true)
          _ -> collect(paragraph, false)
        end

      node ->
        collect(node, false)
    end)
  end

  defp collect(nodes, standalone?) when is_list(nodes),
    do: Enum.flat_map(nodes, &collect(&1, standalone?))

  defp collect({tag, _attrs, _children, _meta}, _standalone?) when tag in ["code", "pre"], do: []

  defp collect({"img", attrs, _children, meta}, standalone?) do
    [
      %{
        src: attr(attrs, "src"),
        alt: attr(attrs, "alt"),
        standalone?: standalone?,
        html?: Map.get(meta, :verbatim, false)
      }
    ]
  end

  defp collect({_tag, _attrs, children, _meta}, _standalone?), do: collect(children, false)

  defp collect(text, _standalone?) when is_binary(text) do
    for [_, src] <- Regex.scan(~r/<img\b[^>]*\bsrc=["']([^"']+)["']/i, text),
        do: %{src: src, alt: "", standalone?: false, html?: true}
  end

  defp attr(attrs, name), do: Enum.find_value(attrs, "", fn {k, v} -> k == name && v end)

  # An `http(s)` image is the publisher's to show as a link, not ours to budget.
  defp external?(src), do: URI.parse(src).scheme in ["http", "https"]

  # `KilnPublish.Markdown.repo_path/2` (scripts/publish/common.exs), ported
  # rather than loaded: test/scripts/publish_docs_test.exs already requires
  # that script, and two async files requiring it would race. The repo path
  # it publishes from, with the `#fragment` dropped and nothing else touched,
  # so a `?query` or a `%20` fails here as "does not exist" as it would fail
  # the upload; nil where the publisher shows only the alt text.
  defp repo_path(src, source) do
    if src == "" or URI.parse(src).scheme != nil or String.starts_with?(src, ["#", "/"]) do
      nil
    else
      [path | _] = String.split(src, "#", parts: 2)
      path |> Path.expand("/" <> Path.dirname(source)) |> String.trim_leading("/")
    end
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp write!(root, path, contents) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
  end

  defp webp!(root, path, width) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    Image.write!(Image.new!(width, 10, color: :white), file)
  end

  defp noise_webp!(root, path) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))

    {:ok, noise} =
      Vix.Vips.Image.new_from_binary(
        :crypto.strong_rand_bytes(400 * 400 * 3),
        400,
        400,
        3,
        :VIPS_FORMAT_UCHAR
      )

    Image.write!(noise, file, quality: 100)
  end
end
