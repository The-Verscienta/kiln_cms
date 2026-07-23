# Import the holistic-acupuncture Sanity export into KilnCMS.
#
#     mix run projects/acupuncture/priv/repo/acupuncture_import.exs path/to/kiln-export.json
#
# The export file is produced by the Astro repo's scripts/export-to-kiln.js:
# media entries (metadata-only, pointing at Cloudflare Images), categories,
# tags, and one record per document with blocks already in Kiln's typed shape
# (rich_text bodies are canonical Portable Text). Image blocks arrive with a
# "media_ref" (Sanity asset ref) which this script swaps for the created
# MediaItem's UUID + URL.
#
# Idempotent by natural key: media by URL, categories/tags by slug, content by
# slug — existing records are updated, missing ones created. Records publish
# unless the export marks them `"published": false`.
#
# After publishing, each record's `published_at` is restored to the Sanity
# value with a direct Repo update — the publish action stamps "now" and the
# attribute is deliberately not writable through the API, so a one-time
# migration bypass is the least invasive way to preserve original blog dates.
#
# Requires the acupuncture overlay to be active (config/project.exs registers
# Acupuncture.Catalog — see projects/acupuncture/README.md). Run
# projects/acupuncture/priv/repo/acupuncture_field_definitions.exs first
# (custom-field values are validated against the definitions on every write).

import Ecto.Query

alias Acupuncture.Catalog
alias KilnCMS.Accounts
alias KilnCMS.CMS
alias KilnCMS.Repo

[path | _] = System.argv()
export = path |> File.read!() |> Jason.decode!()

admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")

admin =
  case Accounts.get_user_by_email(admin_email, not_found_error?: false, authorize?: false) do
    {:ok, %{role: :admin} = user} -> user
    _ -> raise "No admin user for #{admin_email} — run priv/repo/seeds.exs first."
  end

tenant = Accounts.default_org_id()
opts = [actor: admin, tenant: tenant]

# --- Media -----------------------------------------------------------------

existing_media = CMS.list_media_items!(opts) |> Map.new(&{&1.url, &1})

media_by_ref =
  Map.new(export["media"], fn m ->
    attrs = %{
      filename: m["filename"],
      content_type: m["content_type"],
      width: m["width"],
      height: m["height"],
      url: m["url"],
      variants: m["variants"] || %{},
      alt: m["alt"]
    }

    item =
      case Map.fetch(existing_media, m["url"]) do
        {:ok, item} -> CMS.update_media_item!(item, attrs, opts)
        :error -> CMS.create_media_item!(attrs, opts)
      end

    {m["sanity_ref"], item}
  end)

IO.puts("media: #{map_size(media_by_ref)} ready")

# --- Categories / tags -----------------------------------------------------

categories =
  Map.new(export["categories"], fn %{"slug" => slug, "name" => name} ->
    case CMS.get_category_by_slug(slug, opts ++ [not_found_error?: false]) do
      {:ok, %{} = cat} -> {slug, cat}
      _ -> {slug, CMS.create_category!(%{name: name, slug: slug}, opts)}
    end
  end)

tags =
  Map.new(export["tags"], fn %{"slug" => slug, "name" => name} ->
    case CMS.get_tag_by_slug(slug, opts ++ [not_found_error?: false]) do
      {:ok, %{} = tag} -> {slug, tag}
      _ -> {slug, CMS.create_tag!(%{name: name, slug: slug}, opts)}
    end
  end)

IO.puts("categories: #{map_size(categories)}, tags: #{map_size(tags)}")

# --- Content ---------------------------------------------------------------

# Swap image blocks' media_ref (Sanity asset ref) for MediaItem UUID + URL.
resolve_blocks = fn blocks ->
  Enum.map(blocks || [], fn
    %{"_type" => "image", "media_ref" => ref} = block ->
      case Map.fetch(media_by_ref, ref) do
        {:ok, item} ->
          block
          |> Map.delete("media_ref")
          |> Map.merge(%{"media_id" => item.id, "url" => item.url})
          |> then(fn b ->
            if b["alt"] in [nil, ""], do: Map.put(b, "alt", item.alt || ""), else: b
          end)

        :error ->
          Map.delete(block, "media_ref")
      end

    block ->
      block
  end)
end

# Per-type code interfaces (bang variants; create/list arity 2, update/publish
# arity 3: record, params, opts). `post` is a core type on KilnCMS.CMS; the
# four acupuncture types live on the overlay's Acupuncture.Catalog domain.
interfaces =
  Map.new(~w(post condition team_member testimonial faq), fn type ->
    plural = if type == "faq", do: "faqs", else: "#{type}s"
    domain = if type == "post", do: CMS, else: Catalog

    {type,
     %{
       list: Function.capture(domain, :"list_#{plural}!", 2),
       create: Function.capture(domain, :"create_#{type}!", 2),
       update: Function.capture(domain, :"update_#{type}!", 3),
       publish: Function.capture(domain, :"publish_#{type}!", 3)
     }}
  end)

