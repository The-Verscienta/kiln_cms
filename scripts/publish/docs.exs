# The logic behind scripts/publish_docs.exs, kept apart from its
# `Mix.install` and `main/1` call so test/scripts/ can load it against the
# app's own copies of earmark_parser, req and jason. Read
# scripts/publish_docs.exs for what is published, and the site setup.

Code.require_file("common.exs", __DIR__)

defmodule PublishDocs do
  @moduledoc false

  alias KilnPublish.{API, Markdown}

  @repo_url "https://github.com/The-Verscienta/kiln_cms"
  @raw_url "https://raw.githubusercontent.com/The-Verscienta/kiln_cms/main"

  # Every mix.exs group is exactly one of these three, and `catalogue/1`
  # raises on one that is none of them: a new group has to be placed on
  # purpose, rather than appearing at /docs the first time this script runs.
  #
  # The sections of the /docs index, in their mix.exs order.
  @public_groups [
    "Getting started",
    "Compare & migrate",
    "Authoring & editorial",
    "Modeling & extending",
    "APIs & headless",
    "Operations & deployment",
    "Security & access"
  ]
  # For people working on Kiln itself (#2157). Published, but set apart: the
  # last section on the index, after a rule. Kept public rather than dropped
  # because guides link into it, e.g. /docs/releasing#updating-a-project-to-a-release.
  @contributing_group "Contributing to Kiln"
  # Groups that stay off the public site. "Architecture decisions" and
  # "Release history" are the #1325 successors to the decision-records group
  # and to CHANGELOG.md (which lives in "Project history"), so they inherit
  # that treatment.
  @internal_groups [
    "Design notes & decision records",
    "Architecture decisions",
    "Audits & release checklists",
    "Release history",
    "Project history"
  ]
  # The index can't be a page with slug `docs`: a page slug may not shadow a
  # content type's section URL (`SlugAvailable`). A `path_alias` may, and an
  # alias answers at `/docs` before the 404 does.
  @index_slug "documentation"
  @index_alias "/docs"

  # ── Catalogue (from mix.exs) ──────────────────────────────────────────────

  @doc """
  The published guides, grouped: `%{path, slug, title, group}`. Raises when
  mix.exs has a group that is neither public, contributing nor internal.
  """
  def catalogue(mix_exs \\ "mix.exs") do
    ast = read_mix_exs(mix_exs)
    options = Map.new(eval_defp(ast, :extras), fn {path, opts} -> {to_string(path), opts} end)

    # Group order, then each group's own order, so index sections come out
    # whole (code-injection is listed under Security in `extras/0` but grouped
    # under Authoring).
    for {group, paths} <- groups(ast),
        group not in @internal_groups,
        path <- paths do
      opts = Map.get(options, path, [])
      %{path: path, slug: slug(path, opts), title: opts[:title], group: group}
    end
  end

  @doc "mix.exs's `groups_for_extras/0`, as `{group, paths}` with string names."
  def groups(mix_exs \\ "mix.exs")

  def groups(mix_exs) when is_binary(mix_exs), do: mix_exs |> read_mix_exs() |> groups()

  def groups(ast) do
    groups =
      Enum.map(eval_defp(ast, :groups_for_extras), fn {g, paths} -> {to_string(g), paths} end)

    known = [@contributing_group | @public_groups ++ @internal_groups]

    case Enum.reject(groups, fn {group, _} -> group in known end) do
      [] ->
        groups

      unknown ->
        raise """
        mix.exs has groups_for_extras the docs publisher does not know: \
        #{Enum.map_join(unknown, ", ", &inspect(elem(&1, 0)))}

        Add each to @public_groups, @contributing_group or @internal_groups in
        scripts/publish/docs.exs, which decides whether it appears at /docs.
        """
    end
  end

  @doc "mix.exs's `extras/0` paths, as strings."
  def extras(mix_exs \\ "mix.exs") do
    mix_exs
    |> read_mix_exs()
    |> eval_defp(:extras)
    |> Enum.map(fn {path, _} -> to_string(path) end)
  end

  defp read_mix_exs(path), do: path |> File.read!() |> Code.string_to_quoted!()

  # Evaluating the body, rather than defining mix.exs's project module inside
  # this script's own Mix.install project.
  #
  # Both functions build keyword lists, and both now call zero-arity private
  # helpers of their own — `release_history/0` and `decisions/0`, which glob
  # docs/changelog and docs/decisions (#1325). Those calls are resolved the
  # same way, by evaluating the helper's body and splicing the result in.
  # Without that, evaluating `extras/0` raised "undefined function
  # release_history/0" and every docs publish since has failed.
  defp eval_defp(ast, name) do
    body = defp_body(ast, name) || raise "mix.exs has no `defp #{name}`"

    {resolved, _} =
      Macro.prewalk(body, nil, fn
        {call, _meta, args} = node, acc when is_atom(call) and args in [[], nil] ->
          if defp_body(ast, call),
            do: {Macro.escape(eval_defp(ast, call)), acc},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    {value, _binding} = Code.eval_quoted(resolved)
    value
  end

  defp defp_body(ast, name) do
    {_, body} =
      Macro.prewalk(ast, nil, fn
        {:defp, _, [{^name, _, _}, [do: body]]} = node, nil -> {node, body}
        node, acc -> {node, acc}
      end)

    body
  end

  defp slug("README.md", _opts), do: "overview"

  defp slug(path, opts),
    do: opts[:filename] || path |> Path.basename(".md") |> String.downcase()

  # ── Markdown → HTML ───────────────────────────────────────────────────────
  #
  # Parsing and rendering are KilnPublish.Markdown (scripts/publish/common.exs,
  # shared with publish_releases.exs); what is guide-specific — titles and the
  # link rewriting to /docs/<slug> — stays here.

  @doc "Renders one guide to `{title, html}`. `slugs` maps repo paths to slugs."
  def render(doc, markdown, slugs) do
    ast = markdown |> Markdown.strip_front_matter() |> Markdown.parse(doc.path)
    {h1, ast} = Markdown.pop_h1(ast)

    {doc.title || h1 || doc.slug,
     ast |> Markdown.map_ast(&rewrite(&1, doc.path, slugs)) |> Markdown.render()}
  end

  # Only a guide that names one sends a description. Sending nil for the rest
  # would clear one an editor wrote on the site.
  defp seo_attrs(%{seo_description: nil}), do: %{}
  defp seo_attrs(%{seo_description: text}), do: %{"seo_description" => text}

  defp rewrite({"a", attrs, children, meta}, source, slugs),
    do: {"a", Markdown.update_attr(attrs, "href", &link(&1, source, slugs)), children, meta}

  defp rewrite({"img", attrs, children, meta}, source, _slugs),
    do: {"img", Markdown.update_attr(attrs, "src", &asset(&1, source)), children, meta}

  defp rewrite(node, _source, _slugs), do: node

  @doc """
  A guide's link, made to work on the site. Another published guide becomes
  `/docs/<slug>`; any other repo path (source, internal notes, scripts) becomes
  its GitHub URL; absolute URLs and in-page fragments are left alone.
  """
  def link(href, source, slugs) do
    case Markdown.repo_path(href, source) do
      nil ->
        href

      {path, fragment} ->
        case slugs do
          %{^path => slug} -> "/docs/" <> slug <> fragment
          _ -> "#{@repo_url}/blob/main/#{path}#{fragment}"
        end
    end
  end

  defp asset(src, source) do
    case Markdown.repo_path(src, source) do
      nil -> src
      {path, _fragment} -> "#{@raw_url}/#{path}"
    end
  end

  # The guide the `/docs` index leads with (#1930): what Kiln is for, and the
  # order to read the delivery and governance guides in.
  @start_here "docs/right-everywhere-provably.md"
  # The role tracks (#2157). The guide is the one place they are curated; the
  # index inlines its `##` sections rather than keeping a second list.
  @reading_paths "docs/reading-paths.md"

  @doc """
  The `/docs` index page body: one "Start here" section (the wedge guide, the
  role tracks from docs/reading-paths.md, a link to site search), then every
  public guide under its mix.exs section, then the Contributing to Kiln
  guides, set apart after a rule.
  """
  def index_html(docs) do
    {contributing, public} = Enum.split_with(docs, &(&1.group == @contributing_group))
    source = ~s(<a href="#{@repo_url}/tree/main/docs">docs/ on GitHub</a>)

    "<p>Guides for running, authoring in, extending and integrating with Kiln. " <>
      "Every page is published from #{source}.</p>" <>
      start_here(docs) <>
      sections(Enum.reject(public, &(&1.path == @reading_paths))) <>
      contributing(contributing)
  end

  defp sections(docs) do
    docs
    |> Enum.chunk_by(& &1.group)
    |> Enum.map_join(fn [%{group: group} | _] = in_group ->
      "<h2>#{Markdown.escape(group)}</h2>" <> list(in_group)
    end)
  end

  defp list(docs) do
    items =
      Enum.map_join(docs, fn doc ->
        ~s(<li><a href="/docs/#{doc.slug}">#{Markdown.escape(doc.title)}</a></li>)
      end)

    "<ul>#{items}</ul>"
  end

  defp contributing([]), do: ""

  defp contributing(docs) do
    "<hr><h2>#{Markdown.escape(@contributing_group)}</h2>" <>
      "<p>For people working on Kiln itself, not using it.</p>" <> list(docs)
  end

  # Each part is left out when its guide is not in the catalogue, so a rename
  # in mix.exs drops it rather than linking to a page that is not there; with
  # neither guide, so is the heading.
  defp start_here(docs) do
    case wedge(docs) <> role_tracks(docs) do
      "" ->
        ""

      body ->
        "<h2>Start here</h2>" <>
          body <>
          ~s(<p><a href="/search">Search kilncms.dev</a> to look for a word or ) <>
          "a feature across every guide and page on the site.</p>"
    end
  end

  defp wedge(docs) do
    case Enum.find(docs, &(&1.path == @start_here)) do
      nil ->
        ""

      doc ->
        link = ~s(<a href="/docs/#{doc.slug}">#{Markdown.escape(doc.title)}</a>)

        "<p>Kiln is a CMS for content that has to be right: a correction reaches " <>
          "every site and app you connect within seconds, with a signed record of " <>
          "who changed it, who approved it and what readers saw. #{link} explains " <>
          "how, and gives the order to read the delivery and governance guides in.</p>"
    end
  end

  # The guide's rendered body from its first `##` on, each `##` demoted to an
  # `<h3>` under "Start here". Its lead paragraphs introduce the page itself, so
  # they stay on /docs/reading-paths. String surgery is safe here because
  # `Markdown.render/1` writes bare `<h2>` tags and escapes every `<` in text and
  # code, so `<h2>` in the output is always a heading.
  defp role_tracks(docs) do
    case Enum.find(docs, &(&1.path == @reading_paths)) do
      %{html: html} ->
        case String.split(html, "<h2>", parts: 2) do
          [_lead, tracks] ->
            ("<h2>" <> tracks)
            |> String.replace("<h2>", "<h3>")
            |> String.replace("</h2>", "</h3>")

          [_no_sections] ->
            ""
        end

      _absent ->
        ""
    end
  end

  @doc "Every guide in `catalogue`, read and rendered: adds `html` and `seo_description`."
  def render_all(catalogue) do
    slugs = Map.new(catalogue, &{&1.path, &1.slug})

    Enum.map(catalogue, fn doc ->
      markdown = File.read!(doc.path)
      {title, html} = render(doc, markdown, slugs)

      Map.merge(doc, %{
        title: title,
        html: html,
        seo_description: Markdown.seo_description(markdown)
      })
    end)
  end

  # ── CLI ───────────────────────────────────────────────────────────────────

  def main(argv) do
    {opts, files} =
      OptionParser.parse!(argv, strict: [all: :boolean, dry_run: :boolean, out: :string])

    catalogue = catalogue()

    # mix.exs decides titles, slugs and sections, and this script decides the
    # rendering — a change to either can touch every page.
    all? =
      opts[:all] ||
        Enum.any?(
          files,
          &(&1 in [
              "mix.exs",
              "scripts/publish_docs.exs",
              "scripts/publish/docs.exs",
              "scripts/publish/common.exs"
            ])
        )

    selected = if all?, do: catalogue, else: Enum.filter(catalogue, &(&1.path in files))

    rendered = render_all(catalogue)

    to_publish = Enum.filter(rendered, fn doc -> Enum.any?(selected, &(&1.path == doc.path)) end)
    IO.puts("#{length(to_publish)} of #{length(catalogue)} guides selected")

    if opts[:dry_run],
      do: dry_run(to_publish, rendered, opts[:out]),
      else: publish_all(to_publish, rendered)
  end

  defp dry_run(to_publish, rendered, out) do
    for doc <- to_publish do
      IO.puts("  /docs/#{doc.slug}  #{doc.title}  (#{byte_size(doc.html)} bytes)")
      if doc.seo_description, do: IO.puts("      description: #{doc.seo_description}")
      if out, do: write_file(out, doc.slug, doc.title, doc.html)
    end

    if out, do: write_file(out, @index_slug, "Documentation", index_html(rendered))
  end

  defp write_file(out, slug, title, html) do
    File.mkdir_p!(out)
    File.write!(Path.join(out, slug <> ".html"), "<h1>#{Markdown.escape(title)}</h1>\n" <> html)
  end

  defp publish_all(to_publish, rendered) do
    req = API.client(API.env!("KILN_URL"), API.env!("KILN_DOCS_API_KEY"))
    type_name = System.get_env("KILN_DOCS_TYPE", "doc")
    entries = {"/entries", "entry", [{"type_name", type_name}]}
    pages = {"/pages", "page", []}

    # Resolved up front even when every guide already exists: a missing type is
    # a setup mistake worth failing on before any page is touched.
    type_id = type_id(req, type_name)
    create_entry = &%{"slug" => &1, "type_definition_id" => type_id}

    results =
      Enum.map(to_publish, fn doc ->
        API.report(
          doc.slug,
          API.upsert(
            req,
            entries,
            doc.slug,
            Map.merge(body(doc.title, doc.html), seo_attrs(doc)),
            create_entry
          )
        )
      end) ++
        [
          API.report(
            @index_slug,
            API.upsert(
              req,
              pages,
              @index_slug,
              body("Documentation", index_html(rendered)),
              &%{"slug" => &1, "path_alias" => @index_alias}
            )
          )
        ]

    failed = Enum.count(results, &(&1 == :error))
    if failed > 0, do: System.halt(1), else: IO.puts("done")
  end

  defp body(title, html), do: %{"title" => title, "block_tree" => API.rich_text_tree(html)}

  defp type_id(req, type_name) do
    case System.get_env("KILN_DOCS_TYPE_ID") do
      unset when unset in [nil, ""] -> look_up_type(req, type_name)
      id -> id
    end
  end

  defp look_up_type(req, type_name) do
    case API.request(req, :get, "/type-definitions/by-name/#{URI.encode(type_name)}", []) do
      {:ok, %{"data" => %{"id" => id}}} ->
        id

      {:error, message} ->
        raise """
        could not look up the "#{type_name}" content type: #{message}

        Create it at /editor/types (name "#{type_name}", path segment "docs"), and
        check the API key is a :read_write key on an admin account.
        """
    end
  end
end
