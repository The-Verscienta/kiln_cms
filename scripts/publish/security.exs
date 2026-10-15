# The logic behind scripts/publish_security.exs, kept apart from its
# `Mix.install` and `main/1` call so test/scripts/ can load it against the
# app's own copies of earmark_parser, req and jason. Read
# scripts/publish_security.exs for what is published, and the site setup.

Code.require_file("common.exs", __DIR__)

defmodule PublishSecurity do
  @moduledoc false

  alias KilnPublish.{API, Markdown}

  @repo "The-Verscienta/kiln_cms"
  @repo_url "https://github.com/" <> @repo
  @policy_source ".github/SECURITY.md"

  # The page's slug is its URL: `/security`. Nothing reserves the segment, and
  # the notice type's path segment is `security-notices`, so `SlugAvailable`
  # has nothing to object to.
  @page_slug "security"
  @page_title "Security"

  # The core's package name on every notice it publishes. A plugin's notice
  # (the registry, #1447) carries the plugin's Hex name in the same field, so
  # one type and one feed serve both.
  @core_package "kiln_cms"

  # The custom fields the `security_notice` type must define, by machine
  # name, and the field types each may have.
  @fields [
    %{
      name: "package",
      types: ["string"],
      label: "Package",
      note: "kiln_cms, or the plugin's Hex name"
    },
    %{
      name: "affected_versions",
      types: ["string"],
      label: "Affected versions",
      note: "e.g. >= 1.0.0, < 1.3.2"
    },
    %{
      name: "patched_versions",
      types: ["string"],
      label: "Patched versions",
      note: "e.g. 1.3.2, 1.2.4"
    },
    %{
      name: "severity",
      types: ["string"],
      label: "Severity",
      note: "low, medium, high or critical"
    },
    %{name: "advisory_id", types: ["string"], label: "Advisory ID", note: "GHSA-xxxx-xxxx-xxxx"},
    %{name: "cve_id", types: ["string"], label: "CVE", note: "empty when none was assigned"},
    %{name: "published_on", types: ["date"], label: "Published on", note: "YYYY-MM-DD"},
    %{
      name: "advisory_url",
      types: ["url", "string"],
      label: "Advisory URL",
      note: "the GitHub advisory"
    }
  ]

  # The repository-advisory API's vocabulary. The global advisory database
  # says `moderate` for the same level, so that is read as `medium`.
  @severities ~w(low medium high critical)

  # The content slug pattern (`KilnCMS.CMS.Content`'s `match(:slug, …)`).
  @slug_pattern ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  def fields, do: @fields
  def page_slug, do: @page_slug

  # ── Advisories ────────────────────────────────────────────────────────────

  @doc """
  The repository's published GitHub security advisories, as the REST API
  returns them. Published advisories on a public repository need no token;
  `GITHUB_TOKEN`, when set, only lifts the anonymous rate limit.

  A token GitHub refuses with a 401 or 403 (revoked, or scoped away from
  the endpoint) is dropped and the request made again without it: the
  published list never needed it.
  """
  def fetch_advisories(token \\ System.get_env("GITHUB_TOKEN")) do
    path = "/repos/#{@repo}/security-advisories"
    anonymous = fn -> fetch_pages(github([]), path, 1, []) end

    result =
      if token in [nil, ""] do
        anonymous.()
      else
        case fetch_pages(github([{"authorization", "Bearer " <> token}]), path, 1, []) do
          {:error, {status, _message}} when status in [401, 403] ->
            IO.puts("  note  GitHub refused the token (#{status}); reading without it")
            anonymous.()

          result ->
            result
        end
      end

    case result do
      {:error, {_status, message}} -> {:error, message}
      ok -> ok
    end
  end

  defp github(auth) do
    Req.new(
      base_url: "https://api.github.com",
      headers:
        [
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"}
        ] ++ auth
    )
  end

  # 100 a page, and every page until a short one: the project will not have
  # hundreds, but a silently truncated list would drop the oldest notices.
  defp fetch_pages(req, path, page, acc) do
    params = [state: "published", per_page: 100, page: page]

    case Req.get(req, url: path, params: params) do
      {:ok, %{status: 200, body: advisories}} when is_list(advisories) ->
        acc = acc ++ advisories

        if length(advisories) < 100,
          do: {:ok, acc},
          else: fetch_pages(req, path, page + 1, acc)

      {:ok, %{status: status, body: body}} ->
        {:error, {status, "GET #{path} → #{status}: #{inspect(body)}"}}

      {:error, exception} ->
        {:error, {nil, "#{path}: #{Exception.message(exception)}"}}
    end
  end

  @doc """
  One advisory as a notice: `{:ok, notice}`, `:withdrawn`, or `{:error,
  message}` for one this script cannot publish faithfully.

  A withdrawn advisory is not published. One already on the site stays there
  — notices are never unpublished from here — so withdraw it in the editor
  too.
  """
  def notice(%{"withdrawn_at" => withdrawn}) when withdrawn not in [nil, ""], do: :withdrawn

  def notice(%{"ghsa_id" => ghsa} = advisory) when is_binary(ghsa) do
    with {:ok, slug} <- notice_slug(ghsa),
         {:ok, date} <- published_on(advisory["published_at"], ghsa) do
      vulnerabilities = List.wrap(advisory["vulnerabilities"])

      {:ok,
       %{
         slug: slug,
         advisory_id: ghsa,
         cve_id: presence(advisory["cve_id"]),
         title: title(advisory),
         severity: severity(advisory["severity"]),
         package: package(vulnerabilities),
         affected_versions: join_ranges(vulnerabilities, "vulnerable_version_range"),
         patched_versions: join_ranges(vulnerabilities, "patched_versions"),
         published_on: date,
         advisory_url: advisory["html_url"] || "#{@repo_url}/security/advisories/#{ghsa}",
         html: render_description(advisory["description"] || "", ghsa)
       }}
    end
  end

  def notice(advisory), do: {:error, "an advisory with no ghsa_id: #{inspect(advisory)}"}

  @doc """
  `GHSA-6983-jfq8-485w` → `ghsa-6983-jfq8-485w`. The identifier is already
  letters, digits and single hyphens; only its case changes.
  """
  def notice_slug(ghsa) do
    slug = String.downcase(ghsa)

    if Regex.match?(@slug_pattern, slug),
      do: {:ok, slug},
      else: {:error, "#{inspect(ghsa)} does not make a slug"}
  end

  defp published_on(timestamp, ghsa) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, datetime |> DateTime.to_date() |> Date.to_iso8601()}
      _ -> {:error, "#{ghsa}: published_at #{inspect(timestamp)} is not a timestamp"}
    end
  end

  defp published_on(_timestamp, ghsa), do: {:error, "#{ghsa} has no published_at"}

  # The summary is the advisory's one-line headline, and the entry's title. A
  # maintainer writes it, but it is text all the same: `title` is a plain
  # string, and the delivery templates escape it.
  defp title(%{"summary" => summary, "ghsa_id" => ghsa}) when is_binary(summary) do
    case summary |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> ghsa
      text -> text
    end
  end

  defp title(%{"ghsa_id" => ghsa}), do: ghsa

  defp severity(value) when value in @severities, do: value
  defp severity("moderate"), do: "medium"
  defp severity(_unknown), do: "unknown"

  # Every package the advisory names, in its order. GitHub may record the
  # core under its Hex name or not at all (an advisory with no package
  # entry), so an empty list is the core.
  defp package(vulnerabilities) do
    names =
      vulnerabilities
      |> Enum.map(&get_in(&1, ["package", "name"]))
      |> Enum.map(&presence/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if names == [], do: @core_package, else: Enum.join(names, ", ")
  end

  # One range per vulnerability, in order. GitHub writes `>= 1.0.0, < 1.3.2`
  # in some advisories and `>= 1.0.0 and < 1.3.2` in others; both are kept as
  # written, because the reader compares them against a version by eye.
  defp join_ranges(vulnerabilities, key) do
    vulnerabilities
    |> Enum.map(&presence(&1[key]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> "unknown"
      ranges -> Enum.join(ranges, "; ")
    end
  end

  @doc """
  The advisory's description (Markdown, with GitHub's CRLFs) as HTML. Its
  links are absolute already; a relative one is resolved against the
  repository, the way GitHub shows it.
  """
  def render_description(markdown, ghsa) do
    markdown
    |> String.replace("\r\n", "\n")
    |> Markdown.parse(ghsa)
    |> Markdown.map_ast(&rewrite(&1, "README.md"))
    |> Markdown.render()
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp presence(_value), do: nil

  @doc """
  The JSON:API attributes a notice is written with:

      %{
        "title" => "Unbounded channel joins…",
        "block_tree" => [%{"_type" => "rich_text", "legacy_html" => "…"}],
        "custom_fields" => %{
          "package" => "kiln_cms",
          "affected_versions" => ">= 1.0.0, < 1.3.2",
          "patched_versions" => "1.3.2",
          "severity" => "high",
          "advisory_id" => "GHSA-…",
          "cve_id" => "CVE-…",           # absent when none was assigned
          "published_on" => "2026-10-20",
          "advisory_url" => "https://github.com/…/security/advisories/GHSA-…"
        }
      }

  `cve_id` is left out rather than written empty when the advisory has none:
  `custom_fields` merges per key, so a CVE assigned after publication fills
  in on the next run.
  """
  def entry_attrs(notice) do
    fields =
      %{
        "package" => notice.package,
        "affected_versions" => notice.affected_versions,
        "patched_versions" => notice.patched_versions,
        "severity" => notice.severity,
        "advisory_id" => notice.advisory_id,
        "published_on" => notice.published_on,
        "advisory_url" => notice.advisory_url
      }

    fields = if notice.cve_id, do: Map.put(fields, "cve_id", notice.cve_id), else: fields

    %{
      "title" => notice.title,
      "block_tree" => API.rich_text_tree(notice.html),
      "custom_fields" => fields
    }
  end

  # ── The /security page ────────────────────────────────────────────────────

  @doc """
  `.github/SECURITY.md` as HTML: its H1 goes (the page title prints instead),
  and so does its opening pointer to the published copy, which this is.
  Relative links point at the file on GitHub's `main`, where the policy they
  cite lives.
  """
  def render_policy(markdown, source \\ @policy_source) do
    ast = markdown |> Markdown.strip_front_matter() |> Markdown.parse(source)
    {_h1, ast} = Markdown.pop_h1(ast)

    ast
    |> drop_self_reference()
    |> Markdown.map_ast(&rewrite(&1, source))
    |> Markdown.render()
  end

  # SECURITY.md opens by pointing GitHub readers at the published copy; on
  # the published copy that sentence points at itself.
  defp drop_self_reference([{"p", _, children, _} = p | rest]) do
    if children
       |> Markdown.plain_text()
       |> String.starts_with?("This policy is also published at"),
       do: rest,
       else: [p | rest]
  end

  defp drop_self_reference(ast), do: ast

  defp rewrite({"a", attrs, children, meta}, source),
    do: {"a", Markdown.update_attr(attrs, "href", &link(&1, source)), children, meta}

  defp rewrite(node, _source), do: node

  @doc "A relative link in `source`, as its GitHub URL on `main`."
  def link(href, source) do
    case Markdown.repo_path(href, source) do
      nil -> href
      {path, fragment} -> "#{@repo_url}/blob/main/#{path}#{fragment}"
    end
  end

  @doc """
  The notices section under the policy: every published notice, newest
  first, and the feed to follow them by. `notices` is `[%{slug, title,
  published_on, severity, package}]`; `segment` is the type's path segment.
  """
  def notices_html(notices, segment) do
    feed = "/#{segment}/feed.xml"

    list =
      case notices do
        [] ->
          "<p>No security notices have been published.</p>"

        _ ->
          items =
            Enum.map_join(notices, fn notice ->
              ~s(<li><a href="/#{segment}/#{notice.slug}">#{Markdown.escape_text(notice.title)}</a>) <>
                " — " <>
                Markdown.escape_text(
                  "#{notice.package}, #{notice.severity}, #{notice.published_on}"
                ) <> "</li>"
            end)

          "<ul>#{items}</ul>"
      end

    # Not "Security notices": SECURITY.md has a section of that name, which
    # explains them, and this list follows it on the same page.
    "<h2>All security notices</h2>" <>
      ~s(<p>Newest first. Follow them in a feed reader: <a href="#{feed}">#{feed}</a> ) <>
      ~s[(or <a href="/#{segment}/feed.json">JSON Feed</a>).</p>] <>
      list
  end

  @doc "The `/security` page's attributes: the policy, then the notices."
  def page_attrs(policy_html, notices, segment) do
    %{
      "title" => @page_title,
      "seo_description" =>
        "How to report a vulnerability in Kiln, which release lines get security fixes, and every security notice published for the core.",
      "block_tree" => API.rich_text_tree(policy_html <> notices_html(notices, segment))
    }
  end

  @doc "Newest first, then by advisory id, so a re-run lists them identically."
  def sort_notices(notices),
    do: Enum.sort_by(notices, &{&1.published_on, &1.advisory_id}, :desc)

  # ── The site's security_notice type ───────────────────────────────────────

  @doc """
  Checks a `GET /type-definitions/by-name/:name?include=field_definitions`
  body against `fields/0`: `{:ok, %{id, path_segment, feed?}}`, or `{:error,
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
        {:ok,
         %{
           id: id,
           path_segment: attrs["path_segment"],
           feed?: attrs["has_published_feed"] == true
         }}

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
    segment "security-notices", tick "Published feed", and give it these
    custom fields:
    #{fields}
    The API key must be a :read_write key on an admin account.
    """
  end

  # ── Publishing ────────────────────────────────────────────────────────────

  def publish(notices, policy_html) do
    req = API.client(API.env!("KILN_URL"), API.env!("KILN_SECURITY_API_KEY"))
    type_name = System.get_env("KILN_SECURITY_TYPE", "security_notice")

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

    # A type without its feed still publishes; the page's feed link 404s
    # until an admin ticks the box, which is worth saying in the log.
    if not type.feed?,
      do:
        IO.puts(
          "  note  \"#{type_name}\" has no published feed: tick it in /editor/types, or /#{type.path_segment}/feed.xml is a 404"
        )

    entries = {"/entries", "entry", [{"type_name", type_name}]}
    pages = {"/pages", "page", []}
    create_entry = &%{"slug" => &1, "type_definition_id" => type.id}

    results =
      Enum.map(notices, fn notice ->
        API.report(
          notice.slug,
          API.upsert(req, entries, notice.slug, entry_attrs(notice), create_entry)
        )
      end)

    page = page_attrs(policy_html, notices, type.path_segment)
    create_page = &%{"slug" => &1}

    results =
      results ++ [API.report(@page_slug, API.upsert(req, pages, @page_slug, page, create_page))]

    if Enum.any?(results, &(&1 == :error)), do: System.halt(1), else: IO.puts("done")
  end

  # ── CLI ───────────────────────────────────────────────────────────────────

  @switches [advisories: :string, dry_run: :boolean, out: :string]

  def main(argv) do
    {opts, rest} = OptionParser.parse!(argv, strict: @switches)
    if rest != [], do: usage!("unexpected arguments: #{Enum.join(rest, " ")}")

    advisories =
      case opts[:advisories] do
        nil -> fetch_advisories()
        path -> path |> File.read!() |> Jason.decode()
      end
      |> case do
        {:ok, list} when is_list(list) -> list
        {:ok, other} -> fail!("expected a JSON list of advisories, got #{inspect(other)}")
        {:error, message} -> fail!("could not read the advisories: #{inspect(message)}")
      end

    notices = advisories |> Enum.flat_map(&notice_or_skip/1) |> sort_notices()
    policy_html = @policy_source |> File.read!() |> render_policy()
    IO.puts("#{length(notices)} notice(s) to publish")

    if opts[:dry_run],
      do: dry_run(notices, policy_html, opts[:out]),
      else: publish(notices, policy_html)
  end

  # An advisory this script cannot read is skipped with a message rather than
  # failing the run: the policy page and every other notice still go out, and
  # the workflow log names it.
  defp notice_or_skip(advisory) do
    case notice(advisory) do
      {:ok, notice} ->
        [notice]

      :withdrawn ->
        IO.puts("  skipped  #{advisory["ghsa_id"]}: withdrawn")
        []

      {:error, message} ->
        IO.puts(:stderr, "  skipped  #{message}")
        []
    end
  end

  defp dry_run(notices, policy_html, out) do
    for notice <- notices do
      IO.puts(
        "  /security-notices/#{notice.slug}  #{notice.package} #{notice.severity}  #{notice.published_on}"
      )

      if out do
        write_file(
          out,
          notice.slug <> ".html",
          "<h1>#{Markdown.escape(notice.title)}</h1>\n" <> notice.html
        )

        attrs = put_in(entry_attrs(notice), ["block_tree"], "(see #{notice.slug}.html)")
        write_file(out, notice.slug <> ".json", Jason.encode!(attrs, pretty: true))
      end
    end

    if out do
      page = page_attrs(policy_html, notices, "security-notices")
      [%{"legacy_html" => html}] = page["block_tree"]
      write_file(out, @page_slug <> ".html", "<h1>#{@page_title}</h1>\n" <> html)
    end
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

    usage: elixir scripts/publish_security.exs [--advisories FILE] [--dry-run [--out DIR]]
    """)

    System.halt(2)
  end
end