table_for = %{
  "post" => "posts",
  "condition" => "conditions",
  "team_member" => "team_members",
  "testimonial" => "testimonials",
  "faq" => "faqs"
}

# Existing rows per type, keyed by slug, for idempotent re-runs.
existing_by_type =
  Map.new(interfaces, fn {type, %{list: list}} ->
    {type, list.(%{}, opts) |> Map.new(&{&1.slug, &1})}
  end)

counts = %{created: 0, updated: 0, published: 0, failed: 0}

{counts, imported} =
  Enum.reduce(export["records"], {counts, %{}}, fn record, {counts, imported} ->
    type = record["type"]
    %{create: create, update: update, publish: publish} = interfaces[type]

    optional =
      [
        excerpt: record["excerpt"],
        seo_title: record["seo_title"],
        seo_description: record["seo_description"],
        category_id: record["category_slug"] && categories[record["category_slug"]].id,
        featured_image_id:
          record["featured_image_ref"] &&
            case media_by_ref[record["featured_image_ref"]] do
              nil -> nil
              item -> item.id
            end,
        tag_ids:
          record["tag_slugs"] &&
            record["tag_slugs"]
            |> Enum.uniq()
            |> Enum.map(&(tags[&1] && tags[&1].id))
            |> Enum.reject(&is_nil/1)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    attrs =
      Map.merge(
        %{
          title: record["title"],
          slug: record["slug"],
          blocks: resolve_blocks.(record["blocks"]),
          custom_fields: record["custom_fields"] || %{}
        },
        optional
      )

    # Concurrent Oban jobs (embedding, notifications) can collide with the
    # loop on the same row (optimistic lock / pool contention), so retry a
    # failed record once before counting it as failed. The retry re-reads the
    # row from the DB — attempt 1 may have created it before failing at
    # publish, which the pre-loop snapshot can't know about.
    import_one = fn lookup ->
      {verb, row} =
        case lookup.(record["slug"]) do
          {:ok, existing} -> {:updated, update.(existing, Map.delete(attrs, :slug), opts)}
          :error -> {:created, create.(attrs, opts)}
        end

      published? = record["published"] != false and row.state in [:draft, :in_review]
      row = if published?, do: publish.(row, %{}, opts), else: row
      {verb, published?, row}
    end

    snapshot_lookup = fn slug -> Map.fetch(existing_by_type[type], slug) end

    fresh_lookup = fn slug ->
      %{list: list} = interfaces[type]

      case list.(%{}, opts) |> Enum.find(&(&1.slug == slug)) do
        nil -> :error
        row -> {:ok, row}
      end
    end

    result =
      try do
        {:ok, import_one.(snapshot_lookup)}
      rescue
        _ ->
          Process.sleep(250)

          try do
            {:ok, import_one.(fresh_lookup)}
          rescue
            e -> {:error, e}
          end
      end

    case result do
      {:ok, {verb, published?, row}} ->
        counts =
          counts
          |> Map.update!(verb, &(&1 + 1))
          |> then(&if published?, do: Map.update!(&1, :published, fn n -> n + 1 end), else: &1)

        {counts, Map.put(imported, {type, record["slug"]}, row)}

      {:error, e} ->
        IO.puts(
          "  FAILED #{type}/#{record["slug"]}: #{Exception.message(e) |> String.slice(0, 300)}"
        )

        {Map.update!(counts, :failed, &(&1 + 1)), imported}
    end
  end)

IO.inspect(counts, label: "content")

# --- Related conditions (second pass, now that all ids exist) --------------

related_updates =
  export["records"]
  |> Enum.filter(&(&1["type"] == "condition" and (&1["related_slugs"] || []) != []))
  |> Enum.reduce(0, fn record, n ->
    with %{} = row <- imported[{"condition", record["slug"]}] do
      ids =
        record["related_slugs"]
        |> Enum.map(&imported[{"condition", &1}])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.id)

      if ids != [] do
        interfaces["condition"].update.(row, %{related_condition_ids: ids}, opts)
        n + 1
      else
        n
      end
    else
      _ -> n
    end
  end)

IO.puts("related-condition links: #{related_updates}")

# --- Restore original publish dates (direct Repo update; see header) -------

restored =
  export["records"]
  |> Enum.filter(& &1["published_at"])
  |> Enum.reduce(0, fn record, n ->
    with %{} = row <- imported[{record["type"], record["slug"]}],
         {:ok, dt, _} <- DateTime.from_iso8601(record["published_at"]) do
      table = table_for[record["type"]]

      from(r in table, where: r.id == ^Ecto.UUID.dump!(row.id))
      |> Repo.update_all(set: [published_at: dt])

      n + 1
    else
      _ -> n
    end
  end)

IO.puts("published_at restored: #{restored}")
IO.puts("Import finished.")
