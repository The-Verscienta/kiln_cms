defmodule KilnCMS.CMS.ContentCopy do
  @moduledoc """
  Shared mechanics for copying one content record's authored payload into a
  **brand-new** record.

  Two features clone content: the one-click translation
  (`KilnCMS.CMS.Translations`, into a new locale) and the duplicate action
  (`KilnCMS.CMS.Duplication`, into a new draft of the same locale). They differ
  in what identifies the copy — a translation keeps the slug and changes the
  locale, a duplicate keeps the locale and regenerates the slug — but the
  payload in between is the same, and so are the parts that are easy to get
  wrong:

    * **blocks** must go back through the union's storage shape so the create
      action re-casts (and re-sanitizes) them, minus their stable ids — at
      *every* depth, since `columns` children carry ids of their own — so the
      copy gets fresh ones;
    * **tags** are a `manage_relationship` argument on `:create`, not an
      attribute, so they travel as an id list — and the load that reads them
      must project ids only, or one click drags every tag's full row into the
      caller's heap.

  Everything here is payload-only. Workflow (`state`, schedules), delivery
  bookkeeping (published version, artifacts) and history start fresh on the
  copy, by virtue of simply not being copied. Curated **related content** is
  not here either: those rows carry a per-link payload (`kind`, `position`,
  `label`, `metadata`) that the `related_<type>_ids` argument would flatten, so
  `KilnCMS.CMS.Duplication` clones the `ContentLink` rows themselves.
  """

  alias KilnCMS.CMS.Tag

  # The authored content attributes shared by every clone. Deliberately absent:
  # `slug`/`locale` (each caller decides — they're what identifies the copy),
  # `canonical_url` (points at the *source*'s canonical URL, never the copy's),
  # `path_alias` (re-derived from the type's alias pattern), and every workflow
  # / scheduling column.
  @content_attrs [
    :title,
    :excerpt,
    :seo_title,
    :seo_description,
    :seo_keywords,
    :seo_image,
    :audience,
    :custom_fields,
    :category_id,
    :featured_image_id
  ]

  @doc """
  The authored content attributes every clone carries (see the module doc for
  what is deliberately excluded).
  """
  @spec content_attrs() :: [atom()]
  def content_attrs, do: @content_attrs

  @doc """
  The load a caller must request so `tag_ids/1` sees a real list rather than
  `%Ash.NotLoaded{}` — projected to ids, because that is all it reads.
  """
  @spec tag_load() :: keyword()
  def tag_load, do: [tags: Ash.Query.select(Tag, [:id])]

  @doc """
  `record`'s values for `keys`, as create-action attrs. `nil` values are
  dropped rather than sent, so the create action's own defaults apply.
  """
  @spec take(struct(), [atom()]) :: map()
  def take(record, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.get(record, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  @doc """
  `record`'s block tree, dumped back to the union's storage shape so the create
  action re-casts it, with every block's stable id stripped so the copy mints
  fresh ones.

  `:keep_ids?` suppresses the strip. Only the translation path passes it, and
  only because a locale variant is the *same document in another language*:
  every consumer of a block id is already scoped to one record (collab locks
  key on `{document_key, block_id}`, version folds and experiment patches read
  one record's tree, `_id` is emitted per fired document), so sharing ids
  across variants collides with nothing — and it is what lets a translation
  vendor's XLIFF file (#502) address a paragraph by identity instead of by
  position. A **duplicate** is a different document and keeps minting fresh
  ids; that is the whole difference between the two callers here.

  `:role` resets every block field that role may not edit to its declared
  default, and returns which ones were reset.

  Without it a copy dead-ended. `Changes.EnforceBlockFieldPolicy` runs on create
  as well as update, and on a create there is no stored tree to diff against —
  so `permitted_value/2` falls to the field's **declared default** and every
  admin-set value trips it. An editor duplicating (or translating) a page whose
  `quote` block has `featured: true` got a refusal they could do nothing about,
  on content they were allowed to read (#890).

  Resetting rather than refusing mirrors what duplication already does with
  per-field write grants: the copy carries what the actor could have authored.
  """
  @spec dump_blocks(struct(), keyword()) :: {[map()], [String.t()]}
  def dump_blocks(record, opts \\ []) do
    attribute = Ash.Resource.Info.attribute(record.__struct__, :blocks)

    {:ok, dumped} =
      Ash.Type.dump_to_embedded(attribute.type, record.blocks || [], attribute.constraints)

    dumped
    |> then(fn blocks ->
      if Keyword.get(opts, :keep_ids?, false), do: blocks, else: Enum.map(blocks, &strip_ids/1)
    end)
    |> reset_restricted(Keyword.get(opts, :role))
  end

  # `nil` role = admin, or an actor-less internal caller: nothing is restricted,
  # matching the policy bypass `EnforceBlockFieldPolicy` respects.
  defp reset_restricted(blocks, nil), do: {blocks, []}

  defp reset_restricted(blocks, role) do
    Enum.map_reduce(blocks, [], fn block, reset ->
      case block_module(block) do
        nil -> {block, reset}
        module -> reset_block(block, module, role, reset)
      end
    end)
    |> then(fn {blocks, reset} -> {blocks, reset |> Enum.uniq() |> Enum.sort()} end)
  end

  defp reset_block(%{"value" => value} = block, module, role, reset) when is_map(value) do
    {value, reset} = reset_fields(value, module, role, reset)
    {%{block | "value" => value}, reset}
  end

  defp reset_block(block, _module, _role, reset), do: {block, reset}

  defp reset_fields(value, module, role, reset) do
    Enum.reduce(value, {value, reset}, fn {key, _current}, {acc, reset} ->
      name = field_atom(key)

      cond do
        is_nil(name) ->
          {acc, reset}

        Kiln.Block.Policy.can_edit_field?(module, name, role) ->
          {acc, reset}

        true ->
          {Map.put(acc, key, field_default(module, name)),
           ["#{block_name(module)}.#{name}" | reset]}
      end
    end)
  end

  defp block_module(%{"type" => type}) do
    case Keyword.get(KilnCMS.Blocks.union_types(), to_atom(type)) do
      nil -> nil
      config -> Keyword.get(config, :type)
    end
  end

  defp block_module(_other), do: nil

  defp block_name(module), do: module |> Kiln.Block.Info.name() |> to_string()

  defp field_default(module, name) do
    case Enum.find(Kiln.Block.Info.fields(module), &(&1.name == name)) do
      %{default: default} -> default
      _ -> nil
    end
  end

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp to_atom(_other), do: nil

  defp field_atom(key), do: to_atom(key)

  # Drop `id` from every block-shaped map in the tree, at any depth. The union
  # dumps nested (`%{"type" => …, "value" => %{id: …, _type: "columns", …}}`)
  # and a `columns` block holds its children as raw maps that carry ids of their
  # own — a top-level-only strip would leave the copy sharing nested block ids
  # with its source. `_type` is what marks a map as a block, so ordinary maps in
  # a block field (a media reference, a custom-field map) keep their `id`.
  #
  # Key shapes are mixed on purpose: `dump_to_embedded` emits atom keys for the
  # block's own attributes, while nested children keep the string keys they were
  # cast from.
  defp strip_ids(%{} = map) when not is_struct(map) do
    map
    |> drop_block_id()
    |> Map.new(fn {key, value} -> {key, strip_ids(value)} end)
  end

  defp strip_ids(list) when is_list(list), do: Enum.map(list, &strip_ids/1)
  defp strip_ids(other), do: other

  defp drop_block_id(map) do
    if Map.has_key?(map, :_type) or Map.has_key?(map, "_type"),
      do: Map.drop(map, ["id", :id]),
      else: map
  end

  @doc "The source's tag ids, for the create action's `tag_ids` argument."
  @spec tag_ids(struct()) :: [Ash.UUID.t()]
  def tag_ids(record) do
    case Map.get(record, :tags) do
      tags when is_list(tags) -> Enum.map(tags, & &1.id)
      _not_loaded -> []
    end
  end
end
