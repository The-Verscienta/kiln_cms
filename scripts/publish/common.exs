# The code scripts/publish_docs.exs and scripts/publish_releases.exs share:
# Markdown → HTML and the JSON:API client that upserts content by slug.
#
# Loaded with `Code.require_file/1` by both scripts, after their `Mix.install`
# (earmark_parser, req, jason), and by test/scripts/ against the app's own
# copies of those three deps. Nothing here may reach a `KilnCMS.*` module: CI
# publishes without compiling the application.

defmodule KilnPublish.Markdown do
  @moduledoc """
  Markdown → HTML for content published over the API.

  earmark_parser ONLY. Not `earmark`: that package is retired on Hex and
  carries a stored-XSS advisory in its HTML renderer, so nothing in this repo
  may install it. Its `Earmark.Transform` is replaced by `render/1` below — a
  port of `KilnCMS.Markdown`'s renderer, which a script cannot call.
  """

  # Same options as `KilnCMS.Markdown`, so a page reads here the way the same
  # Markdown pasted into the editor would. `{:error, ast, messages}` is
  # earmark_parser's "parsed, with warnings" (an unclosed fence, a stray `]`):
  # the tree is still the document, so it publishes, and the warnings go to
  # stderr where the workflow log keeps them.
  @doc "Parses Markdown to earmark_parser's AST; `source` labels warnings."
  def parse(markdown, source) do
    {ast, messages} =
      case EarmarkParser.as_ast(markdown, gfm_tables: true, breaks: false, pure_links: true) do
        {:ok, ast, messages} -> {ast, messages}
        {:error, ast, messages} -> {ast, messages}
      end

    for {severity, line, message} <- messages,
        do: IO.puts(:stderr, "  #{severity} #{source}:#{line}: #{message}")

    ast
  end

  def strip_front_matter("---\n" <> rest = markdown) do
    case String.split(rest, "\n---\n", parts: 2) do
      [_front, body] -> body
      [_] -> markdown
    end
  end

  def strip_front_matter(markdown), do: markdown

  @doc """
  The page's search-result description: the text of a
  `<!-- seo-description: … -->` comment, or nil.

  A comment rather than YAML front matter because ExDoc renders the same files
  and has no front matter: a `---` block would print in the HexDocs page as a
  rule and a heading. A comment is invisible in both places, and `render/1`
  drops it from the published body.
  """
  def seo_description(markdown) do
    case Regex.run(~r/<!--\s*seo-description:\s*(.*?)\s*-->/s, markdown) do
      [_, text] -> text |> String.replace(~r/\s+/, " ") |> presence()
      nil -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(text), do: text

  @doc """
  Splits off a leading H1 as `{heading | nil, rest}`. The page template prints
  the title, so the document's own H1 would print twice.
  """
  def pop_h1([{"h1", _attrs, children, _meta} | rest]) do
    case children |> plain_text() |> String.trim() do
      "" -> {nil, rest}
      heading -> {heading, rest}
    end
  end

  def pop_h1(ast), do: {nil, ast}

  @doc """
  `Earmark.Transform.map_ast(ast, fun, _ignore_strings = true)`: rewrite each
  element, then descend into what the rewrite returned.
  """
  def map_ast(nodes, fun) when is_list(nodes), do: Enum.map(nodes, &map_ast(&1, fun))

  def map_ast({_tag, _attrs, _children, _meta} = node, fun) do
    {tag, attrs, children, meta} = fun.(node)
    {tag, attrs, map_ast(children, fun), meta}
  end

  def map_ast(other, _fun), do: other

  @doc "Applies `fun` to the value of attribute `name`, wherever it is set."
  def update_attr(attrs, name, fun) do
    Enum.map(attrs, fn
      {^name, value} -> {name, fun.(value)}
      other -> other
    end)
  end

  @doc """
  `{repo-relative path, "#fragment" | ""}` for a relative href written in the
  repo file `source`; nil for an absolute URL, a site path or a fragment.
  """
  def repo_path(href, source) do
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
  # which the scripts cannot call — CI publishes without compiling the
  # application, and that module reaches `KilnCMS.HTMLSanitizer` and
  # `KilnCMS.Blocks.Html`. Keep the two in step: same closed tag lists, same
  # escaping, same `language-` convention, so a page published from here and
  # the same Markdown pasted into the editor produce the same HTML.
  #
  # The one deliberate difference is raw HTML the author wrote. There is no
  # sanitizer here, so an element outside the lists below keeps its text and
  # loses its tag rather than being handed through — the guides write none
  # (the changelog's `<a id>` anchors are dropped this way), and
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

  @doc "Renders an earmark_parser AST to HTML."
  def render(nodes) when is_list(nodes), do: Enum.map_join(nodes, &render/1)

  def render(text) when is_binary(text), do: text |> strip_comments() |> escape_text()

  # An HTML comment: `{:comment, [], [lines], %{comment: true}}`, whose tag is
  # an atom and so matches none of the lists. Its text is a note to whoever
  # edits the file — the catch-all at the bottom would publish it as prose.
  def render({_tag, _attrs, _children, %{comment: true}}), do: ""

  def render({tag, _attrs, _children, _meta}) when tag in @dropped_raw, do: ""

  def render({"pre", _attrs, children, _meta}) do
    {language, text} =
      case children do
        [{"code", attrs, kids, _meta}] -> {code_language(attrs), plain_text(kids)}
        kids -> {nil, plain_text(kids)}
      end

    class = if language, do: ~s( class="language-#{escape(language)}"), else: ""
    "<pre><code#{class}>" <> escape(text) <> "</code></pre>"
  end

  def render({"code", _attrs, children, _meta}),
    do: "<code>" <> escape(plain_text(children)) <> "</code>"

  def render({"a", attrs, children, _meta}) do
    case attrs |> attr("href") |> safe_url(~w(http https mailto)) do
      nil -> render(children)
      href -> ~s(<a href="#{escape(href)}">) <> render(children) <> "</a>"
    end
  end

  def render({"img", attrs, _children, _meta}) do
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

  def render({tag, _attrs, children, _meta}) when tag in @plain_tags,
    do: "<#{tag}>" <> render(children) <> "</#{tag}>"

  def render({tag, _attrs, _children, _meta}) when tag in @void_tags, do: "<#{tag}>"

  # Anything else (an element the lists don't know): its text is still the
  # author's, the wrapper is not trusted.
  def render({_tag, _attrs, children, _meta}) when is_list(children), do: render(children)

  def render(_other), do: ""

  # `KilnCMS.HTMLSanitizer.safe_href/1` and `safe_image_src/1`, narrowed to
  # what a script can check without the application: an in-page fragment, a
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

  @doc "The text of an AST, without markup."
  def plain_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &plain_text/1)
  def plain_text(text) when is_binary(text), do: text
  def plain_text({_tag, _attrs, children, _meta}), do: plain_text(children)
  def plain_text(_other), do: ""

  # earmark_parser pre-escapes some attribute values (`alt`) and not others
  # (`href`), so every value is decoded before it is escaped exactly once.
  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} when is_binary(value) -> decode(value)
      _ -> nil
    end)
  end

  @doc "Undoes the five entities earmark_parser may have applied."
  def decode(value) do
    value
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  @doc "An attribute value or code content: every markup character."
  def escape(text) do
    text
    |> escape_text()
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&#39;")
  end

  @doc """
  A text run. Quotes are left alone: they are not markup in element content,
  and escaping them only makes a page's HTML harder to read in a diff.
  """
  def escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end

