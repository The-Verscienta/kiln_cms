defmodule KilnCMS.Portability.Ghost do
  @moduledoc """
  Reads a Ghost JSON export into the neutral shape
  `KilnCMS.Portability.Import` loads (#1876) — the same shape
  `KilnCMS.Portability.WXR` produces from WordPress, so a Ghost migration gets
  the dry run, conflict policy, media sideloading, redirects and report for
  free.

  Pure, like `WXR`: it parses bytes and returns data, with no writes, no
  network and no policy checks, so `--dry-run` prints the plan this exact code
  produced.

  ## What a Ghost export is

  One JSON document, `{"db": [{"meta": …, "data": {table => [row]}}]}` — a dump
  of Ghost's tables, joined by id:

    * `posts` holds posts **and** pages, told apart by `type`. Each row carries
      the rendered `html`, which is what is read here; the editor's own source
      (`lexical`, or `mobiledoc` before Ghost 5) is Ghost-specific.
    * `tags` and `posts_tags` — the join, ordered by `sort_order`. A tag whose
      name starts with `#` is an **internal** tag (`visibility: "internal"`):
      theme plumbing, never shown to readers, so it is not imported.
    * `users` and `posts_authors` — likewise ordered; the first author is the
      byline.
    * `posts_meta` holds `meta_title`, `meta_description` and
      `feature_image_alt` since Ghost 4. Older exports keep the first two on
      the post row itself; both places are read.

  ## `__GHOST_URL__`

  Ghost 4+ stores its own URLs as `__GHOST_URL__/content/images/…` and the
  export keeps the placeholder; older exports store images root-relative
  (`/content/images/…`). Either way the images can only be fetched from the
  site, so `:site_url` completes them — and an export that needs it with no
  `:site_url` is refused up front rather than imported with every image broken.
  Links to the site's own pages (`href="__GHOST_URL__/other-post/"`) become
  root-relative instead, so they land on the new site and its redirects.

  Before Ghost 3 there was no `type` column: a boolean `page` told posts from
  pages, and it is read when `type` is absent.

  ## Status and visibility

  `published` is the only status that means live on the web. `scheduled`
  imports as a draft with its date intact, as WordPress' `future` does: this
  importer has no scheduling story, and publishing early is the one wrong guess
  that cannot be taken back. `sent` (or `posts_meta.email_only`) is an
  **email-only** post — Ghost never put
  it on the site — so it is a draft too, not something to publish now.

  A post Ghost restricted to members (`members`, `paid`, `tiers`) is gated here
  by `audience`. Its attribute default is `:public`, so dropping it would
  publish members-only writing to the open web. `members` lands in `:member`
  (or the first gated audience this instance configures). `paid` and `tiers`
  land in `:paid` when that audience is configured; otherwise in the same
  audience as `members`, with a note, because free members can then read
  them. With no gated audience at all
  (`config :kiln_cms, :audiences, [:public]`) nothing could hold it back, so it
  imports as a **draft** and the reason is reported.
  """

  alias KilnCMS.Blocks.Html
  alias KilnCMS.CMS.Audiences

  @placeholder "__GHOST_URL__"

  # `src="/content/…"` — root-relative, not protocol-relative (`//cdn…`).
  @relative_src ~r{(\ssrc=")/(?!/)}
  # `href="__GHOST_URL__/other-post/"` — a link to one of the site's own pages.
  @own_link ~r{href="__GHOST_URL__/?}

  # A Ghost export is the whole database as one JSON document, and decoding it
  # costs several times its size in terms. Past this, refuse with the size and
  # the remedy rather than let the VM be OOM-killed with no partial progress.
  @max_file_bytes 128 * 1024 * 1024

  @doc """
  Parse a Ghost export from a string.

  Options:

    * `:site_url` — the Ghost site's address (`https://blog.example.com`),
      substituted for `__GHOST_URL__`. Required when the export contains it.

  Returns `{:ok, parsed}` (a `t:KilnCMS.Portability.WXR.parsed/0` plus
  `:unreadable`, the posts that could not be converted and why) or
  `{:error, reason}`. A post with an unusable body is reported, not fatal: an
  export with three bad rows should still import the rest.
  """
  @spec parse(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse(json, opts \\ []) when is_binary(json) do
    site_url = opts |> Keyword.get(:site_url) |> normalize_site_url()

    with {:ok, decoded} <- decode(json),
         {:ok, data, meta} <- data(decoded),
         :ok <- check_site_url(json, data, site_url) do
      {:ok, build(data, meta, site_url)}
    end
  end

  @doc "`parse/2` from a file path, refusing files past the size ceiling."
  @spec parse_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  # The path comes from an operator's command line, which is already trusted to
  # name a file to read.
  # sobelow_skip ["Traversal.FileModule"]
  def parse_file(path, opts \\ []) when is_binary(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         :ok <- check_size(size),
         {:ok, json} <- File.read(path) do
      parse(json, opts)
    else
      {:error, {:too_large, _, _} = reason} -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, {:unreadable_file, reason}}
    end
  end

  @doc "The file-size ceiling `parse_file/2` enforces, in bytes."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  defp check_size(size) when size > @max_file_bytes,
    do: {:error, {:too_large, size, @max_file_bytes}}

  defp check_size(_size), do: :ok

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:malformed_json, Exception.message(error)}}
    end
  end

  # `db` is a list of one database. The meta is read for the version line in
  # the task's summary only.
  defp data(%{"db" => [%{"data" => %{"posts" => posts} = data} = db | _]}) when is_list(posts),
    do: {:ok, data, Map.get(db, "meta", %{})}

  defp data(_other), do: {:error, :not_a_ghost_export}

  # Ghost 4+ writes its own address as the placeholder; older exports store
  # images root-relative (`/content/images/…`). Either way the images can only
  # be fetched from the site, so its address is required.
  defp check_site_url(json, data, nil) do
    if String.contains?(json, @placeholder) or Enum.any?(rows(data, "posts"), &relative_images?/1),
      do: {:error, :site_url_required},
      else: :ok
  end

  defp check_site_url(_json, _data, _site_url), do: :ok

  defp relative_images?(post) do
    root_relative?(post["feature_image"]) or
      (is_binary(post["html"]) and Regex.match?(@relative_src, post["html"]))
  end

  defp root_relative?("/" <> rest), do: not String.starts_with?(rest, "/")
  defp root_relative?(_url), do: false

  defp normalize_site_url(nil), do: nil

  defp normalize_site_url(url) do
    case url |> String.trim() |> String.trim_trailing("/") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── Build ───────────────────────────────────────────────────────────────────

  defp build(data, meta, site_url) do
    users = rows(data, "users")
    tags = data |> rows("tags") |> Map.new(&{&1["id"], &1})
    posts_meta = data |> rows("posts_meta") |> Map.new(&{&1["post_id"], &1})
    tags_by_post = joined(data, "posts_tags", "tag_id")
    authors_by_post = joined(data, "posts_authors", "author_id")
    users_by_id = Map.new(users, &{&1["id"], &1})

    context = %{
      site_url: site_url,
      tags: tags,
      posts_meta: posts_meta,
      tags_by_post: tags_by_post,
      authors_by_post: authors_by_post,
      users: users_by_id
    }

    {records, unreadable} =
      data
      |> rows("posts")
      |> Enum.filter(&kind/1)
      |> Enum.reduce({[], []}, fn post, {ok, bad} ->
        case record(post, context) do
          {:ok, record} -> {[record | ok], bad}
          {:error, reason} -> {ok, [%{title: title(post), reason: reason} | bad]}
        end
      end)

    records = Enum.reverse(records)

    %{
      site: %{title: site_title(data), url: site_url, version: meta["version"]},
      records: records,
      attachments: records |> Enum.flat_map(& &1.attachments) |> Enum.uniq_by(& &1.source_id),
      authors: Enum.map(users, &author/1) |> Enum.reject(&is_nil(&1.login)),
      unreadable: Enum.reverse(unreadable)
    }
  end

  defp rows(data, table) do
    case Map.get(data, table) do
      rows when is_list(rows) -> Enum.filter(rows, &is_map/1)
      _ -> []
    end
  end

  # `post_id => [other_id]`, in the join's `sort_order` — the first tag is
  # Ghost's "primary tag", the first author the byline.
  defp joined(data, table, key) do
    data
    |> rows(table)
    |> Enum.sort_by(&(&1["sort_order"] || 0))
    |> Enum.group_by(& &1["post_id"], & &1[key])
  end

  defp site_title(data) do
    data
    |> rows("settings")
    |> Enum.find_value(fn
      %{"key" => "title", "value" => title} when is_binary(title) -> presence(title)
      _ -> nil
    end)
  end

  defp author(user) do
    %{login: presence(user["slug"]), email: presence(user["email"]), name: presence(user["name"])}
  end

  # ── Post → record ────────────────────────────────────────────────────────────

  defp record(post, context) do
    with {:ok, html} <- body(post) do
      meta = Map.get(context.posts_meta, post["id"], %{})
      {state, audience, notes} = state_and_audience(post, meta)
      notes = notes ++ unsupported_cards(html)
      html = expand_body(html, context.site_url)
      blocks = Html.to_blocks(html, autop: false, shortcodes: false)
      feature = feature_image(post, meta, context.site_url)

      {:ok,
       %{
         kind: kind(post),
         title: title(post),
         slug: presence(post["slug"]),
         blocks: blocks,
         excerpt: presence(post["custom_excerpt"]),
         state: state,
         published_at: parse_datetime(post["published_at"]),
         # Ghost's default permalink for both posts and pages is `/{slug}/`.
         # Only the path is used, to build the redirect.
         source_url: if(post["slug"], do: "/" <> post["slug"] <> "/"),
         source_id: post["id"],
         author: author_slug(post, context),
         categories: [],
         tags: tags(post, context),
         featured_source_id: feature && feature.source_id,
         attachments: List.wrap(feature),
         image_urls: image_urls(blocks),
         attrs: seo_attrs(post, meta) |> put_audience(audience),
         note: if(notes != [], do: Enum.join(notes, "; "))
       }}
    end
  rescue
    # One unreadable post must not lose the rest.
    error -> {:error, Exception.message(error)}
  end

  # `type` arrived in Ghost 3. Before it, a boolean `page` column told the two
  # apart; reading only `type` imported nothing from a Ghost 1 or 2 export.
  defp kind(%{"type" => "post"}), do: :post
  defp kind(%{"type" => "page"}), do: :page
  defp kind(%{"type" => nil} = post), do: legacy_kind(post)
  defp kind(%{"type" => _other}), do: nil
  defp kind(post), do: legacy_kind(post)

  defp legacy_kind(post), do: if(post["page"] in [true, 1], do: :page, else: :post)

  defp title(post), do: post |> Map.get("title") |> to_string() |> String.trim()

  defp body(%{"html" => html}) when is_binary(html), do: {:ok, html}

  # An old export with no rendered HTML holds the body only as mobiledoc, a
  # Ghost editor format. Importing it as an empty document would look like a
  # success and lose the writing, so it is reported instead.
  defp body(%{"mobiledoc" => doc}) when is_binary(doc),
    do: {:error, "the body is mobiledoc only, with no rendered HTML"}

  defp body(%{"lexical" => doc}) when is_binary(doc),
    do: {:error, "the body is lexical only, with no rendered HTML"}

  defp body(_post), do: {:ok, ""}

  # Links to the site's own pages become root-relative, so they land on this
  # site (and its redirects) rather than on the Ghost site being retired.
  # Images keep an absolute URL on the old site, which is where they are
  # fetched from.
  defp expand_body(html, site_url) do
    html = Regex.replace(@own_link, html, ~s(href="/))

    case site_url do
      nil -> html
      _ -> html |> expand(site_url) |> then(&Regex.replace(@relative_src, &1, "\\1#{site_url}/"))
    end
  end

  defp expand(text, nil), do: text
  defp expand(text, site_url), do: String.replace(text, @placeholder, site_url)

  defp expand_url(url, site_url) do
    if site_url && root_relative?(url), do: site_url <> url, else: expand(url, site_url)
  end

  # Cards with media `Html` has no block for. Their files would vanish without
  # a word, so the post says so.
  @unsupported_cards %{
    "kg-video-card" => "video",
    "kg-audio-card" => "audio",
    "kg-file-card" => "file download"
  }

  defp unsupported_cards(html) do
    case for({class, label} <- @unsupported_cards, String.contains?(html, class), do: label) do
      [] ->
        []

      labels ->
        [
          "has #{Enum.join(Enum.sort(labels), ", ")} cards, which do not import; move them by hand"
        ]
    end
  end

  defp state_and_audience(post, meta) do
    {state, note} = state(post["status"], meta["email_only"] in [true, 1])
    notes = List.wrap(note)

    case post["visibility"] do
      visibility when visibility in [nil, "public"] ->
        {state, :public, notes}

      visibility ->
        case audience_for(visibility) do
          nil ->
            {:draft, :public,
             notes ++
               [
                 "restricted to #{visibility} in Ghost, and this site has no gated audience " <>
                   "to hold it back, so it lands as a draft"
               ]}

          {audience, nil} ->
            {state, audience, notes}

          {audience, gating_note} ->
            {state, audience, notes ++ [gating_note]}
        end
    end
  end

  # `members` is any signed-in member. `paid` and `tiers` are narrower: they go
  # to a `:paid` audience when the site configures one, and otherwise to the
  # broader gated audience with a note, because free members could then read
  # them.
  defp audience_for(visibility) do
    case {visibility, gated_audience()} do
      {_visibility, nil} ->
        nil

      {"members", audience} ->
        {audience, nil}

      {visibility, audience} ->
        if :paid in Audiences.gated(),
          do: {:paid, nil},
          else:
            {audience,
             "#{visibility}-only in Ghost; gated to #{inspect(audience)}, which free " <>
               "members can read too"}
    end
  end

  # Email-only is a `sent` status in older exports and a `posts_meta.email_only`
  # flag in newer ones.
  @email_only "email-only in Ghost (never on the site); lands as a draft"

  defp state(_status, true = _email_only), do: {:draft, @email_only}
  defp state("sent", _email_only), do: {:draft, @email_only}
  defp state("published", _email_only), do: {:published, nil}

  defp state("scheduled", _email_only),
    do: {:draft, "scheduled in Ghost; lands as a draft with its date"}

  defp state(_draft, _email_only), do: {:draft, nil}

  defp gated_audience do
    if :member in Audiences.gated(), do: :member, else: List.first(Audiences.gated())
  end

  defp put_audience(attrs, :public), do: attrs
  defp put_audience(attrs, audience), do: Map.put(attrs, "audience", audience)

  # `meta_title` / `meta_description` moved from the post row to `posts_meta`
  # in Ghost 4; the newer place wins. `canonical_url` is deliberately NOT
  # carried — see `KilnCMS.Portability.Import`'s `@envelope_attrs`: it would
  # point search engines back at the site being left.
  defp seo_attrs(post, meta) do
    %{
      "seo_title" => presence(meta["meta_title"]) || presence(post["meta_title"]),
      "seo_description" =>
        presence(meta["meta_description"]) || presence(post["meta_description"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The feature image is a URL, not a library row as WordPress' `_thumbnail_id`
  # is, so it is its own attachment keyed by that URL.
  defp feature_image(post, meta, site_url) do
    case presence(post["feature_image"]) do
      nil ->
        nil

      url ->
        url = expand_url(url, site_url)
        %{source_id: url, url: url, title: nil, alt: presence(meta["feature_image_alt"])}
    end
  end

  defp author_slug(post, context) do
    with [id | _] <- Map.get(context.authors_by_post, post["id"]),
         %{"slug" => slug} <- Map.get(context.users, id) do
      presence(slug)
    else
      _ -> nil
    end
  end

  defp tags(post, context) do
    context.tags_by_post
    |> Map.get(post["id"], [])
    |> Enum.map(&Map.get(context.tags, &1))
    |> Enum.reject(&(is_nil(&1) or internal_tag?(&1)))
    |> Enum.map(&%{name: String.trim(to_string(&1["name"])), slug: presence(&1["slug"])})
    |> Enum.reject(&(&1.name == "" and is_nil(&1.slug)))
    |> Enum.uniq_by(& &1.slug)
  end

  defp internal_tag?(tag),
    do: tag["visibility"] == "internal" or String.starts_with?(to_string(tag["name"]), "#")

  # Read off the converted blocks, like `WXR`: the URLs that will actually be
  # rendered, which is what needs sideloading.
  defp image_urls(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "image"))
    |> Enum.map(& &1["value"]["url"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Ghost writes ISO 8601 with milliseconds and a `Z`.
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
