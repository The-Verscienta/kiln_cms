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

# The PARSER only, matching mix.exs. Not `earmark`: that package is retired on
# Hex and carries a stored-XSS advisory in its HTML renderer, so nothing in
# this repo may install it. Its `Earmark.Transform` is replaced by the renderer
# under "AST → HTML" below — a port of `KilnCMS.Markdown`'s, which this script
# cannot call for the reason above.
Mix.install([
  {:earmark_parser, "~> 1.4"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule PublishDocs do
  @repo_url "https://github.com/The-Verscienta/kiln_cms"
  @raw_url "https://raw.githubusercontent.com/The-Verscienta/kiln_cms/main"
  @internal_groups [
    "Design notes & decision records",
    "Audits & release checklists",
    "Project history"
  ]
  # The index can't be a page with slug `docs`: a page slug may not shadow a
  # content type's section URL (`SlugAvailable`). A `path_alias` may, and an
  # alias answers at `/docs` before the 404 does.
  @index_slug "documentation"
  @index_alias "/docs"
  @jsonapi "application/vnd.api+json"

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

  # Both functions are literal keyword lists, so evaluating the body is safe,
  # and it avoids defining the project module inside this script's own
  # Mix.install project.
  defp eval_defp(ast, name) do
    {_, body} =
      Macro.prewalk(ast, nil, fn
        {:defp, _, [{^name, _, _}, [do: body]]} = node, nil -> {node, body}
        node, acc -> {node, acc}
      end)

    body || raise "mix.exs has no `defp #{name}`"
    {value, _binding} = Code.eval_quoted(body)
    value
  end

  defp slug("README.md", _opts), do: "overview"

  defp slug(path, opts),
    do: opts[:filename] || path |> Path.basename(".md") |> String.downcase()

  # ── Markdown → HTML ───────────────────────────────────────────────────────

  @doc "Renders one guide to `{title, html}`. `slugs` maps repo paths to slugs."
  def render(doc, markdown, slugs) do
    ast = markdown |> strip_front_matter() |> parse(doc.path)
    {h1, ast} = pop_h1(ast)
    {doc.title || h1 || doc.slug, ast |> map_ast(&rewrite(&1, doc.path, slugs)) |> render_ast()}
  end

  # Same options as `KilnCMS.Markdown`, so a guide reads here the way the same
  # Markdown pasted into the editor would. `{:error, ast, messages}` is
  # earmark_parser's "parsed, with warnings" (an unclosed fence, a stray `]`):
  # the tree is still the guide, so it publishes, and the warnings go to stderr
  # where the workflow log keeps them.
  defp parse(markdown, source) do
    {ast, messages} =
      case EarmarkParser.as_ast(markdown, gfm_tables: true, breaks: false, pure_links: true) do
        {:ok, ast, messages} -> {ast, messages}
        {:error, ast, messages} -> {ast, messages}
      end

    for {severity, line, message} <- messages,
        do: IO.puts(:stderr, "  #{severity} #{source}:#{line}: #{message}")

    ast
  end

  defp strip_front_matter("---\n" <> rest = markdown) do
    case String.split(rest, "\n---\n", parts: 2) do
      [_front, body] -> body
      [_] -> markdown
    end
  end

  defp strip_front_matter(markdown), do: markdown

  # The page template prints the title, so the document's own H1 would print
  # twice.
  defp pop_h1([{"h1", _attrs, children, _meta} | rest]) do
    case children |> plain_text() |> String.trim() do
      "" -> {nil, rest}
      heading -> {heading, rest}
    end
  end

  defp pop_h1(ast), do: {nil, ast}

  # `Earmark.Transform.map_ast(ast, fun, _ignore_strings = true)`: rewrite each
  # element, then descend into what the rewrite returned.
  defp map_ast(nodes, fun) when is_list(nodes), do: Enum.map(nodes, &map_ast(&1, fun))

  defp map_ast({_tag, _attrs, _children, _meta} = node, fun) do
    {tag, attrs, children, meta} = fun.(node)
    {tag, attrs, map_ast(children, fun), meta}
  end

  defp map_ast(other, _fun), do: other

  defp rewrite({"a", attrs, children, meta}, source, slugs),
    do: {"a", update_attr(attrs, "href", &link(&1, source, slugs)), children, meta}

  defp rewrite({"img", attrs, children, meta}, source, _slugs),
    do: {"img", update_attr(attrs, "src", &asset(&1, source)), children, meta}

  defp rewrite(node, _source, _slugs), do: node

  defp update_attr(attrs, name, fun) do
    Enum.map(attrs, fn
      {^name, value} -> {name, fun.(value)}
      other -> other
    end)
  end

  @doc """
  A guide's link, made to work on the site. Another published guide becomes
  `/docs/<slug>`; any other repo path (source, internal notes, scripts) becomes
  its GitHub URL; absolute URLs and in-page fragments are left alone.
  """
  def link(href, source, slugs) do
    case repo_path(href, source) do
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
    case repo_path(src, source) do
      nil -> src
      {path, _fragment} -> "#{@raw_url}/#{path}"
    end
  end

  # `{repo-relative path, "#fragment" | ""}` for a relative href, else nil.
  defp repo_path(href, source) do
    if href == "" or URI.parse(href).scheme != nil or String.starts_with?(href, ["#", "/"]) do
      nil
    else
      {path, fragment} =
        case String.split(href, "#", parts: 2) do
          [path, fragment] -> {path, "#" <> fragment}
          [path] -> {path, ""}
        end

      resolved = Path.expand(path, "/" <> Path.dirname(source))
      {String.trim_leading(resolved, "/"), fragment}
    end
  end

  # ── AST → HTML ────────────────────────────────────────────────────────────
  #
  # A port of the renderer in `KilnCMS.Markdown` (lib/kiln_cms/markdown.ex),
  # which this script cannot call — CI publishes without compiling the
  # application, and that module reaches `KilnCMS.HTMLSanitizer` and
  # `KilnCMS.Blocks.Html`. Keep the two in step: same closed tag lists, same
  # escaping, same `language-` convention, so a guide published from here and
  # the same Markdown pasted into the editor produce the same HTML.
  #
  # The one deliberate difference is raw HTML the author wrote. There is no
  # sanitizer here, so an element outside the lists below keeps its text and
  # loses its tag rather than being handed through — the guides write none, and
  # `--dry-run --out` shows it the moment one does.

  # Structure Markdown syntax can produce, rendered bare. Attributes are
  # dropped because they are presentation (earmark_parser's table
  # `style="text-align"`), and the rich-text scrubber strips them on write
  # anyway. `a`, `img`, `pre` and `code` have their own clauses below, because
  # theirs matter.
  @plain_tags ~w(p h1 h2 h3 h4 h5 h6 ul ol li blockquote strong em del table thead tbody tfoot tr th td)
  @void_tags ~w(br hr)

  # Raw HTML that is never content. Rendering the children instead would keep
  # `alert(1)` as a paragraph of visible text.
  @dropped_raw ~w(script style noscript iframe object embed template head title)

  defp render_ast(nodes) when is_list(nodes), do: Enum.map_join(nodes, &render_ast/1)

  defp render_ast(text) when is_binary(text), do: text |> strip_comments() |> escape_text()

  # An HTML comment: `{:comment, [], [lines], %{comment: true}}`, whose tag is
  # an atom and so matches none of the lists. Its text is a note to whoever
  # edits the guide — the catch-all at the bottom would publish it as prose.
  defp render_ast({_tag, _attrs, _children, %{comment: true}}), do: ""

  defp render_ast({tag, _attrs, _children, _meta}) when tag in @dropped_raw, do: ""

  defp render_ast({"pre", _attrs, children, _meta}) do
    {language, text} =
      case children do
        [{"code", attrs, kids, _meta}] -> {code_language(attrs), plain_text(kids)}
        kids -> {nil, plain_text(kids)}
      end

    class = if language, do: ~s( class="language-#{escape(language)}"), else: ""
    "<pre><code#{class}>" <> escape(text) <> "</code></pre>"
  end

  defp render_ast({"code", _attrs, children, _meta}),
    do: "<code>" <> escape(plain_text(children)) <> "</code>"

  defp render_ast({"a", attrs, children, _meta}) do
    case attrs |> attr("href") |> safe_url(~w(http https mailto)) do
      nil -> render_ast(children)
      href -> ~s(<a href="#{escape(href)}">) <> render_ast(children) <> "</a>"
    end
  end

  defp render_ast({"img", attrs, _children, _meta}) do
    src = attrs |> attr("src") |> safe_url(~w(http https))
    alt = attr(attrs, "alt") || ""
    title = attr(attrs, "title")

    if src do
      title_attr = if title in [nil, ""], do: "", else: ~s( title="#{escape(title)}")
      ~s(<img src="#{escape(src)}" alt="#{escape(alt)}"#{title_attr}>)
    else
      # An unusable URL: the alt text is still the author's words.
      escape_text(alt)
    end
  end

  defp render_ast({tag, _attrs, children, _meta}) when tag in @plain_tags,
    do: "<#{tag}>" <> render_ast(children) <> "</#{tag}>"

  defp render_ast({tag, _attrs, _children, _meta}) when tag in @void_tags, do: "<#{tag}>"

  # Anything else (an element the lists don't know): its text is still the
  # author's, the wrapper is not trusted.
  defp render_ast({_tag, _attrs, children, _meta}) when is_list(children),
    do: render_ast(children)

  defp render_ast(_other), do: ""

  # `KilnCMS.HTMLSanitizer.safe_href/1` and `safe_image_src/1`, narrowed to
  # what this script can check without the application: an in-page fragment, a
  # same-origin path, or a URL in `schemes`. Anything else loses its anchor (or
  # its `<img>`) and keeps its text — the scrubber would drop it on write.
  defp safe_url(nil, _schemes), do: nil

  defp safe_url(url, schemes) do
    url = String.trim(url)

    cond do
      url == "" -> nil
      # A backslash is a slash to every browser, so `/\evil.example.com` is the
      # `//host` escape wearing a different hat.
      String.contains?(url, "\\") -> nil
      String.starts_with?(url, "#") -> url
      String.starts_with?(url, "//") -> nil
      String.starts_with?(url, "/") -> if String.contains?(url, ".."), do: nil, else: url
      true -> if URI.parse(url).scheme in schemes, do: url
    end
  end

  # earmark_parser tags a fence as `class="elixir"`; the rich-text scrubber
  # keeps only `language-<lang>`, and only for a language Kiln highlights. An
  # info string with more than a language keeps its first word.
  defp code_language(attrs) do
    with class when is_binary(class) <- attr(attrs, "class"),
         [first | _] <- String.split(class),
         language = String.replace_prefix(first, "language-", ""),
         true <- Regex.match?(~r/\A[A-Za-z0-9_+#-]{1,40}\z/, language) do
      language
    else
      _ -> nil
    end
  end

  # A comment written mid-sentence stays inside the paragraph's text run, where
  # the block clause above never sees it. `KilnCMS.Markdown` hands such a run
  # to the sanitizer, which drops comments; this does the same by hand. Code
  # content does not come through here — `plain_text/1` keeps a fenced HTML
  # example's comments intact.
  defp strip_comments(text), do: String.replace(text, ~r/<!--.*?-->/s, "")

  defp plain_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &plain_text/1)
  defp plain_text(text) when is_binary(text), do: text
  defp plain_text({_tag, _attrs, children, _meta}), do: plain_text(children)
  defp plain_text(_other), do: ""

  # earmark_parser pre-escapes some attribute values (`alt`) and not others
  # (`href`), so every value is decoded before it is escaped exactly once.
  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} when is_binary(value) -> decode(value)
      _ -> nil
    end)
  end

  defp decode(value) do
    value
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  @doc "The `/docs` index page body: every guide, under its mix.exs section."
  def index_html(docs) do
    sections =
      docs
      |> Enum.chunk_by(& &1.group)
      |> Enum.map_join(fn [%{group: group} | _] = in_group ->
        items =
          Enum.map_join(in_group, fn doc ->
            ~s(<li><a href="/docs/#{doc.slug}">#{escape(doc.title)}</a></li>)
          end)

        "<h2>#{escape(group)}</h2><ul>#{items}</ul>"
      end)

    source = ~s(<a href="#{@repo_url}/tree/main/docs">docs/ on GitHub</a>)

    "<p>Guides for running, authoring in, extending and integrating with Kiln. " <>
      "Every page is published from #{source}.</p>" <> sections
  end

  # An attribute value or code content: every markup character.
  defp escape(text) do
    text
    |> escape_text()
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&#39;")
  end

  # A text run. Quotes are left alone: they are not markup in element content,
  # and escaping them only makes a guide's HTML harder to read in a diff.
  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ── JSON:API client ───────────────────────────────────────────────────────

  def client(url, key) do
    Req.new(
      base_url: String.trim_trailing(url, "/") <> "/api/json",
      headers: [
        {"authorization", "Bearer " <> key},
        {"accept", @jsonapi},
        {"content-type", @jsonapi}
      ],
      retry: :transient
    )
  end

  @doc "Creates or updates one record by slug, then publishes it if it isn't."
  def upsert(req, kind, slug, title, html, create_attrs) do
    attrs = %{
      "title" => title,
      "block_tree" => [%{"type" => "rich_text", "content" => html, "order" => 1}]
    }

    with {:ok, existing} <- find(req, kind, slug),
         {:ok, record} <- write(req, kind, existing, slug, attrs, create_attrs) do
      publish(req, kind, record)
    end
  end

  defp find(req, {base, _type, filters}, slug) do
    params = Enum.map(filters, fn {k, v} -> {"filter[#{k}]", v} end) ++ [{"filter[slug]", slug}]

    case request(req, :get, base, params: params) do
      {:ok, %{"data" => [record | _]}} -> {:ok, record}
      {:ok, %{"data" => []}} -> {:ok, nil}
      error -> error
    end
  end

  defp write(req, {base, type, _filters}, nil, slug, attrs, create_attrs) do
    body = %{"data" => %{"type" => type, "attributes" => Map.merge(attrs, create_attrs.(slug))}}
    with {:ok, %{"data" => record}} <- request(req, :post, base, body: body), do: {:ok, record}
  end

  # `block_tree` is replaced wholesale: the body has no hand-edited blocks
  # whose ids would need to survive (#954 — ids only matter for admin-set
  # nested values, and this key is an admin's anyway).
  defp write(req, {base, type, _filters}, %{"id" => id}, _slug, attrs, _create_attrs) do
    body = %{"data" => %{"type" => type, "id" => id, "attributes" => attrs}}

    with {:ok, %{"data" => record}} <- request(req, :patch, "#{base}/#{id}", body: body),
         do: {:ok, record}
  end

  defp publish(_req, _kind, %{"attributes" => %{"state" => "published"}} = record),
    do: {:ok, :updated, record}

  defp publish(req, {base, type, _filters}, %{"id" => id}) do
    body = %{"data" => %{"type" => type, "id" => id, "attributes" => %{}}}

    with {:ok, %{"data" => record}} <- request(req, :patch, "#{base}/#{id}/publish", body: body),
         do: {:ok, :published, record}
  end

  defp request(req, method, path, opts) do
    opts = Keyword.update(opts, :body, nil, &Jason.encode!/1)

    case Req.request(req, [method: method, url: path, decode_body: false] ++ opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, if(body == "", do: %{}, else: Jason.decode!(body))}

      {:ok, %{status: status, body: body}} ->
        {:error, "#{method |> to_string() |> String.upcase()} #{path} → #{status}: #{body}"}

      {:error, exception} ->
        {:error, "#{path}: #{Exception.message(exception)}"}
    end
  end

  # ── CLI ───────────────────────────────────────────────────────────────────

  def main(argv) do
    {opts, files} =
      OptionParser.parse!(argv, strict: [all: :boolean, dry_run: :boolean, out: :string])

    catalogue = catalogue()
    slugs = Map.new(catalogue, &{&1.path, &1.slug})

    # mix.exs decides titles, slugs and sections, and this script decides the
    # rendering — a change to either can touch every page.
    all? = opts[:all] || Enum.any?(files, &(&1 in ["mix.exs", "scripts/publish_docs.exs"]))
    selected = if all?, do: catalogue, else: Enum.filter(catalogue, &(&1.path in files))

    rendered =
      Enum.map(catalogue, fn doc ->
        {title, html} = render(doc, File.read!(doc.path), slugs)
        Map.merge(doc, %{title: title, html: html})
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
      if out, do: write_file(out, doc.slug, doc.title, doc.html)
    end

    if out, do: write_file(out, @index_slug, "Documentation", index_html(rendered))
  end

  defp write_file(out, slug, title, html) do
    File.mkdir_p!(out)
    File.write!(Path.join(out, slug <> ".html"), "<h1>#{escape(title)}</h1>\n" <> html)
  end

  defp publish_all(to_publish, rendered) do
    req = client(env!("KILN_URL"), env!("KILN_DOCS_API_KEY"))
    type_name = System.get_env("KILN_DOCS_TYPE", "doc")
    entries = {"/entries", "entry", [{"type_name", type_name}]}
    pages = {"/pages", "page", []}

    # Resolved up front even when every guide already exists: a missing type is
    # a setup mistake worth failing on before any page is touched.
    type_id = type_id(req, type_name)
    create_entry = &%{"slug" => &1, "type_definition_id" => type_id}

    results =
      Enum.map(to_publish, fn doc ->
        report(doc.slug, upsert(req, entries, doc.slug, doc.title, doc.html, create_entry))
      end) ++
        [
          report(
            @index_slug,
            upsert(
              req,
              pages,
              @index_slug,
              "Documentation",
              index_html(rendered),
              &%{"slug" => &1, "path_alias" => @index_alias}
            )
          )
        ]

    failed = Enum.count(results, &(&1 == :error))
    if failed > 0, do: System.halt(1), else: IO.puts("done")
  end

  defp report(slug, {:ok, outcome, _record}), do: IO.puts("  #{outcome}  #{slug}")

  defp report(slug, {:error, message}) do
    IO.puts(:stderr, "  FAILED  #{slug}: #{message}")
    :error
  end

  defp type_id(req, type_name) do
    case System.get_env("KILN_DOCS_TYPE_ID") do
      unset when unset in [nil, ""] -> look_up_type(req, type_name)
      id -> id
    end
  end

  defp look_up_type(req, type_name) do
    case request(req, :get, "/type-definitions/by-name/#{URI.encode(type_name)}", []) do
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

  defp env!(name) do
    case System.get_env(name) do
      value when value not in [nil, ""] -> value
      _ -> raise "#{name} is not set"
    end
  end
end

PublishDocs.main(System.argv())
