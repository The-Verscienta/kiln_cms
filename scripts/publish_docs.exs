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
# compiling the application, and Markdown rendering stays out of the release.
# The server treats the HTML it sends as untrusted — the rich-text cast
# sanitizes it like any other API write.
#
# Renamed or deleted guides are not unpublished; do that in the editor.

Mix.install([
  {:earmark, "~> 1.4"},
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
    {:ok, ast, _messages} =
      markdown |> strip_front_matter() |> Earmark.Parser.as_ast(gfm: true)

    {h1, ast} = pop_h1(ast)
    ast = Earmark.Transform.map_ast(ast, &rewrite(&1, doc.path, slugs), true)
    {doc.title || h1 || doc.slug, Earmark.Transform.transform(ast, compact_output: true)}
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
  defp pop_h1([{"h1", _, children, _} | rest]), do: {text(children), rest}
  defp pop_h1(ast), do: {nil, ast}

  defp text(nodes) when is_list(nodes), do: nodes |> Enum.map_join(&text/1) |> String.trim()
  defp text({_tag, _attrs, children, _meta}), do: text(children)
  defp text(binary) when is_binary(binary), do: binary

  defp rewrite({"a", attrs, children, meta}, source, slugs),
    do: {"a", update_attr(attrs, "href", &link(&1, source, slugs)), children, meta}

  defp rewrite({"img", attrs, children, meta}, source, _slugs),
    do: {"img", update_attr(attrs, "src", &asset(&1, source)), children, meta}

  # Fenced code: Earmark writes `class="elixir"`, and the rich-text scrubber
  # keeps only `language-<lang>` (and only for a language Kiln highlights).
  defp rewrite({"code", attrs, children, meta}, _source, _slugs) do
    attrs =
      Enum.flat_map(attrs, fn
        {"class", "inline"} -> []
        {"class", lang} -> [{"class", "language-" <> lang}]
        other -> [other]
      end)

    {"code", attrs, children, meta}
  end

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

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
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
