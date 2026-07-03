defmodule Verscienta.Importer do
  @moduledoc """
  Two-pass ETL that loads Verscienta's Directus content into KilnCMS.

  **Pass 0 — taxonomy:** `herb_tags` and `tcm_categories` become namespaced
  Kiln `Tag`s.

  **Pass 1 — content + media:** each content collection is fetched, its
  `custom_fields` schema is materialised as `FieldDefinition`s, Directus file
  references become `MediaItem`s, and every row becomes a content record (body
  HTML → block tree, scalars/JSON → custom fields, taxonomy → tags), then
  published/archived to mirror its Directus status. The Directus id of each row
  is recorded so pass 2 can resolve links.

  **Pass 2 — relations:** cross-document M2M relations and data-carrying O2M
  children (formula ingredients, modifications) become `ContentLink`s, with the
  child's own fields stored on the link `metadata`.

  The importer is **idempotent**: tags, media, field definitions and content are
  looked up by their natural key (slug / name / id) and only created when
  missing, so a re-run tops up rather than duplicates. Pass `dry_run: true` to
  fetch and transform everything (and report counts) without writing.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.{Accounts, CMS}
  alias KilnCMS.CMS.ContentTypes
  alias Verscienta.{Mapping, Source, Transform}

  @doc """
  Run the migration.

  `source_spec` is anything `Verscienta.Source.resolve/1` accepts
  (`:directus`, `{:directus, url: …, token: …}` or `{:fixtures, dir}`).

  Options:

    * `:actor` — a Kiln user struct to act as (defaults to the admin resolved
      from `ADMIN_EMAIL`, falling back to `admin@kiln.test`).
    * `:dry_run` — transform without writing (default `false`).
    * `:locale` — locale for created content (default `"en"`).
  """
  @spec run(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(source_spec, opts \\ []) do
    with {:ok, source} <- Source.resolve(source_spec),
         {:ok, actor} <- resolve_actor(opts[:actor]) do
      ctx = %{
        source: source,
        actor: actor,
        dry_run: Keyword.get(opts, :dry_run, false),
        locale: Keyword.get(opts, :locale, "en"),
        quiet: Keyword.get(opts, :quiet, false)
      }

      do_run(ctx)
    end
  end

  defp do_run(ctx) do
    log(ctx, "Loading Directus collections…")

    with {:ok, taxonomies} <- fetch_taxonomies(ctx),
         {:ok, collections} <- fetch_collections(ctx) do
      state = %{
        id_map: %{},
        media_map: %{},
        tag_map: %{},
        stats: %{tags: 0, media: 0, field_defs: 0, content: 0, links: 0, skipped_links: 0}
      }

      state = import_taxonomies(taxonomies, state, ctx)

      state =
        Enum.reduce(Mapping.configs(), state, fn cfg, st ->
          import_collection(cfg, Map.get(collections, cfg.collection, []), st, ctx)
        end)

      state =
        Enum.reduce(Mapping.configs(), state, fn cfg, st ->
          import_links(cfg, Map.get(collections, cfg.collection, []), st, ctx)
        end)

      report(state, ctx)
      {:ok, state.stats}
    end
  end

  # ── Fetch ─────────────────────────────────────────────────────────────────

  defp fetch_taxonomies(ctx) do
    Enum.reduce_while(Mapping.taxonomies(), {:ok, %{}}, fn {collection, ns}, {:ok, acc} ->
      case Source.fetch_all(ctx.source, collection) do
        {:ok, items} -> {:cont, {:ok, Map.put(acc, ns, items)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_collections(ctx) do
    Enum.reduce_while(Mapping.configs(), {:ok, %{}}, fn cfg, {:ok, acc} ->
      case Source.fetch_all(ctx.source, cfg.collection) do
        {:ok, items} ->
          log(ctx, "  #{cfg.collection}: #{length(items)} rows")
          {:cont, {:ok, Map.put(acc, cfg.collection, items)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # ── Pass 0: taxonomy → tags ────────────────────────────────────────────────

  defp import_taxonomies(taxonomies, state, ctx) do
    Enum.reduce(taxonomies, state, fn {ns, items}, st ->
      Enum.reduce(items, st, fn item, st ->
        name = to_string(item["name"] || item["title"] || item["slug"])
        base = item["slug"] || item["id"]
        slug = "#{ns}-#{base |> to_string() |> slugify()}"

        case ensure_tag(st, name, slug, ctx) do
          {:ok, tag_id, st} -> put_in(st.tag_map[slug], tag_id)
          {:skip, st} -> st
        end
      end)
    end)
  end

  defp ensure_tag(st, _name, slug, _ctx) when is_map_key(st.tag_map, slug), do: {:skip, st}

  defp ensure_tag(st, name, slug, ctx) do
    cond do
      ctx.dry_run ->
        {:ok, "dry-run", bump(st, :tags)}

      existing = get_tag_by_slug(slug) ->
        {:ok, existing.id, st}

      true ->
        tag = CMS.create_tag!(%{name: name, slug: slug}, actor: ctx.actor)
        {:ok, tag.id, bump(st, :tags)}
    end
  end

  defp get_tag_by_slug(slug) do
    case CMS.get_tag_by_slug(slug, authorize?: false) do
      {:ok, tag} -> tag
      _ -> nil
    end
  end

  # ── Pass 1: content + field defs + media ───────────────────────────────────

  defp import_collection(_cfg, [], state, _ctx), do: state

  defp import_collection(cfg, items, state, ctx) do
    log(ctx, "Importing #{cfg.collection} (#{length(items)})…")
    state = ensure_field_definitions(cfg, items, state, ctx)

    Enum.reduce(items, state, fn item, st ->
      plan = Transform.plan(cfg, item)
      import_record(cfg, plan, st, ctx)
    end)
  end

  defp ensure_field_definitions(cfg, items, state, ctx) do
    defs = Transform.field_definitions(cfg, items)
    existing = existing_field_names(cfg.type)

    Enum.reduce(defs, state, fn %{name: name, field_type: type}, st ->
      cond do
        MapSet.member?(existing, name) ->
          st

        ctx.dry_run ->
          bump(st, :field_defs)

        true ->
          CMS.create_field_definition!(
            %{content_type: cfg.type, name: name, label: humanize(name), field_type: type},
            actor: ctx.actor
          )

          bump(st, :field_defs)
      end
    end)
  end

  defp existing_field_names(type) do
    # Single MapSet.new/2 construction path: unioning MapSet.new/0 (raw %{}
    # internals) with MapSet.new/2 (opaque :sets.set/0 internals on
    # Elixir 1.20+) across case branches strips the opaque type and trips
    # dialyzer's call_without_opaque on OTP 29.
    defs =
      case CMS.list_field_definitions(authorize?: false) do
        {:ok, defs} -> defs
        _ -> []
      end

    defs |> Enum.filter(&(&1.content_type == type)) |> MapSet.new(& &1.name)
  end

  defp import_record(cfg, plan, state, ctx) do
    key = {cfg.collection, plan.directus_id}

    if ctx.dry_run do
      _ = resolve_media(plan, state, ctx)
      bump(state, :content)
    else
      case find_existing(cfg.type, plan.slug, ctx.locale) do
        nil -> create_record(cfg, plan, key, state, ctx)
        record -> %{state | id_map: Map.put(state.id_map, key, record.id)}
      end
    end
  end

  defp create_record(cfg, plan, key, state, ctx) do
    {featured_id, image_blocks, state} = resolve_media(plan, state, ctx)

    tag_ids =
      Enum.map(plan.tag_refs, fn {_ns, slug} -> state.tag_map[slug] end) |> Enum.reject(&is_nil/1)

    attrs =
      %{
        title: plan.title,
        slug: plan.slug,
        locale: ctx.locale,
        custom_fields: plan.custom_fields,
        blocks: order_blocks(plan.text_blocks ++ image_blocks),
        tag_ids: tag_ids
      }
      |> maybe_put(:featured_image_id, featured_id)

    record = ContentTypes.create!(cfg.type, attrs, actor: ctx.actor)
    apply_state(cfg.type, record, plan.state_action, ctx)

    state
    |> bump(:content)
    |> Map.update!(:id_map, &Map.put(&1, key, record.id))
  end

  defp apply_state(_type, _record, :draft, _ctx), do: :ok

  defp apply_state(type, record, action, ctx) do
    verb = if action == :archive, do: "archive", else: "publish"

    case ContentTypes.transition(type, verb, record, actor: ctx.actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("#{type} #{record.slug} #{verb} failed: #{inspect(reason)}")
    end
  end

  # ── Media ──────────────────────────────────────────────────────────────────

  # Returns {featured_image_id, image_blocks, state}.
  defp resolve_media(plan, state, ctx) do
    {featured_id, state} = ensure_media(plan.featured_image, state, ctx)

    {image_blocks, state} =
      Enum.reduce(plan.image_specs, {[], state}, fn spec, {blocks, st} ->
        {media_id, st} = ensure_media(spec, st, ctx)

        block =
          %{
            type: :image,
            data: drop_nil(%{"url" => spec.url, "alt" => spec.alt, "media_id" => media_id})
          }

        {blocks ++ [block], st}
      end)

    {featured_id, image_blocks, state}
  end

  defp ensure_media(nil, state, _ctx), do: {nil, state}
  defp ensure_media(%{url: nil}, state, _ctx), do: {nil, state}

  defp ensure_media(%{directus_id: did} = spec, state, ctx) do
    cond do
      is_map_key(state.media_map, did) ->
        {state.media_map[did], state}

      ctx.dry_run ->
        {nil, bump(state, :media)}

      true ->
        media =
          CMS.create_media_item!(
            drop_nil(%{
              filename: spec.filename,
              content_type: spec.content_type,
              url: spec.url,
              alt: spec.alt,
              width: spec.width,
              height: spec.height
            }),
            actor: ctx.actor
          )

        {media.id, state |> bump(:media) |> Map.update!(:media_map, &Map.put(&1, did, media.id))}
    end
  end

  # ── Pass 2: relations → content links ──────────────────────────────────────

  defp import_links(_cfg, [], state, _ctx), do: state

  defp import_links(cfg, items, state, ctx) do
    specs =
      Enum.flat_map(items, fn item ->
        source_id = state.id_map[{cfg.collection, item["id"]}]
        if source_id, do: Enum.map(Transform.link_specs(cfg, item), &{source_id, &1}), else: []
      end)

    if specs != [], do: log(ctx, "Linking #{cfg.collection} (#{length(specs)} edges)…")

    Enum.reduce(specs, state, fn {source_id, spec}, st ->
      create_link(source_id, spec, st, ctx)
    end)
  end

  defp create_link(source_id, spec, state, ctx) do
    target_id = state.id_map[{spec.target_collection, spec.target_directus_id}]

    cond do
      is_nil(target_id) ->
        bump(state, :skipped_links)

      ctx.dry_run ->
        bump(state, :links)

      true ->
        attrs = %{
          source_id: source_id,
          target_id: target_id,
          kind: spec.kind,
          position: spec.position,
          metadata: stringify_metadata(spec.metadata)
        }

        try do
          CMS.create_content_link!(attrs, actor: ctx.actor)
          bump(state, :links)
        rescue
          # Duplicate edge (identity [source, target, kind]) on a re-run — fine.
          _ in Ash.Error.Invalid -> state
        end
    end
  end

  defp stringify_metadata(metadata) do
    Map.new(metadata, fn {k, v} ->
      {to_string(k),
       if(is_binary(v) or is_number(v) or is_boolean(v), do: v, else: Jason.encode!(v))}
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp find_existing(type, slug, locale) do
    resource = ContentTypes.get!(type).resource

    resource
    |> Ash.Query.filter(slug == ^slug and locale == ^locale)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp order_blocks(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, i} -> Map.put(block, :order, i) end)
  end

  defp resolve_actor(%{} = actor), do: {:ok, actor}

  defp resolve_actor(nil) do
    email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")

    case Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, %{} = user} -> {:ok, user}
      _ -> {:error, "no admin user found for #{email}; seed one or pass actor:"}
    end
  end

  defp bump(state, key), do: update_in(state.stats[key], &(&1 + 1))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp slugify(value), do: Slug.slugify(value) || value

  defp humanize(name) do
    name |> String.replace("_", " ") |> String.split() |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp log(%{quiet: true}, _msg), do: :ok

  defp log(%{dry_run: dry} = _ctx, msg) do
    prefix = if dry, do: "[dry-run] ", else: ""
    Mix.shell().info(prefix <> msg)
  rescue
    _ -> Logger.info(msg)
  end

  defp report(state, ctx) do
    s = state.stats

    log(
      ctx,
      "Done. tags=#{s.tags} media=#{s.media} field_defs=#{s.field_defs} " <>
        "content=#{s.content} links=#{s.links} skipped_links=#{s.skipped_links}"
    )
  end
end
