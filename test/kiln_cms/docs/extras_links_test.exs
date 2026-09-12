defmodule KilnCMS.Docs.ExtrasLinksTest do
  @moduledoc """
  Every relative Markdown link between two ExDoc extras lands on the file whose
  path was written, and on the section its `#fragment` names — in the generated
  docs *and* on github.com.

  ## Files: ExDoc resolves by basename

  ExDoc resolves a relative link from an extra **by basename alone**. The whole
  of `ExDoc.Formatter.extra_paths/1` is

      Map.put(acc, Path.basename(source_path), id)

  folded over `extras` in order, and `ExDoc.Autolink.build_extra_link/2` looks
  the link up as `config.extras[Path.basename(path)]`. The directories you wrote
  are never consulted, and the `filename:` override changes only the *output*
  name, not this lookup. So when several extras share a basename, every relative
  link to any of them renders as a link to whichever was registered **last**.

  Four extras are named `README.md` — the root one plus `examples/`, `projects/`
  and `clients/elixir/kiln_client/`. Ten links written as `../README.md`,
  `../projects/README.md` or `../examples/README.md` therefore rendered as links
  to the Elixir client's page, and an eleventh (`../clients/js/README.md`, not an
  extra at all) was quietly absorbed into it too.

  **`mix docs --warnings-as-errors` does not catch this.** It warns only when a
  basename is missing from the map entirely; a basename that *is* present
  resolves silently, to the wrong page. The docs job was green the whole time.

  The fix in the source documents is to link a README by its absolute
  `https://github.com/The-Verscienta/kiln_cms/blob/main/…` URL — the only form
  that is right both on github.com and in `mix docs` output, and the form this
  repository already uses for `.github/SECURITY.md` and `AGENTS.md`.

  ## Fragments: two sluggers disagree

  Guides are written on GitHub and link each other's sections by GitHub's
  slugs, which `KilnCMS.HeadingAnchors.slug/1` reproduces (it is also what
  kilncms.dev serves). ExDoc slugs differently, in `ExDoc.Utils.text_to_id/1`
  applied by `ExDoc.DocAST.add_ids_to_headers(ast, [:h2, :h3])`:

    * it collapses every run of non-word characters to one `-`, where GitHub
      drops the punctuation and keeps a `-` per space — `Storage & CDN` is
      `storage-cdn` in the docs and `storage--cdn` on GitHub;
    * an apostrophe or slash becomes a `-` — `What's` is `what-s`, not `whats`;
    * only `##` and `###` headings get an id at all.

  38 of 110 fragment links were dead in the generated docs, and `mix docs`
  never looks at a fragment; one more, written against ExDoc's slug, was dead
  on github.com instead. The second test fails when a fragment is missing from
  **either** heading-id set, so a link has to be right in both.

  ExDoc is `only: :dev`, so its slugger is ported below (`exdoc_ids/1`) and the
  Markdown is parsed with `EarmarkParser` — the parser ExDoc itself calls, at
  the version pinned in `mix.lock` for both. The third test pins the port to
  what ex_doc 0.40.3's own functions return; if ex_doc is upgraded and that
  test fails, re-run `ExDoc.DocAST.add_ids_to_headers/2` (or read the ids out of
  a fresh `doc/*.html`) before touching the expectations.

  See CONTRIBUTING.md, "Documentation", and the `extras/0` comment in `mix.exs`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.HeadingAnchors

  # The extensions ExDoc treats as extras and rewrites to `.html`
  # (`ExDoc.Autolink`'s `@builtin_ext`). Anything else is passed through
  # untouched and is not our business.
  @builtin_ext [".livemd", ".cheatmd", ".md", ".txt", ""]

  # The ones ExDoc parses as Markdown and so gives heading ids.
  @markdown_ext [".md", ".livemd", ".cheatmd"]

  # `[text](href)`, allowing one level of brackets inside the text so that
  # ``[`examples/README.md`](…)`` and `[**Creating an admin user**](…)` match.
  @link ~r/\[(?:[^\[\]]|\[[^\]]*\])*\]\(([^()\s]+)\)/

  @extras Mix.Project.config()[:docs][:extras] |> Enum.map(fn {path, _} -> to_string(path) end)

  test "every relative link between extras resolves to the file it names" do
    links = for extra <- @extras, link <- relative_links(extra), do: link

    # A broken regex or a moved extras list would otherwise pass vacuously.
    assert length(links) > 200,
           "expected the extras to contain hundreds of relative links, found #{length(links)}"

    mistargeted =
      for {source, line, href, written, _fragment} <- links,
          not same_page?(href),
          resolved = resolves_to(written),
          resolved != nil and resolved != written do
        "  #{source}:#{line}\n" <>
          "      written:  #{href}  ->  #{written}\n" <>
          "      renders as a link to:  #{resolved}"
      end

    assert mistargeted == [],
           """
           These links render as links to a different file than the one they name.

           ExDoc resolves a relative link from an extra by BASENAME, taking the
           last extra registered with that basename — the directories below are
           ignored. Nothing in `mix docs --warnings-as-errors` reports it.

           #{Enum.join(mistargeted, "\n")}

           Fix each one by linking the file's absolute URL:

               https://github.com/The-Verscienta/kiln_cms/blob/main/<path>

           which is correct both on github.com and in the generated docs. Do not
           fix it by reordering `extras:` in mix.exs — that only moves which of
           the colliding links is wrong.
           """
  end

  test "every #fragment link between extras lands on a heading in the docs and on GitHub" do
    links =
      for extra <- @extras,
          {_, line, href, written, fragment} <- relative_links(extra),
          fragment != nil,
          target = if(same_page?(href), do: extra, else: resolves_to(written)),
          Path.extname(target || "") in @markdown_ext,
          do: {extra, line, href, fragment, target}

    # Same guard: a fragment regression in the scan must not read as "all good".
    assert length(links) > 75,
           "expected dozens of #fragment links between extras, found #{length(links)}"

    ids = Map.new(@extras, &{&1, heading_ids(&1)})

    dead =
      for {source, line, href, fragment, target} <- links,
          %{exdoc: exdoc, github: github} = ids[target],
          missing =
            Enum.reject([exdoc: exdoc, github: github], fn {_, set} -> fragment in set end),
          missing != [] do
        where = missing |> Keyword.keys() |> Enum.map_join(" and ", &rendering/1)

        "  #{source}:#{line}  (#{href})\n" <>
          "      no heading in #{target} has this id #{where}" <>
          near_miss(fragment, target)
      end

    assert dead == [],
           """
           These #fragment links do not land on a section in every rendering.

           ExDoc slugs a heading with `ExDoc.Utils.text_to_id/1` (a run of
           punctuation collapses to one `-`, `What's` becomes `what-s`) and ids
           only `##` and `###`; GitHub drops the punctuation, keeps a `-` per
           space, and ids every level. `mix docs --warnings-as-errors` checks
           neither.

           #{Enum.join(dead, "\n")}

           Fix each one of two ways:

             * link the file without the fragment and name the section in the
               sentence — "see *Production storage & CDN* in [media-pipeline.md](…)";
               always safe;
             * reword the heading so both slugs agree (`&` -> `and`, drop the
               apostrophe, `—` -> `:`), then update every link to it. This changes
               the heading's GitHub anchor: grep docs/, README.md, CHANGELOG.md,
               lib/ and the GitHub issues for the old one first.
           """
  end

  # Pins the ExDoc port to ex_doc 0.40.3 itself: the first list is exactly what
  # `ExDoc.Markdown.to_ast/2 |> ExDoc.DocAST.add_ids_to_headers([:h2, :h3])`
  # returned for this document, and the port also reproduced all 1,084 h2/h3
  # ids in a full `mix docs` build. The GitHub list is
  # `KilnCMS.HeadingAnchors`, whose slugs are pinned in its own test.
  test "the ExDoc slug port matches ids from a real docs build" do
    markdown = """
    # Title

    ## Production storage & CDN

    ## On/off variables

    ### Reranking ask's sources

    ## What is in the index — and what is not (#1006)

    ## 11. Ranking eval harness  ·  Effort M · Risk L · *shipped (`mix kiln.search.eval`)*

    ### Phase 3 — Hybrid fusion (+ optional rerank)

    ## A `<b>` tag &amp; C++

    #### Four is never an id

    > ### Quoted headings still count

    ## Setting up

    ### Setting up

    ## Setting up
    """

    assert %{exdoc: exdoc, github: github} = heading_ids_of(markdown)

    assert exdoc == [
             "production-storage-cdn",
             "on-off-variables",
             "reranking-ask-s-sources",
             "what-is-in-the-index-and-what-is-not-1006",
             "11-ranking-eval-harness-effort-m-risk-l-shipped-mix-kiln-search-eval",
             "phase-3-hybrid-fusion-optional-rerank",
             "a-b-tag-c",
             "quoted-headings-still-count",
             "setting-up",
             "setting-up-1",
             "setting-up-2"
           ]

    assert github == [
             "title",
             "production-storage--cdn",
             "onoff-variables",
             "reranking-asks-sources",
             "what-is-in-the-index--and-what-is-not-1006",
             "11-ranking-eval-harness----effort-m--risk-l--shipped-mix-kilnsearcheval",
             "phase-3--hybrid-fusion--optional-rerank",
             "a-b-tag--c",
             "four-is-never-an-id",
             "quoted-headings-still-count",
             "setting-up",
             "setting-up-1",
             "setting-up-2"
           ]
  end

  defp rendering(:exdoc), do: "in the generated docs"
  defp rendering(:github), do: "on github.com"

  # When the fragment is some heading's slug in one renderer, say which heading,
  # so the reader sees the punctuation that caused it.
  defp near_miss(fragment, target) do
    heading =
      target
      |> File.read!()
      |> headings()
      |> Enum.find(fn {_level, text} -> HeadingAnchors.slug(text) == fragment end)

    case heading do
      {level, text} -> "\n      (written against GitHub's slug for h#{level} \"#{text}\")"
      nil -> ""
    end
  end

  # `#section` alone stays on the page it is written in; ExDoc does no lookup.
  defp same_page?(href), do: String.starts_with?(href, "#")

  # The extra ExDoc actually links to for a path with this basename: the last
  # registered one, or nil when no extra shares the basename (which ExDoc
  # reports itself, as a warning the docs job turns into an error).
  defp resolves_to(written) do
    base = Path.basename(written)

    @extras
    |> Enum.filter(&(Path.basename(&1) == base))
    |> List.last()
  end

  # Relative links to a Markdown-ish file, as {source, line, href, written,
  # fragment}, where `written` is the link target resolved to a
  # repo-root-relative path (the source itself for a bare `#fragment`), and
  # `fragment` is nil when the link carries none.
  defp relative_links(extra) do
    for {line, number} <-
          extra |> File.read!() |> prose() |> String.split("\n") |> Enum.with_index(1),
        [_, href] <- Regex.scan(@link, line),
        uri = URI.parse(href),
        is_nil(uri.scheme),
        is_nil(uri.host),
        uri.path not in [nil, ""] or uri.fragment not in [nil, ""],
        Path.extname(uri.path || "") in @builtin_ext do
      written =
        case uri.path do
          p when p in [nil, ""] -> extra
          p -> p |> Path.expand(Path.dirname(extra)) |> Path.relative_to_cwd()
        end

      fragment = if uri.fragment in [nil, ""], do: nil, else: uri.fragment
      {extra, number, href, written, fragment}
    end
  end

  defp heading_ids(extra) do
    if Path.extname(extra) in @markdown_ext,
      do: extra |> File.read!() |> heading_ids_of(),
      else: %{exdoc: [], github: []}
  end

  defp heading_ids_of(markdown) do
    headings = headings(markdown)
    %{exdoc: exdoc_ids(headings), github: github_ids(headings)}
  end

  # `ExDoc.DocAST.add_ids_to_headers(ast, [:h2, :h3])` over
  # `ExDoc.Utils.text_to_id/1`: `h2`/`h3` only, repeats numbered `-1`, `-2` by
  # how often the *base* id has been seen.
  defp exdoc_ids(headings) do
    headings
    |> Enum.filter(fn {level, _} -> level in [2, 3] end)
    |> Enum.map_reduce(%{}, fn {_, text}, seen ->
      base = exdoc_text_to_id(text)
      count = Map.get(seen, base, 0)
      id = if count >= 1, do: "#{base}-#{count}", else: base
      {id, Map.put(seen, base, count + 1)}
    end)
    |> elem(0)
  end

  defp exdoc_text_to_id(text) do
    text
    |> String.replace(~r/&#\d+;/, "")
    |> String.replace(~r/&[A-Za-z0-9]+;/, "")
    |> String.replace(~r/\W+/u, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  # GitHub ids every level. `HeadingAnchors.put_ids/1` owns the slug and the
  # repeat counter; it reads a heading's text through tags and entities, so a
  # literal `<` or `>` (from inline code) is escaped first — both are dropped
  # by the slug either way.
  defp github_ids(headings) do
    html =
      Enum.map_join(headings, fn {level, text} ->
        "<h#{level}>#{text |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")}</h#{level}>"
      end)

    for [_, id] <- Regex.scan(~r/<h[1-6] id="([^"]*)">/, HeadingAnchors.put_ids(html)), do: id
  end

  # Every heading in the document as {level, text}, parsed the way ExDoc parses
  # an extra (`ExDoc.Markdown.Earmark.to_ast/2`'s options), with text taken the
  # way `ExDoc.DocAST.text/1` takes it: all descendant strings, trimmed.
  defp headings(markdown) do
    {_, ast, _} =
      EarmarkParser.as_ast(markdown, gfm: true, breaks: false, pure_links: true, math: true)

    collect_headings(ast)
  end

  defp collect_headings(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_headings/1)

  defp collect_headings({"h" <> <<digit>>, _attrs, children, _meta}) when digit in ?1..?6,
    do: [{digit - ?0, children |> text() |> IO.iodata_to_binary() |> String.trim()}]

  defp collect_headings({_tag, _attrs, children, _meta}), do: collect_headings(children)
  defp collect_headings(_text), do: []

  defp text(nodes) when is_list(nodes), do: Enum.map(nodes, &text/1)
  defp text(string) when is_binary(string), do: string
  defp text({_tag, _attrs, children, _meta}), do: text(children)

  # Blank out what ExDoc never autolinks — fenced code blocks, inline code spans
  # and HTML comments — keeping the line count so failures point at the real
  # line. Without this, `mix docs`'s own prose about `[text](url)` and the
  # comment in README.md explaining the SECURITY.md link both read as links.
  defp prose(markdown) do
    markdown
    |> String.replace(~r/<!--.*?-->/s, &String.replace(&1, ~r/[^\n]/, " "))
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_fence? ->
      cond do
        Regex.match?(~r/^\s*(```|~~~)/, line) -> {"", not in_fence?}
        in_fence? -> {"", true}
        true -> {String.replace(line, ~r/``[^`]*``|`[^`\n]*`/, ""), false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end
end
