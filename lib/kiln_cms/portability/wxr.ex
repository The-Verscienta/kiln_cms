defmodule KilnCMS.Portability.WXR do
  @moduledoc """
  Reads a WordPress eXtended RSS export into the neutral shape
  `KilnCMS.Portability.Import` loads (#487).

  This module is **pure**: it parses bytes and returns data. It performs no
  writes, no network calls and no policy checks, which is what makes
  `--dry-run` honest — the plan a dry run prints is produced by exactly this
  code, not by a second implementation that might disagree with the real one.

  ## What WXR actually is

  RSS 2.0 with four WordPress namespaces bolted on. The parts that matter:

    * `channel/item` is everything — posts, pages, attachments, menu items and
      navigation entries all share one element type, discriminated by
      `wp:post_type`. Filtering on it is the whole importer.
    * `content:encoded` is the body, and it is **not** display HTML. Classic
      posts have no `<p>` tags at all (WordPress adds them at render time), so
      it must go through `KilnCMS.Blocks.Html`'s `autop` before it means what
      it looks like.
    * `<category>` carries *both* taxonomies, told apart by `domain`
      (`category` vs `post_tag`) — not by position.
    * `<link>` is the live permalink. It is the only record of where the
      content used to live, and it is why a WordPress import can produce
      working redirects at all.
    * `wp:postmeta` holds `_thumbnail_id`, which points at an *attachment
      item's* `wp:post_id` — so the featured image can only be resolved after
      every attachment has been read. Hence two passes.

  ## Dates

  `wp:post_date_gmt` is UTC and is preferred. It is `"0000-00-00 00:00:00"` for
  never-published content, which is not a date — treating it as one yields
  year 0 and a nonsensical publish timestamp, so it is read as absent.
  """

  import SweetXml, only: [sigil_x: 2]

  alias KilnCMS.Blocks.Html

  @typedoc """
  One importable record, source-neutral. `blocks` is typed-block input, ready
  for a create action; `source_url` is the old permalink a redirect is built
  from.
  """
  @type content_record :: %{
          kind: :post | :page,
          title: String.t(),
          slug: String.t() | nil,
          blocks: [map()],
          excerpt: String.t() | nil,
          state: :draft | :published,
          published_at: DateTime.t() | nil,
          source_url: String.t() | nil,
          source_id: String.t() | nil,
          author: String.t() | nil,
          categories: [%{name: String.t(), slug: String.t()}],
          tags: [%{name: String.t(), slug: String.t()}],
          featured_source_id: String.t() | nil,
          image_urls: [String.t()]
        }

  @type attachment :: %{
          source_id: String.t(),
          url: String.t(),
          title: String.t() | nil,
          alt: String.t() | nil
        }

  @type parsed :: %{
          site: %{title: String.t() | nil, url: String.t() | nil},
          records: [content_record()],
          attachments: [attachment()],
          authors: [%{login: String.t(), email: String.t() | nil, name: String.t() | nil}]
        }

  # The post types worth importing. `attachment` is read separately (it becomes
  # media, not content); everything else WordPress puts in this file —
  # `nav_menu_item`, `wp_block`, `revision`, `custom_css`, and whatever a plugin
  # invented — is deliberately ignored rather than guessed at.
  @importable %{"post" => :post, "page" => :page}

  @doc """
  Parse WXR from a string.

  Returns `{:ok, parsed}` or `{:error, reason}`. A file that is not XML at all,
  or is XML with no `<channel>`, is an error; a file with unreadable *items* is
  not — those items are skipped, because a 4,000-post export with three
  corrupt rows should import 3,997 posts.
  """
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    doc = SweetXml.parse(xml, dtd: :none)

    case SweetXml.xpath(doc, ~x"//channel"o) do
      nil ->
        {:error, :not_a_wxr_file}

      channel ->
        attachments = attachments(channel)

        {:ok,
         %{
           site: site(channel),
           records: records(channel),
           attachments: attachments,
           authors: authors(channel)
         }}
    end
  rescue
    # `xmerl` throws/exits on malformed input rather than returning an error,
    # and the shapes it produces are not worth enumerating — any failure to
    # parse is the same answer to the caller.
    error -> {:error, {:malformed_xml, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:malformed_xml, reason}}
    thrown -> {:error, {:malformed_xml, thrown}}
  end

  @doc """
  `parse/1` from a file path.

  Reads the whole file into memory. A WXR export is a single XML document with
  no streaming-friendly framing, and `xmerl` needs the complete tree anyway, so
  streaming would buy nothing — but it does mean a multi-gigabyte export is a
  multi-gigabyte allocation, which is why WordPress' own exporter splits large
  sites into several files.
  """
  @spec parse_file(Path.t()) :: {:ok, parsed()} | {:error, term()}
  # The path comes from an operator's command line or an admin upload, both of
  # which are already trusted to name a file to read.
  # sobelow_skip ["Traversal.FileModule"]
  def parse_file(path) when is_binary(path) do
    with :ok <- check_size(path),
         {:ok, xml} <- File.read(path) do
      parse(xml)
    else
      {:error, {:too_large, _, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:unreadable_file, reason}}
    end
  end

  # `SweetXml.parse/2` runs `:erlang.binary_to_list/1` before `:xmerl_scan`, so
  # the document becomes a charlist at ~16 bytes per source byte BEFORE the
  # element tree is built on top of it. A 200 MB export is ~3 GB of charlist and
  # several more of tree.
  #
  # Refusing up front, with the number and the remedy, beats the alternative:
  # an OOM kill has no error, no partial progress, and nothing telling the
  # operator that splitting the export is the answer.
  @max_file_bytes 64 * 1024 * 1024

  # sobelow_skip ["Traversal.FileModule"]
  defp check_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file_bytes ->
        {:error, {:too_large, size, @max_file_bytes}}

      {:ok, _stat} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Channel-level ──────────────────────────────────────────────────────────

  defp site(channel) do
    %{
      title: channel |> SweetXml.xpath(~x"./title/text()"So) |> presence(),
      url: channel |> SweetXml.xpath(~x"./link/text()"So) |> presence()
    }
  end

  defp authors(channel) do
    channel
    |> SweetXml.xpath(~x"./wp:author"l)
    |> Enum.map(fn author ->
      %{
        login: author |> SweetXml.xpath(~x"./wp:author_login/text()"So) |> to_string(),
        email: author |> SweetXml.xpath(~x"./wp:author_email/text()"So) |> presence(),
        name: author |> SweetXml.xpath(~x"./wp:author_display_name/text()"So) |> presence()
      }
    end)
    |> Enum.reject(&(&1.login == ""))
  end

  defp attachments(channel) do
    channel
    |> items()
    |> Enum.filter(&(post_type(&1) == "attachment"))
    |> Enum.map(&attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp attachment(item) do
    url = item |> SweetXml.xpath(~x"./wp:attachment_url/text()"So) |> presence()

    if url do
      %{
        source_id: post_id(item),
        url: url,
        title: item |> SweetXml.xpath(~x"./title/text()"So) |> presence(),
        alt: postmeta(item, "_wp_attachment_image_alt")
      }
    end
  end

  defp records(channel) do
    channel
    |> items()
    |> Enum.filter(&Map.has_key?(@importable, post_type(&1)))
    |> Enum.map(&record/1)
    |> Enum.reject(&is_nil/1)
  end

  defp items(channel), do: SweetXml.xpath(channel, ~x"./item"l)

  # ── Item → record ──────────────────────────────────────────────────────────

  defp record(item) do
    html = item |> SweetXml.xpath(~x"./content:encoded/text()"So) |> to_string()
    blocks = Html.to_blocks(html)

    %{
      kind: Map.fetch!(@importable, post_type(item)),
      title: item |> SweetXml.xpath(~x"./title/text()"So) |> to_string() |> String.trim(),
      slug: item |> SweetXml.xpath(~x"./wp:post_name/text()"So) |> presence() |> decode_slug(),
      blocks: blocks,
      excerpt: item |> SweetXml.xpath(~x"./excerpt:encoded/text()"So) |> presence(),
      state: state(item),
      published_at: published_at(item),
      source_url: item |> SweetXml.xpath(~x"./link/text()"So) |> presence(),
      source_id: post_id(item),
      author: item |> SweetXml.xpath(~x"./dc:creator/text()"So) |> presence(),
      categories: terms(item, "category"),
      tags: terms(item, "post_tag"),
      featured_source_id: postmeta(item, "_thumbnail_id"),
      image_urls: image_urls(blocks)
    }
  rescue
    # One unreadable item must not lose the other 3,999.
    _error -> nil
  end

  defp post_type(item), do: item |> SweetXml.xpath(~x"./wp:post_type/text()"So) |> to_string()
  defp post_id(item), do: item |> SweetXml.xpath(~x"./wp:post_id/text()"So) |> presence()

  # WordPress' `publish` is the only status that means live. `future` is a
  # scheduled post whose date has not arrived; importing it as published would
  # publish it early, and this importer has no scheduling story, so it lands as
  # a draft with its date intact for an editor to decide on. `private`,
  # `pending`, `draft` and `inherit` are all drafts.
  defp state(item) do
    case item |> SweetXml.xpath(~x"./wp:status/text()"So) |> to_string() do
      "publish" -> :published
      _other -> :draft
    end
  end

  defp published_at(item) do
    gmt = item |> SweetXml.xpath(~x"./wp:post_date_gmt/text()"So) |> presence()
    local = item |> SweetXml.xpath(~x"./wp:post_date/text()"So) |> presence()

    parse_datetime(gmt) || parse_datetime(local)
  end

  # `"2024-03-01 09:15:00"` — a space, not a `T`, and no offset. The GMT field
  # is UTC by definition; the local one is the site's wall clock, taken as UTC
  # only because the export carries no zone to do better with. Both are
  # approximations an editor can correct, which is preferable to dropping the
  # publication date of every post.
  defp parse_datetime(nil), do: nil
  defp parse_datetime("0000-00-00 00:00:00"), do: nil

  defp parse_datetime(value) do
    case value |> String.trim() |> String.replace(" ", "T") |> NaiveDateTime.from_iso8601() do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  # `<category domain="post_tag" nicename="how-to">How To</category>` — the
  # element name is `category` for BOTH taxonomies, so `domain` is the only
  # thing that tells a tag from a category.
  defp terms(item, domain) do
    item
    |> SweetXml.xpath(~x"./category[@domain='#{domain}']"l)
    |> Enum.map(fn node ->
      %{
        name: node |> SweetXml.xpath(~x"./text()"So) |> to_string() |> String.trim(),
        slug: node |> SweetXml.xpath(~x"./@nicename"So) |> presence() |> decode_slug()
      }
    end)
    |> Enum.reject(&(&1.name == "" and is_nil(&1.slug)))
    |> Enum.uniq_by(& &1.slug)
  end

  defp postmeta(item, key) do
    item
    |> SweetXml.xpath(~x"./wp:postmeta"l)
    |> Enum.find_value(fn meta ->
      if SweetXml.xpath(meta, ~x"./wp:meta_key/text()"So) |> to_string() == key,
        do: meta |> SweetXml.xpath(~x"./wp:meta_value/text()"So) |> presence()
    end)
  end

  # Every image the body references, so the importer knows what to sideload
  # before it rewrites the blocks. Read off the converted blocks rather than
  # re-scanned from the HTML: what matters is the set of URLs that will
  # actually be *rendered*, and `Html.to_blocks/2` has already dropped the ones
  # that live in stripped shortcodes or script tags.
  defp image_urls(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "image"))
    |> Enum.map(& &1["value"]["url"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # A non-ASCII slug is percent-encoded in WXR (`%d0%bf%d1%80%d0%b8`). Stored
  # decoded, so the slug generator sees real characters and the redirect built
  # from the old permalink still matches the encoded request path.
  defp decode_slug(nil), do: nil
  defp decode_slug(slug), do: URI.decode(slug)

  defp presence(nil), do: nil
  defp presence(value) when is_list(value), do: value |> to_string() |> presence()

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value
end
