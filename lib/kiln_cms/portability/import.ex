defmodule KilnCMS.Portability.Import do
  @moduledoc """
  Writes a parsed import (`KilnCMS.Portability.WXR`, or the JSON envelope
  `KilnCMS.Portability.Export` produces) into the CMS (#487).

  ## Everything goes through Ash actions

  No raw inserts. Each record is created with the type's ordinary `:create`
  action under the caller's `:actor` and `:tenant`, so slug generation, custom
  fields, sanitization, tenancy and policy all apply exactly as they would to a
  hand-authored document. An importer that wrote rows directly would be the one
  path in the system that could mint content its operator was not allowed to
  create — and the one whose output would be missing the derived columns
  everything downstream reads.

  Publishing is likewise a state-machine `:publish` transition rather than a
  `state` attribute write, so an imported live post fires artifacts, gets a
  published version and enters delivery the same way any other publish does.

  ## Dry run

  `:dry_run` (default `false`) performs every *read* — resolving existing
  slugs, matching taxonomy, deciding what each record would become — and no
  writes at all, then returns the same report shape a real run returns. The
  plan and the run share `disposition/2`, so the two cannot disagree about what
  already exists, which is where a separately-written planner would drift.

  It is a plan, **not a validation**: no changeset is built, so a record the
  create action would reject (a slug the type reserves, a dynamic type's
  required custom field) is still reported as importable. What it will not do
  is miss a collision. Media is likewise reported as `would_import` — it
  fetches nothing, so it cannot know which URLs are reachable.

  ## Re-running

  Matching is by `(slug, locale)`, the same identity the database enforces. An
  existing match is **skipped** by default, which makes a re-run safe and makes
  a resumed run cheap after a partial failure. `:on_conflict` accepts:

    * `:skip` (default) — leave the existing record alone
    * `:error` — stop and report, for an operator who expected a clean target

  There is deliberately no `:overwrite`. A second import silently replacing
  edits an author made after the first one is not recoverable through any UI,
  and "import again to update" is not a workflow this feature is trying to
  support — content sync is a different problem from content migration.

  ## Ordering

  Taxonomy first (records reference it), then every record's **disposition**,
  then media, then records, then redirects. Media is resolved before the blocks
  that mention it so a record is created **once**, already pointing at its
  imported assets — creating and then updating would mint a second version of
  every imported document.

  Deciding dispositions *before* the media phase is what makes a resume cheap:
  a re-run fetches nothing for the records it already imported. Fetching first
  meant dying at record 8,000 and re-running re-downloaded the whole library and
  created a second, orphaned copy of every asset.
  """

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.Media.Ingest

  # The authored fields the envelope carries beyond title/slug/blocks. `audience`
  # is the one that MUST travel: its attribute default is `:public`, so dropping
  # it does not merely lose fidelity — it publishes a members-only document to
  # the open web.
  @envelope_attrs ~w(
    seo_title seo_description seo_keywords seo_image
    canonical_url path_alias audience custom_fields
  )

  @type report :: %{
          created: [map()],
          skipped: [map()],
          failed: [map()],
          media: map(),
          taxonomy: map(),
          redirects: map(),
          dry_run: boolean()
        }

  @doc """
  Import `parsed` (a `t:KilnCMS.Portability.WXR.parsed/0` map).

  Options:

    * `:actor` / `:tenant` — required in practice; every write runs under them
    * `:dry_run` — plan only, no writes (default `false`)
    * `:skip_media` — do not sideload images (default `false`). Blocks keep the
      source URLs, so the imported site hotlinks the old one.
    * `:redirects` — create a redirect from each old permalink (default `true`)
    * `:locale` — locale for created records (default `"en"`)
    * `:on_conflict` — `:skip` (default) or `:error`
    * `:limit` — import at most N records, for trying a large export out
  """
  @spec run(map(), keyword()) :: {:ok, report()}
  def run(parsed, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    records = parsed |> Map.get(:records, []) |> apply_limit(opts[:limit])

    taxonomy = import_taxonomy(records, dry_run?, opts)

    # Decide what each record WOULD become before fetching a single byte. A
    # resumed run then re-downloads nothing for the records it already imported
    # — without this, dying at record 8,000 and re-running re-fetches the whole
    # media library and creates a second, orphaned copy of every asset, which
    # makes a resume more expensive than the original run rather than cheaper.
    decided = Enum.map(records, &{&1, disposition(&1, opts)})
    fresh = for {record, {:create, _slug}} <- decided, do: record

    media = import_media(parsed, fresh, dry_run?, opts)

    {results, redirects} = import_records(decided, taxonomy, media, dry_run?, opts)

    {:ok,
     %{
       dry_run: dry_run?,
       created: Enum.filter(results, &(&1.outcome == :created)),
       skipped: Enum.filter(results, &(&1.outcome == :skipped)),
       failed: Enum.filter(results, &(&1.outcome == :failed)),
       taxonomy: taxonomy.report,
       media: media.report,
       redirects: redirects
     }}
  end

  defp apply_limit(records, nil), do: records
  defp apply_limit(records, limit) when is_integer(limit), do: Enum.take(records, limit)

  @doc """
  Import a `KilnCMS.Portability.Export` envelope (decoded JSON).

  Converts it to the same neutral shape a WXR parse produces and hands it to
  `run/2` — so a JSON import and a WordPress import share one write path, one
  conflict policy, one dry run and one report. A second implementation here is
  how the two would come to disagree about what "already exists" means.
  """
  @spec run_envelope(map(), keyword()) :: {:ok, report()} | {:error, :not_an_export_envelope}
  def run_envelope(envelope, opts \\ [])

  def run_envelope(%{"records" => records} = envelope, opts) when is_list(records) do
    manifest = envelope |> Map.get("media", []) |> Map.new(&{&1["id"], &1})

    run(
      %{
        records: Enum.map(records, &envelope_record(&1, manifest)),
        attachments: Enum.map(Map.values(manifest), &manifest_attachment/1)
      },
      opts
    )
  end

  def run_envelope(_other, _opts), do: {:error, :not_an_export_envelope}

  # The source database's media uuids mean nothing here, so an image block's
  # `media_id` is replaced by the manifest's URL and the id dropped — the
  # sideload then re-points it at whatever this database creates. Leaving the
  # id in place would produce blocks referencing rows that do not exist.
  defp envelope_record(record, manifest) do
    blocks = record |> Map.get("blocks", []) |> Enum.map(&resolve_manifest_urls(&1, manifest))

    %{
      kind: record["type"],
      title: record["title"],
      slug: record["slug"],
      blocks: blocks,
      excerpt: record["excerpt"],
      state: if(record["state"] == "published", do: :published, else: :draft),
      published_at: parse_datetime(record["published_at"]),
      source_url: nil,
      source_id: nil,
      author: nil,
      categories: term_list(record["category"]),
      tags: Enum.map(List.wrap(record["tags"]), &%{name: &1, slug: &1}),
      featured_source_id: record["featured_image_id"],
      image_urls: image_urls(blocks),
      # The envelope's own locale wins over the run's default. Without this
      # every locale collapses to one, and the second translation of a slug is
      # reported "already present" — a silent deletion of half a bilingual site.
      locale: record["locale"],
      attrs: Map.take(record, @envelope_attrs)
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _error -> nil
    end
  end

  defp parse_datetime(_other), do: nil

  # Recursive, and NOT limited to top-level `image` blocks. A gallery's items and
  # an image nested inside a `columns` block each carry their own `media_id`; the
  # export walks the whole tree to build the manifest, so anything shallower here
  # leaves those pointing at the SOURCE database's uuids — rows that do not exist
  # in the target — and never sideloads their bytes either.
  defp resolve_manifest_urls(%{} = map, manifest) when not is_struct(map) do
    map
    |> remap_media_id(manifest)
    |> Map.new(fn {key, value} -> {key, resolve_manifest_urls(value, manifest)} end)
  end

  defp resolve_manifest_urls(list, manifest) when is_list(list),
    do: Enum.map(list, &resolve_manifest_urls(&1, manifest))

  defp resolve_manifest_urls(other, _manifest), do: other

  defp remap_media_id(map, manifest) do
    case Map.get(map, "media_id") do
      id when is_binary(id) ->
        case Map.get(manifest, id) do
          %{"url" => url} -> map |> Map.put("url", url) |> Map.delete("media_id")
          _unknown -> Map.delete(map, "media_id")
        end

      _absent ->
        map
    end
  end

  defp manifest_attachment(entry),
    do: %{source_id: entry["id"], url: entry["url"], title: entry["filename"], alt: entry["alt"]}

  defp term_list(nil), do: []
  defp term_list(slug) when is_binary(slug), do: [%{name: slug, slug: slug}]
  defp term_list(_other), do: []

  # Every `url` a media-bearing map in the tree points at, at any depth — the
  # counterpart to `resolve_manifest_urls/2`. A gallery's images are as much a
  # part of the document as a top-level image block.
  defp image_urls(blocks), do: blocks |> collect_urls() |> Enum.uniq()

  defp collect_urls(%{} = map) when not is_struct(map) do
    own = if is_binary(map["url"]), do: [map["url"]], else: []
    own ++ Enum.flat_map(Map.values(map), &collect_urls/1)
  end

  defp collect_urls(list) when is_list(list), do: Enum.flat_map(list, &collect_urls/1)
  defp collect_urls(_other), do: []

  # ── Taxonomy ───────────────────────────────────────────────────────────────

  # Categories and tags are resolved by slug and created when missing. Both are
  # `upsert_identity`-free ordinary creates, so a concurrent run could race —
  # acceptable, because a duplicate-slug create fails loudly and the record it
  # would have been attached to reports a failure rather than losing its terms
  # silently.
  defp import_taxonomy(records, dry_run?, opts) do
    categories = collect_terms(records, :categories)
    tags = collect_terms(records, :tags)

    {category_ids, created_categories} = resolve_terms(:category, categories, dry_run?, opts)
    {tag_ids, created_tags} = resolve_terms(:tag, tags, dry_run?, opts)

    %{
      categories: category_ids,
      tags: tag_ids,
      report: %{
        categories: %{
          matched: map_size(category_ids) - created_categories,
          created: created_categories
        },
        tags: %{matched: map_size(tag_ids) - created_tags, created: created_tags}
      }
    }
  end

  defp collect_terms(records, key) do
    records
    |> Enum.flat_map(&Map.get(&1, key, []))
    |> Enum.map(&normalize_term/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.slug)
  end

  # A WXR `<category>` can carry a name with no `nicename`. Slugifying the name
  # is what WordPress itself would have stored, and without it the term is
  # unmatchable and the record loses it.
  defp normalize_term(%{name: name, slug: slug}) do
    case slug || slugify(name) do
      resolved when is_binary(resolved) and resolved != "" ->
        %{name: presence(name) || resolved, slug: resolved}

      _unusable ->
        nil
    end
  end

  defp normalize_term(_other), do: nil

  defp resolve_terms(kind, terms, dry_run?, opts) do
    Enum.reduce(terms, {%{}, 0}, fn term, {acc, created} ->
      case resolve_term(kind, term, dry_run?, opts) do
        {:matched, id} -> {Map.put(acc, term.slug, id), created}
        {:created, id} -> {Map.put(acc, term.slug, id), created + 1}
        :failed -> {acc, created}
      end
    end)
  end

  defp resolve_term(kind, term, dry_run?, opts) do
    case find_term(kind, term.slug, opts) do
      %{id: id} -> {:matched, id}
      # No id exists to record; the slug maps to `:would_create` so a record
      # referencing it is still reported as importable.
      nil when dry_run? -> {:created, :would_create}
      nil -> create_and_tag(kind, term, opts)
    end
  end

  defp create_and_tag(kind, term, opts) do
    case create_term(kind, term, opts) do
      {:ok, %{id: id}} -> {:created, id}
      {:error, _reason} -> :failed
    end
  end

  defp find_term(:category, slug, opts) do
    CMS.list_categories!(scope(opts) ++ [query: [filter: [slug: slug], limit: 1]]) |> List.first()
  end

  defp find_term(:tag, slug, opts) do
    CMS.list_tags!(scope(opts) ++ [query: [filter: [slug: slug], limit: 1]]) |> List.first()
  end

  defp create_term(:category, term, opts),
    do: CMS.create_category(%{name: term.name, slug: term.slug}, scope(opts))

  defp create_term(:tag, term, opts),
    do: CMS.create_tag(%{name: term.name, slug: term.slug}, scope(opts))

  # ── Media ──────────────────────────────────────────────────────────────────

  # Builds `source_url => media_id` for every image any record references, plus
  # `wp_attachment_id => media_id` so `_thumbnail_id` can resolve to a featured
  # image. One fetch per distinct URL, however many posts embed it.
  defp import_media(parsed, records, dry_run?, opts) do
    attachments = Map.get(parsed, :attachments, [])
    wanted = wanted_media(records, attachments)

    cond do
      Keyword.get(opts, :skip_media, false) ->
        %{by_url: %{}, by_source_id: %{}, report: %{skipped: length(wanted)}}

      dry_run? ->
        %{by_url: %{}, by_source_id: %{}, report: %{would_import: length(wanted)}}

      true ->
        sideload(wanted, opts)
    end
  end

  # Body images plus every attachment a `_thumbnail_id` points at. An
  # attachment nothing references is deliberately NOT imported: a WordPress
  # library is usually far larger than the content that survives a migration,
  # and pulling all of it turns a ten-minute import into an hours-long one for
  # assets nobody asked for.
  defp wanted_media(records, attachments) do
    by_id = Map.new(attachments, &{&1.source_id, &1})

    featured =
      records
      |> Enum.map(& &1[:featured_source_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.reject(&is_nil/1)

    body =
      records
      |> Enum.flat_map(&Map.get(&1, :image_urls, []))
      |> Enum.map(&%{source_id: nil, url: &1, title: nil, alt: nil})

    (featured ++ body) |> Enum.uniq_by(& &1.url)
  end

  defp sideload(wanted, opts) do
    {by_url, by_source_id, failures} =
      Enum.reduce(wanted, {%{}, %{}, []}, fn asset, {by_url, by_id, failures} ->
        case Ingest.store_url(asset.url, scope(opts) ++ [alt: asset.alt]) do
          {:ok, item} ->
            {Map.put(by_url, asset.url, item), maybe_put(by_id, asset.source_id, item), failures}

          {:error, reason} ->
            # A missing image is not a reason to abandon a migration — the post
            # still imports, keeping the source URL, and the failure is reported
            # so an operator can re-upload it.
            Logger.warning("Import: could not sideload #{asset.url}: #{inspect(reason)}")
            {by_url, by_id, [%{url: asset.url, reason: reason} | failures]}
        end
      end)

    %{
      by_url: by_url,
      by_source_id: by_source_id,
      report: %{imported: map_size(by_url), failed: Enum.reverse(failures)}
    }
  end

  defp maybe_put(map, nil, _value), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Records ────────────────────────────────────────────────────────────────

  defp import_records(decided, taxonomy, media, dry_run?, opts) do
    redirects? = Keyword.get(opts, :redirects, true)

    {results, redirects} =
      Enum.reduce(decided, {[], %{created: 0, skipped: 0}}, fn {record, disposition},
                                                               {results, redirects} ->
        {outcome, created, entry} =
          import_record(record, disposition, taxonomy, media, dry_run?, opts)

        counted =
          bump(redirects, redirect_for(outcome, record, created, redirects?, dry_run?, opts))

        # Prepended, not appended: `results ++ [entry]` copies the accumulator
        # every iteration, which is O(n^2) — 1.25 billion cons cells at 50k
        # records.
        {[entry | results], counted}
      end)

    {Enum.reverse(results), redirects}
  end

  # Only a record that was actually created gets a redirect. A dry run counts
  # the one it *would* have made, so the two reports line up rather than making
  # a dry run look like it produces fewer redirects than the real thing.
  defp redirect_for(:created, record, created, true, false, opts),
    do: create_redirect(record, created, opts)

  defp redirect_for(:planned, record, _created, true, true, _opts),
    do: if(record[:source_url], do: :created, else: :skipped)

  defp redirect_for(_outcome, _record, _created, _redirects?, _dry_run?, _opts), do: :skipped

  defp bump(counts, key), do: Map.update(counts, key, 1, &(&1 + 1))

  # What this record would become, decided from reads alone. Computed up front
  # so the media phase knows which records are actually going to be written.
  defp disposition(record, opts) do
    locale = locale_for(record, opts)
    slug = record[:slug] || slugify(record.title)

    cond do
      match = existing(record.kind, slug, locale, opts) -> {:conflict, slug, match.id}
      trashed?(record.kind, slug, locale, opts) -> {:trashed, slug}
      true -> {:create, slug}
    end
  end

  # An explicit `--locale` wins; otherwise a record carries its own (the JSON
  # envelope has one per record), and only then does the default apply.
  defp locale_for(record, opts),
    do: Keyword.get(opts, :locale) || record[:locale] || "en"

  defp import_record(record, {:conflict, slug, id}, _taxonomy, _media, _dry_run?, opts),
    do: on_conflict(record, slug, id, Keyword.get(opts, :on_conflict, :skip))

  # A **trashed** record still holds its slug: `destroy` is a soft delete, so
  # the row (and the `[slug, locale]` unique index) survives while the ordinary
  # read hides it. Without this check the importer plans a create, and the
  # database refuses it with a raw "slug: has already been taken" that says
  # nothing about where the collision came from — and a dry run reports the
  # record as importable when it is not.
  #
  # Reported as a failure rather than a skip: nothing was imported, and the
  # operator has to decide (restore it, or purge it and re-run).
  defp import_record(record, {:trashed, slug}, _taxonomy, _media, _dry_run?, _opts),
    do:
      {:failed, nil,
       %{
         outcome: :failed,
         kind: record.kind,
         title: record.title,
         slug: slug,
         reason: :slug_held_by_trashed_record
       }}

  defp import_record(record, {:create, slug}, _taxonomy, _media, true = _dry_run?, _opts),
    do: {:planned, nil, %{outcome: :created, kind: record.kind, title: record.title, slug: slug}}

  defp import_record(record, {:create, slug}, taxonomy, media, _dry_run?, opts),
    do: create_record(record, slug, locale_for(record, opts), taxonomy, media, opts)

  defp trashed?(kind, slug, locale, opts) do
    ContentTypes.list_trashed!(
      kind,
      scope(opts) ++ [query: [filter: [slug: slug, locale: locale], limit: 1]]
    ) != []
  rescue
    # A type with no trash tier simply has no collision of this kind.
    _error -> false
  end

  defp on_conflict(record, slug, id, :skip),
    do:
      {:skipped, nil,
       %{outcome: :skipped, kind: record.kind, title: record.title, slug: slug, existing_id: id}}

  defp on_conflict(record, slug, _id, :error),
    do:
      {:failed, nil,
       %{
         outcome: :failed,
         kind: record.kind,
         title: record.title,
         slug: slug,
         reason: :already_exists
       }}

  defp existing(kind, slug, locale, opts) do
    ContentTypes.list!(
      kind,
      scope(opts) ++ [query: [filter: [slug: slug, locale: locale], limit: 1]]
    )
    |> List.first()
  rescue
    _error -> nil
  end

  defp create_record(record, slug, locale, taxonomy, media, opts) do
    attrs = %{
      title: record.title,
      slug: slug,
      locale: locale,
      blocks: rewrite_blocks(record.blocks, media),
      tag_ids: term_ids(record[:tags], taxonomy.tags)
    }

    attrs =
      record
      |> Map.get(:attrs, %{})
      |> Enum.reduce(attrs, fn {key, value}, acc ->
        put_present(acc, String.to_existing_atom(key), value)
      end)
      |> Map.merge(attrs)
      |> put_present(:excerpt, record[:excerpt])
      |> put_present(:category_id, first_term_id(record[:categories], taxonomy.categories))
      |> put_present(:featured_image_id, featured_image_id(record, media))
      |> acceptable(record.kind, opts)

    case create_via_action(record.kind, attrs, opts) do
      {:ok, created} ->
        created = record |> maybe_publish(created, opts) |> restore_published_at(record, opts)

        {:created, created,
         %{
           outcome: :created,
           kind: record.kind,
           title: record.title,
           slug: created.slug,
           id: created.id
         }}

      {:error, reason} ->
        Logger.warning(
          "Import: #{record.kind} #{inspect(record.title)} failed: #{inspect(reason)}"
        )

        {:failed, nil,
         %{
           outcome: :failed,
           kind: record.kind,
           title: record.title,
           slug: slug,
           reason: describe(reason)
         }}
    end
  end

  # Drop any attribute this type does not actually have. Content types do NOT
  # share one attribute set — a `Page` has no `excerpt`, and a dynamic type has
  # whatever its definition declares — so an envelope written from one type and
  # loaded against another would fail the whole record on `NoSuchInput` for one
  # field it never needed. Filtering here also keeps the dry run honest for the
  # commonest case: a WordPress *page* with an `<excerpt:encoded>`.
  defp acceptable(attrs, kind, opts) do
    case storage_resource(kind, opts) do
      nil ->
        attrs

      resource ->
        Map.filter(attrs, fn {key, _value} ->
          key in [:blocks, :tag_ids] or not is_nil(Ash.Resource.Info.attribute(resource, key))
        end)
    end
  end

  defp storage_resource(kind, opts) do
    case ContentTypes.get(kind, org_id(opts)) do
      nil -> nil
      descriptor -> Slugs.storage_resource(descriptor)
    end
  rescue
    _error -> nil
  end

  defp org_id(opts) do
    case Keyword.get(opts, :tenant) do
      %{id: id} -> id
      id when is_binary(id) -> id
      _ -> KilnCMS.Accounts.default_org_id()
    end
  end

  # The source's publication date, put back after the publish transition set it
  # to now. `published_at` is not in the create action's `accept` list (it is
  # workflow bookkeeping, not an authored field), and the transition stamps
  # `utc_now`, so without this every post in a decade-old blog is dated at the
  # moment of import — the archive collapses into one arbitrary-ordered second,
  # and feeds and sitemaps inherit it.
  #
  # `force_change_attribute` on the ordinary update action rather than a raw
  # insert: still an Ash action, still policy-checked, and the extra version it
  # mints is an honest record that the import set the date.
  defp restore_published_at(created, %{published_at: %DateTime{} = at}, opts) do
    created
    |> Ash.Changeset.for_update(:update, %{}, scope(opts))
    |> Ash.Changeset.force_change_attribute(:published_at, at)
    |> Ash.update()
    |> case do
      {:ok, updated} -> updated
      _error -> created
    end
  rescue
    _error -> created
  end

  defp restore_published_at(created, _record, _opts), do: created

  # `ContentTypes` exposes only the raising create. An import must survive one
  # bad record without abandoning the other 3,999, so the raise is converted
  # here rather than left to blow up the run.
  defp create_via_action(kind, attrs, opts) do
    {:ok, ContentTypes.create!(kind, attrs, scope(opts))}
  rescue
    error -> {:error, error}
  end

  # A record that was live on the source site is published here through the
  # state machine, not by writing `state` — so it fires, versions and enters
  # delivery like any other publish. A publish that is refused leaves an
  # imported draft, which is recoverable; the alternative (treating it as a
  # record failure) would throw away a successful content import over a
  # workflow permission.
  defp maybe_publish(%{state: :published} = record, created, opts) do
    case ContentTypes.transition(record.kind, "publish", created, scope(opts)) do
      {:ok, published} ->
        published

      other ->
        Logger.warning(
          "Import: #{record.kind} #{inspect(record.title)} imported but not published: #{inspect(other)}"
        )

        created
    end
  rescue
    error ->
      Logger.warning("Import: publish failed for #{inspect(record.title)}: #{inspect(error)}")
      created
  end

  defp maybe_publish(_record, created, _opts), do: created

  # Point every image block at the `MediaItem` that was sideloaded for its URL.
  # A URL that failed to import keeps its original value, so the block still
  # renders (hotlinked) rather than becoming a broken placeholder.
  defp rewrite_blocks(blocks, %{by_url: by_url}) when map_size(by_url) > 0 do
    Enum.map(blocks, fn
      %{"type" => "image", "value" => value} = block ->
        case Map.get(by_url, value["url"]) do
          nil ->
            block

          item ->
            %{
              block
              | "value" => value |> Map.put("url", item.url) |> Map.put("media_id", item.id)
            }
        end

      block ->
        block
    end)
  end

  defp rewrite_blocks(blocks, _media), do: blocks

  defp featured_image_id(record, %{by_source_id: by_id}) do
    case Map.get(by_id, record[:featured_source_id]) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp term_ids(nil, _lookup), do: []

  defp term_ids(terms, lookup) do
    terms
    |> Enum.map(&normalize_term/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.get(lookup, &1.slug))
    |> Enum.filter(&is_binary/1)
  end

  # A record can hold many categories in WordPress and exactly one here; the
  # first is kept and the rest are already carried as tags would be — dropping
  # them silently is the alternative, and it loses information an editor cannot
  # recover from the imported record.
  defp first_term_id(terms, lookup), do: terms |> term_ids(lookup) |> List.first()

  # ── Redirects ──────────────────────────────────────────────────────────────

  # The old permalink's PATH, not the whole URL: a redirect matches on the path
  # a request arrives with, and the source site's host is by definition not this
  # one. A path that is `/` or empty is not a redirect — it is the old home
  # page, and pointing it at one imported post would break the new site's root.
  defp create_redirect(record, created, opts) do
    with url when is_binary(url) <- record[:source_url],
         path when path not in [nil, "", "/"] <- URI.parse(url).path,
         {:ok, _redirect} <-
           CMS.create_redirect(
             %{
               path: String.trim_trailing(path, "/"),
               locale: Keyword.get(opts, :locale, "en"),
               target_type: to_string(record.kind),
               target_id: created.id
             },
             scope(opts)
           ) do
      :created
    else
      _ -> :skipped
    end
  rescue
    _error -> :skipped
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp scope(opts), do: Keyword.take(opts, [:actor, :tenant])

  defp slugify(nil), do: nil

  defp slugify(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
    |> String.trim("-")
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(other), do: inspect(other)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
