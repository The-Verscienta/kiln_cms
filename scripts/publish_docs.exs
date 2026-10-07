# Publish the user-facing guides in docs/ to a running Kiln site, as entries of
# a dynamic "Doc" content type (served at /docs/<slug>) plus a page that
# indexes them by section (slug `documentation`, served at /docs by its alias).
# kilncms.dev runs this from .github/workflows/publish-docs.yml on every push
# to main that touches docs.
#
#     elixir scripts/publish_docs.exs --all
#     elixir scripts/publish_docs.exs docs/deploy.md docs/seo.md
#     elixir scripts/publish_docs.exs --all --dry-run --out /tmp/docs-html
#
# Environment (not needed with --dry-run):
#
#     KILN_URL            site origin, e.g. https://kilncms.dev
#     KILN_DOCS_API_KEY   a :read_write API key on an ADMIN account — publishing
#                         is admin-only (docs/json-api.md → "Writing")
#     KILN_DOCS_TYPE      the Doc type's machine name (default "doc"); its id is
#                         looked up via /api/json/type-definitions/by-name/:name
#     KILN_DOCS_TYPE_ID   optional: that id, skipping the lookup
#
# Which files are published, their titles and their sections all come from
# `extras/0` and `groups_for_extras/0` in mix.exs — the curation ExDoc already
# uses — minus the internal groups in @internal_groups. Adding a guide to
# mix.exs is what publishes it.
#
# A standalone script rather than a mix task on purpose: CI publishes without
# compiling the application, so nothing here may reach a `KilnCMS.*` module.
# The server treats the HTML it sends as untrusted — the rich-text cast
# sanitizes it like any other API write.
#
# Renamed or deleted guides are not unpublished; do that in the editor.
#
# The Markdown renderer and the JSON:API client are shared with
# scripts/publish_releases.exs, in scripts/publish/common.exs.

# The PARSER only, matching mix.exs. Not `earmark`: that package is retired on
# Hex and carries a stored-XSS advisory in its HTML renderer, so nothing in
# this repo may install it. Its `Earmark.Transform` is replaced by the renderer
# in scripts/publish/common.exs — a port of `KilnCMS.Markdown`'s, which this
# script cannot call for the reason above.
Mix.install([
  {:earmark_parser, "~> 1.4"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("publish/common.exs", __DIR__)

defmodule PublishDocs do
  alias KilnPublish.{API, Markdown}

  @repo_url "https://github.com/The-Verscienta/kiln_cms"
  @raw_url "https://raw.githubusercontent.com/The-Verscienta/kiln_cms/main"
  # Groups that stay off the public site. "Architecture decisions" and
  # "Release history" are the #1325 successors to the decision-records group
  # and to CHANGELOG.md (which lives in "Project history"), so they inherit
  # that treatment rather than appearing at /docs the first time this script
  # runs again.
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

  @doc "The published guides, grouped: `%{path, slug, title, group}`."
  def catalogue(mix_exs \\ "mix.exs") do
    ast = mix_exs |> File.read!() |> Code.string_to_quoted!()
    options = Map.new(eval_defp(ast, :extras), fn {path, opts} -> {to_string(path), opts} end)

    # Group order, then each group's own order, so index sections come out
    # whole (code-injection is listed under Security in `extras/0` but grouped
    # under Authoring).
    for {group, paths} <- eval_defp(ast, :groups_for_extras),
        to_string(group) not in @internal_groups,
        path <- paths do
      opts = Map.get(options, path, [])
      %{path: path, slug: slug(path, opts), title: opts[:title], group: to_string(group)}
    end
  end

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

  @doc "The `/docs` index page body: every guide, under its mix.exs section."
  def index_html(docs) do
    sections =
      docs
      |> Enum.chunk_by(& &1.group)
      |> Enum.map_join(fn [%{group: group} | _] = in_group ->
        items =
          Enum.map_join(in_group, fn doc ->
            ~s(<li><a href="/docs/#{doc.slug}">#{Markdown.escape(doc.title)}</a></li>)
          end)

        "<h2>#{Markdown.escape(group)}</h2><ul>#{items}</ul>"
      end)

    source = ~s(<a href="#{@repo_url}/tree/main/docs">docs/ on GitHub</a>)

    "<p>Guides for running, authoring in, extending and integrating with Kiln. " <>
      "Every page is published from #{source}.</p>" <> sections
  end

  # ── CLI ───────────────────────────────────────────────────────────────────

  def main(argv) do
    {opts, files} =
      OptionParser.parse!(argv, strict: [all: :boolean, dry_run: :boolean, out: :string])

    catalogue = catalogue()
    slugs = Map.new(catalogue, &{&1.path, &1.slug})

    # mix.exs decides titles, slugs and sections, and this script decides the
    # rendering — a change to either can touch every page.
    all? =
      opts[:all] ||
        Enum.any?(
          files,
          &(&1 in ["mix.exs", "scripts/publish_docs.exs", "scripts/publish/common.exs"])
        )

    selected = if all?, do: catalogue, else: Enum.filter(catalogue, &(&1.path in files))

    rendered =
      Enum.map(catalogue, fn doc ->
        markdown = File.read!(doc.path)
        {title, html} = render(doc, markdown, slugs)

        Map.merge(doc, %{
          title: title,
          html: html,
          seo_description: Markdown.seo_description(markdown)
        })
      end)

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

PublishDocs.main(System.argv())