defmodule KilnPublish.API do
  @moduledoc """
  The JSON:API client the publish scripts write through: one record upserted
  by slug and published, and the dynamic-type lookup.
  """

  @jsonapi "application/vnd.api+json"

  def client(url, key) do
    Req.new(
      base_url: String.trim_trailing(url, "/") <> "/api/json",
      headers: [
        {"authorization", "Bearer " <> key},
        {"accept", @jsonapi},
        {"content-type", @jsonapi}
      ],
      retry: &retry/2,
      max_retries: 5
    )
  end

  # A full sync is ~3 requests a record, more than the site's 120/min `:api`
  # bucket, so a 429 mid-run is expected and must be waited out. `:transient`
  # honours `retry-after`, but a site whose rate limiter predates rounding it
  # up answers 0 in the window's last second, and three instant retries then
  # all land before the reopen (the v0.11.0 docs sync failed that way). Hence
  # a 1s floor.
  #
  # A 429 is refused before the action runs, so retrying one is safe for any
  # method; a 5xx is not for a POST, which may have created the entry.
  defp retry(_request, %Req.Response{status: 429} = response) do
    seconds =
      case Req.Response.get_header(response, "retry-after") do
        [value | _] ->
          case Integer.parse(String.trim(value)) do
            {seconds, ""} -> seconds
            _http_date_or_junk -> 1
          end

        [] ->
          1
      end

    {:delay, max(seconds, 1) * 1000}
  end

  defp retry(request, %Req.Response{status: status}),
    do: request.method != :post and status in [408, 500, 502, 503, 504]

  defp retry(request, %Req.TransportError{reason: reason}),
    do: request.method != :post and reason in [:timeout, :econnrefused, :closed]

  defp retry(_request, _response_or_exception), do: false

  @doc """
  A body of one typed rich_text block: 1.0 refuses the legacy `type`/`content`
  write shape (#1543). The HTML goes in `legacy_html` — exactly where the
  legacy shape put it — because its code blocks are what Portable Text cannot
  hold faithfully.
  """
  def rich_text_tree(html), do: [%{"_type" => "rich_text", "legacy_html" => html}]

  @doc """
  Creates or updates one record by slug, then publishes it if it isn't.

  `kind` is `{route, json_api_type, filters}`; `attrs` is written on both
  create and update, `create_attrs.(slug)` on create only.

  `block_tree` is replaced wholesale: the body has no hand-edited blocks whose
  ids would need to survive (#954 — ids only matter for admin-set nested
  values, and this key is an admin's anyway). `custom_fields` merges per key
  over what the record holds (`ApplyCustomFields`).
  """
  def upsert(req, kind, slug, attrs, create_attrs) do
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

  @doc "One JSON:API request: `{:ok, decoded_body}` on a 2xx, else `{:error, message}`."
  def request(req, method, path, opts) do
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

  @doc """
  A dynamic type by machine name, with its field definitions included:
  `{:ok, %{"data" => type, "included" => [field_definition, ...]}}`.
  """
  def type_definition(req, type_name) do
    request(req, :get, "/type-definitions/by-name/#{URI.encode(type_name)}",
      params: [include: "field_definitions"]
    )
  end

  @doc "Prints one upsert's outcome; returns `:error` for a failure."
  def report(slug, {:ok, outcome, _record}), do: IO.puts("  #{outcome}  #{slug}")

  def report(slug, {:error, message}) do
    IO.puts(:stderr, "  FAILED  #{slug}: #{message}")
    :error
  end

  def env!(name) do
    case System.get_env(name) do
      value when value not in [nil, ""] -> value
      _ -> raise "#{name} is not set"
    end
  end
end
