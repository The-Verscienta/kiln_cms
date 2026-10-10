# The logic behind scripts/publish_releases.exs, kept apart from its
# `Mix.install` and `main/1` call so test/scripts/ can load it against the
# app's own copies of earmark_parser, req and jason. Read
# scripts/publish_releases.exs for what is published, and the site setup.

Code.require_file("common.exs", __DIR__)

defmodule PublishReleases do
  @moduledoc false

  alias KilnPublish.{API, Markdown}

  @repo_url "https://github.com/The-Verscienta/kiln_cms"
  @changelog_dir "docs/changelog"

  # A page slug may not equal a content type's path segment (`SlugAvailable`):
  # `/releases` is the release type's section URL. A `path_alias` may, and
  # answers before the 404 does — the same arrangement as /docs.
  @index_slug "release-notes"
  @index_title "Release notes"

  # The custom fields the `release` type must define, by machine name, and the
  # field types each may have. `required?` fields fail the run when missing;
  # the value a release carries is always written.
  @fields [
    %{name: "version", types: ["string"], label: "Version", note: "e.g. 1.0.0, no leading v"},
    %{name: "released_on", types: ["date"], label: "Released on", note: "YYYY-MM-DD"},
    %{
      name: "release_url",
      types: ["url", "string"],
      label: "Release URL",
      note: "the GitHub release"
    },
    %{name: "highlights", types: ["text"], label: "Highlights", note: "one per line"}
  ]

  # `KilnCMS.Limits.paragraph/0`, the longest text a paragraph-sized field
  # takes elsewhere; highlights past it are left to the body.
  @highlights_limit 4_000

  # The content slug pattern (`KilnCMS.CMS.Content`'s `match(:slug, …)`).
  @slug_pattern ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  def fields, do: @fields
  def index_slug, do: @index_slug

  # ── Versions ──────────────────────────────────────────────────────────────

  @doc """
  `{:ok, %{tag, version, prerelease?}}` for `v1.0.0`, `1.0.0` or
  `v1.1.0-rc.1`; `{:error, message}` for anything else.
  """
  def parse_version(input) when is_binary(input) do
    version = input |> String.trim() |> String.replace_prefix("v", "")

    case Version.parse(version) do
      {:ok, %Version{build: nil} = parsed} ->
        {:ok, %{tag: "v" <> version, version: version, prerelease?: parsed.pre != []}}

      _ ->
        {:error, "#{inspect(input)} is not a release version (expected e.g. v1.0.0)"}
    end
  end

  @doc """
  The entry slug for a tag: `v1.0.0` → `v1-0-0`, `v1.1.0-rc.1` →
  `v1-1-0-rc-1`. A slug is lowercase letters, digits and single hyphens, so
  every dot becomes a hyphen.
  """
  def slug(tag) do
    slug =
      tag
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if Regex.match?(@slug_pattern, slug), do: slug, else: raise("no slug for #{inspect(tag)}")
  end

  @doc "The GitHub release page for a tag."
  def release_url(tag), do: "#{@repo_url}/releases/tag/#{tag}"

  @doc """
  Every final release with long-form notes in `dir`, newest first. The
  directory holds one `vX.Y.Z.md` per release plus `unreleased.md`; a
  pre-release has no file of its own.
  """
  def catalogue(dir \\ @changelog_dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn file ->
      with "v" <> _ <- file,
           ".md" <- Path.extname(file),
           {:ok, %{prerelease?: false} = parsed} <- parse_version(Path.rootname(file)) do
        [parsed]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.version, &(Version.compare(&1, &2) == :gt))
  end

  @doc """
  The long-form notes for a release: `docs/changelog/<tag>.md`, or — for a
  pre-release, whose notes are still accumulating — `unreleased.md`.
  """
  def source(%{tag: tag, prerelease?: prerelease?}, dir \\ @changelog_dir) do
    own = Path.join(dir, tag <> ".md")

    cond do
      File.exists?(own) -> {:ok, own}
      prerelease? -> {:ok, Path.join(dir, "unreleased.md")}
      true -> {:error, "#{own} does not exist (a release's long-form notes are cut there)"}
    end
  end

  # ── CHANGELOG.md ──────────────────────────────────────────────────────────

  @doc """
  The CHANGELOG.md section for `version` as `{date | nil, markdown}`, or nil
  when the file has none. A pre-release reads the `[Unreleased]` section,
  which is where its entries still are.
  """
  def changelog_section(changelog, %{version: version, prerelease?: prerelease?}) do
    heading = if prerelease?, do: "Unreleased", else: version
    pattern = ~r/^## \[#{Regex.escape(heading)}\](?: - (\d{4}-\d{2}-\d{2}))?[ \t]*$/m

    case Regex.run(pattern, changelog, return: :index) do
      [{start, length} | date] ->
        rest = binary_part(changelog, start + length, byte_size(changelog) - start - length)
        [body | _] = Regex.split(~r/^## /m, rest, parts: 2)

        date =
          case date do
            [{d_start, d_length}] -> binary_part(changelog, d_start, d_length)
            _ -> nil
          end

        {date, body}

      nil ->
        nil
    end
  end

  # The summary sections a reader deciding whether to upgrade needs, in the
  # order CHANGELOG.md lists them. Changed/Fixed/Security stay in the body.
  @highlight_sections ["Upgrade notes", "Breaking", "Added"]

  @doc """
  The release's highlights, one per line: the bold lead of each summary line
  under Upgrade notes, Breaking and Added in its CHANGELOG.md section. Whole
  lines past #{@highlights_limit} characters are left to the body.
  """
  def highlights(nil), do: ""

  def highlights(section_markdown) do
    section_markdown
    |> Markdown.parse("CHANGELOG.md")
    |> chunk_by_h3()
    |> Enum.filter(fn {heading, _nodes} -> heading in @highlight_sections end)
    |> Enum.sort_by(fn {heading, _} -> Enum.find_index(@highlight_sections, &(&1 == heading)) end)
    |> Enum.flat_map(fn {_heading, nodes} -> Enum.flat_map(nodes, &leads/1) end)
    |> Enum.reduce_while({[], 0}, fn line, {acc, size} ->
      size = size + String.length(line) + 1

      if size > @highlights_limit + 1,
        do: {:halt, {acc, size}},
        else: {:cont, {[line | acc], size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp chunk_by_h3(nodes) do
    nodes
    |> Enum.reduce([], fn
      {"h3", _, children, _}, acc ->
        [{children |> Markdown.plain_text() |> String.trim(), []} | acc]

      _node, [] ->
        []

      node, [{heading, kids} | acc] ->
        [{heading, [node | kids]} | acc]
    end)
    |> Enum.map(fn {heading, kids} -> {heading, Enum.reverse(kids)} end)
  end

  defp leads({"ul", _, items, _}), do: Enum.flat_map(items, &lead/1)
  defp leads(_node), do: []

  # A summary line is `- **Lead sentence.** (links)`; the lead is the first
  # `<strong>`, wherever earmark_parser put it (a tight list item has it bare,
  # a loose one inside a `<p>`).
  defp lead({"li", _, children, _}) do
    case first_strong(children) do
      nil -> []
      text -> [text |> Markdown.decode() |> String.replace(~r/\s+/, " ") |> String.trim()]
    end
  end

  defp lead(_node), do: []

  defp first_strong([{"strong", _, kids, _} | _]), do: Markdown.plain_text(kids)
  defp first_strong([{"p", _, kids, _} | _]), do: first_strong(kids)

  defp first_strong([text | rest]) when is_binary(text),
    do: if(String.trim(text) == "", do: first_strong(rest))

  defp first_strong(_), do: nil

  # ── Body ──────────────────────────────────────────────────────────────────

  @doc """
  The long-form notes as HTML. The H1 (`KilnCMS 1.0.0 — full release notes`)
  goes — the entry's title prints instead — and so does the stock paragraph
  pointing back at CHANGELOG.md, which reads as a note to repo readers.
  Relative links resolve to GitHub at the release's own tag, so a link from
  1.0's notes shows the file as 1.0 shipped it.
  """
  def render(markdown, source, tag) do
    ast = markdown |> Markdown.strip_front_matter() |> Markdown.parse(source)
    {_h1, ast} = Markdown.pop_h1(ast)

    ast
    |> drop_boilerplate()
    |> Markdown.map_ast(&rewrite(&1, source, tag))
    |> Markdown.render()
  end

  defp drop_boilerplate([{"p", _, children, _} = p | rest]) do
    if children |> Markdown.plain_text() |> String.starts_with?("The long-form entries behind"),
      do: rest,
      else: [p | rest]
  end

  defp drop_boilerplate(ast), do: ast

  defp rewrite({"a", attrs, children, meta}, source, tag),
    do: {"a", Markdown.update_attr(attrs, "href", &link(&1, source, tag)), children, meta}

  defp rewrite({"img", attrs, children, meta}, source, tag),
    do: {"img", Markdown.update_attr(attrs, "src", &asset(&1, source, tag)), children, meta}

  defp rewrite(node, _source, _tag), do: node

  @doc "A relative link in `source`, as its GitHub URL at `tag`."
  def link(href, source, tag) do
    case Markdown.repo_path(href, source) do
      nil -> href
      {path, fragment} -> "#{@repo_url}/blob/#{tag}/#{path}#{fragment}"
    end
  end

  defp asset(src, source, tag) do
    case Markdown.repo_path(src, source) do
      nil ->
        src

      {path, _fragment} ->
        "https://raw.githubusercontent.com/The-Verscienta/kiln_cms/#{tag}/#{path}"
    end
  end

  # ── Building a release ────────────────────────────────────────────────────

  @doc """
  Everything one entry needs, from the files: `version` (parsed), `date`, the
  long-form `html` and the `highlights`. `date` is `opts[:date]`, else the
  CHANGELOG.md heading's, else the tag's (`git log`); `{:error, _}` when none
  answers or the notes are missing.
  """
  def build(parsed, opts \\ []) do
    dir = Keyword.get(opts, :dir, @changelog_dir)
    changelog = opts |> Keyword.get(:changelog, "CHANGELOG.md") |> File.read!()
    {heading_date, section} = changelog_section(changelog, parsed) || {nil, nil}

    with {:ok, source} <- source(parsed, dir),
         {:ok, date} <- date(opts[:date] || heading_date || tag_date(parsed.tag), parsed.tag) do
      {:ok,
       Map.merge(parsed, %{
         slug: slug(parsed.tag),
         title: "KilnCMS " <> parsed.version,
         date: date,
         release_url: release_url(parsed.tag),
         highlights: highlights(section),
         source: source,
         html: render(File.read!(source), source, parsed.tag)
       })}
    end
  end

  defp date(nil, tag),
    do:
      {:error,
       "no release date for #{tag}: no dated `## [x.y.z] - YYYY-MM-DD` heading in CHANGELOG.md, no tag to date it by; pass --date"}

  defp date(value, tag) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "#{inspect(value)} is not a date (YYYY-MM-DD) for #{tag}"}
    end
  end

  @doc "The tag's commit date, `YYYY-MM-DD`, or nil when the tag isn't here."
  def tag_date(tag) do
    case System.cmd("git", ["log", "-1", "--format=%cs", tag <> "^{commit}", "--"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> if out =~ ~r/\A\d{4}-\d{2}-\d{2}\s*\z/, do: String.trim(out)
      _ -> nil
    end
  rescue
    # No git on PATH.
    ErlangError -> nil
  end

  @doc """
  The JSON:API attributes an entry is written with — the shape the site
  stores, and what the #1877 updates feed reads back:

      %{
        "title" => "KilnCMS 1.0.0",
        "block_tree" => [%{"_type" => "rich_text", "legacy_html" => "…"}],
        "custom_fields" => %{
          "version" => "1.0.0",
          "released_on" => "2026-10-02",
          "release_url" => "https://github.com/…/releases/tag/v1.0.0",
          "highlights" => "lead one\\nlead two"
        }
      }
  """
  def entry_attrs(release) do
    %{
      "title" => release.title,
      "block_tree" => API.rich_text_tree(release.html),
      "custom_fields" => %{
        "version" => release.version,
        "released_on" => release.date,
        "release_url" => release.release_url,
        "highlights" => release.highlights
      }
    }
  end

  @doc """
  The `/releases` index page body: every final release, newest first.
  `releases` is `[%{version, slug, date}]`; `segment` is the type's
  path segment.
  """
  def index_html(releases, segment) do
    items =
      Enum.map_join(releases, fn release ->
        ~s(<li><a href="/#{segment}/#{release.slug}">KilnCMS #{Markdown.escape(release.version)}</a>) <>
          " — " <> Markdown.escape_text(release.date) <> "</li>"
      end)

    "<p>What changed in each Kiln release, and what to do before upgrading. " <>
      ~s(Every release is also on <a href="#{@repo_url}/releases">GitHub</a>.</p>) <>
      "<ul>#{items}</ul>"
  end

  # The newsletter sign-up under the list (#1870). It has to come from here:
  # the index is rebuilt on every run, which replaces its whole block tree, so
  # a block an editor added by hand would be gone at the next release.
  @signup_block %{
    "_type" => "newsletter_signup",
    "heading" => "Get the release notes by email",
    "intro" => "One email per release, with what changed and what to do before upgrading."
  }

  @doc """
  The `/releases` index page's attributes: the list, then the newsletter
  sign-up when the site has that block (`signup_supported?/1`).
  """
  def index_page(releases, segment, signup?) do
    blocks = API.rich_text_tree(index_html(releases, segment))

    %{
      "title" => @index_title,
      "block_tree" => if(signup?, do: blocks ++ [@signup_block], else: blocks)
    }
  end

  @doc """
  Whether a `GET /api/schema` body names the `newsletter_signup` block. A
  site on a Kiln without it would refuse the whole index write over that
  one block, so the index goes out without the sign-up instead.
  """
  def signup_supported?(%{"$defs" => %{"block_newsletter_signup" => _}}), do: true
  def signup_supported?(_body), do: false

  # ── The site's release type ───────────────────────────────────────────────

  @doc """
  Checks a `GET /type-definitions/by-name/:name?include=field_definitions`
  body against `fields/0`: `{:ok, %{id, path_segment}}`, or `{:error,
  message}` naming every missing or mistyped field.
  """
  def check_type(%{"data" => %{"id" => id, "attributes" => attrs}} = body, type_name) do
    defined =
      for %{"type" => "field_definition", "attributes" => field} <- Map.get(body, "included", []),
          into: %{},
          do: {field["name"], to_string(field["field_type"])}

    problems = Enum.flat_map(@fields, &field_problem(&1, Map.get(defined, &1.name)))

    case problems do
      [] ->
        {:ok, %{id: id, path_segment: attrs["path_segment"]}}

      _ ->
        {:error,
         """
         the "#{type_name}" content type is missing fields this script writes:
         #{Enum.map_join(problems, "\n", &("  - " <> &1))}
         """}
    end
  end

  defp field_problem(field, nil), do: ["`#{field.name}` is missing"]

  defp field_problem(field, type) do
    if type in field.types,
      do: [],
      else: ["`#{field.name}` is a #{type} field; make it #{Enum.join(field.types, " or ")}"]
  end

  @doc "How to set the type up, for an error message."
  def type_setup(type_name) do
    fields =
      Enum.map_join(@fields, "\n", fn f ->
        "    #{f.name}  (#{hd(f.types)}, label \"#{f.label}\"): #{f.note}"
      end)

    """
    In /editor/types, create (or edit) the type named "#{type_name}" with path
    segment "releases", and give it these custom fields:
    #{fields}
    The API key must be a :read_write key on an admin account.
    """
  end

  # ── Publishing ────────────────────────────────────────────────────────────

  def publish(releases, index) do
    req = API.client(API.env!("KILN_URL"), API.env!("KILN_RELEASES_API_KEY"))
    type_name = System.get_env("KILN_RELEASES_TYPE", "release")

    # Resolved up front even when every release already exists: a missing
    # type or field is a setup mistake worth failing on before anything is
    # touched.
    type =
      with {:ok, body} <- API.type_definition(req, type_name),
           {:ok, type} <- check_type(body, type_name) do
        type
      else
        {:error, message} ->
          fail!(
            "could not use the \"#{type_name}\" content type: #{message}\n\n" <>
              type_setup(type_name)
          )
      end

    entries = {"/entries", "entry", [{"type_name", type_name}]}
    pages = {"/pages", "page", []}
    create_entry = &%{"slug" => &1, "type_definition_id" => type.id}

    results =
      Enum.map(releases, fn release ->
        API.report(
          release.slug,
          API.upsert(req, entries, release.slug, entry_attrs(release), create_entry)
        )
      end)

    # Rebuilt on every run, so a new release is listed the moment it is
    # published.
    page = index_page(index, type.path_segment, signup?(req))

    alias_path = "/" <> type.path_segment
    create_page = &%{"slug" => &1, "path_alias" => alias_path}

    results =
      results ++ [API.report(@index_slug, API.upsert(req, pages, @index_slug, page, create_page))]

    if Enum.any?(results, &(&1 == :error)), do: System.halt(1), else: IO.puts("done")
  end

  # A schema the site can't serve costs the sign-up, not the run: the list is
  # what the index is for.
  defp signup?(req) do
    case API.schema(req) do
      {:ok, body} ->
        supported? = signup_supported?(body)

        if not supported?,
          do: IO.puts("  note  the site has no newsletter_signup block; the index has no sign-up")

        supported?

      {:error, message} ->
        IO.puts(:stderr, "  note  could not read the site's schema (#{message}); no sign-up")
        false
    end
  end

  # ── CLI ───────────────────────────────────────────────────────────────────

  @switches [
    version: :string,
    all: :boolean,
    prerelease: :boolean,
    date: :string,
    dry_run: :boolean,
    out: :string
  ]

  def main(argv) do
    {opts, rest} = OptionParser.parse!(argv, strict: @switches)
    if rest != [], do: usage!("unexpected arguments: #{Enum.join(rest, " ")}")

    releases = opts |> select() |> Enum.flat_map(&build_or_skip(&1, opts))

    index = index_entries(releases)
    IO.puts("#{length(releases)} release(s) selected")

    if opts[:dry_run],
      do: dry_run(releases, index, opts[:out]),
      else: publish(releases, index)
  end

  defp select(opts) do
    case {opts[:all], opts[:version]} do
      {true, nil} ->
        if opts[:date], do: usage!("--date applies to one --version, not --all")
        catalogue()

      {nil, version} when is_binary(version) ->
        version |> parse_version() |> select_version(opts[:prerelease])

      _ ->
        usage!("pass exactly one of --version vX.Y.Z or --all")
    end
  end

  defp select_version({:ok, %{prerelease?: true} = parsed}, true), do: [parsed]

  defp select_version({:ok, %{prerelease?: true} = parsed}, _flag) do
    IO.puts("#{parsed.tag} is a pre-release: not published (pass --prerelease to publish it)")
    System.halt(0)
  end

  defp select_version({:ok, parsed}, _flag), do: [parsed]
  defp select_version({:error, message}, _flag), do: usage!(message)

  # A backfill passes over a release it cannot date (0.1.0: never tagged, no
  # dated heading) — there is no GitHub release to link it to either. One
  # named release that cannot be built is the operator's mistake, and fails.
  defp build_or_skip(parsed, opts) do
    case build(parsed, date: opts[:date]) do
      {:ok, release} ->
        [release]

      {:error, message} ->
        if opts[:all], do: IO.puts(:stderr, "  skipped  #{message}"), else: fail!(message)
        []
    end
  end

  # Every final release the index lists: the ones `--all` publishes, i.e.
  # those with a date (the CHANGELOG.md heading, else the tag). An undated one
  # has no entry to link to.
  defp index_entries(releases) do
    changelog = File.read!("CHANGELOG.md")
    built = Map.new(releases, &{&1.tag, &1})

    Enum.flat_map(catalogue(), fn parsed ->
      case Map.fetch(built, parsed.tag) do
        {:ok, release} -> [release]
        :error -> dated(parsed, changelog)
      end
    end)
  end

  defp dated(parsed, changelog) do
    {date, _} = changelog_section(changelog, parsed) || {nil, nil}

    case date || tag_date(parsed.tag) do
      nil -> []
      date -> [Map.merge(parsed, %{slug: slug(parsed.tag), date: date})]
    end
  end

  defp dry_run(releases, index, out) do
    for release <- releases do
      IO.puts(
        "  /releases/#{release.slug}  #{release.title}  #{release.date}  " <>
          "(#{byte_size(release.html)} bytes, #{length(String.split(release.highlights, "\n", trim: true))} highlights)"
      )

      if out do
        write_file(
          out,
          release.slug <> ".html",
          "<h1>#{Markdown.escape(release.title)}</h1>\n" <> release.html
        )

        attrs = put_in(entry_attrs(release), ["block_tree"], "(see #{release.slug}.html)")
        write_file(out, release.slug <> ".json", Jason.encode!(attrs, pretty: true))
      end
    end

    if out,
      do:
        write_file(
          out,
          @index_slug <> ".html",
          "<h1>#{@index_title}</h1>\n" <> index_html(index, "releases")
        )
  end

  defp write_file(out, name, content) do
    File.mkdir_p!(out)
    File.write!(Path.join(out, name), content)
  end

  defp fail!(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp usage!(message) do
    IO.puts(:stderr, """
    #{message}

    usage: elixir scripts/publish_releases.exs --version v1.0.0 [--prerelease] [--date YYYY-MM-DD]
           elixir scripts/publish_releases.exs --all
           ... [--dry-run [--out DIR]]
    """)

    System.halt(2)
  end
end
