defmodule KilnCMS.CMS.Translations do
  @moduledoc """
  The **localization workflow** over per-locale content (D-i18n): content is
  modelled one record per locale sharing a slug (`unique [slug, locale]`), and
  this module answers the editorial questions that model raises —

    * `siblings/3` — every locale variant of a record (all workflow states,
      editor-facing; the public `published_translations` read stays the
      delivery surface);
    * `coverage/3` — per configured locale: the variant (or `:missing`), its
      workflow state, and whether it has gone **stale** (the default-locale
      source was updated after the translation's last edit — the standard
      lightweight outdated heuristic; any edit of the translation clears it);
    * `create_translation!/4` — one-click "translate to `<locale>`": duplicate
      the source's content fields into a new draft in the target locale, ready
      for a translator.

  All functions dispatch through `KilnCMS.CMS.ContentTypes`, so compiled types
  and admin-defined dynamic entries (D17) behave identically.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.I18n

  # Content fields copied into a new translation. Workflow (state, schedules)
  # and delivery bookkeeping (published_version, artifacts) start fresh;
  # canonical_url is locale-specific by nature, so it isn't carried over.
  @copied_attrs [
    :title,
    :slug,
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
  Every locale variant sharing `record`'s slug (including `record` itself),
  any workflow state, sorted by locale. Editor-facing: pass the acting user.
  """
  @spec siblings(atom() | String.t() | map(), struct(), keyword()) :: [struct()]
  def siblings(kind, record, opts \\ []) do
    ContentTypes.list!(
      kind,
      Keyword.merge(opts, query: [filter: [slug: record.slug], sort: [locale: :asc]])
    )
  end

  @doc """
  Translation coverage for one record: an entry per configured locale —

      %{locale: "fr", record: %Page{} | nil, status: :published | :draft |
        :in_review | :archived | :missing, stale?: boolean()}

  `stale?` is true for a non-default-locale variant whose default-locale
  sibling was updated after it (never for the default locale or missing
  variants).
  """
  @spec coverage(atom() | String.t() | map(), struct(), keyword()) :: [map()]
  def coverage(kind, record, opts \\ []) do
    siblings = siblings(kind, record, opts)
    by_locale = Map.new(siblings, &{&1.locale, &1})
    source = by_locale[I18n.default_locale()]

    for locale <- I18n.locales() do
      variant = by_locale[locale]

      %{
        locale: locale,
        record: variant,
        status: if(variant, do: variant.state, else: :missing),
        stale?: stale?(variant, source, locale)
      }
    end
  end

  defp stale?(nil, _source, _locale), do: false
  defp stale?(_variant, nil, _locale), do: false

  defp stale?(variant, source, locale) do
    locale != I18n.default_locale() and
      DateTime.after?(source.updated_at, variant.updated_at)
  end

  @doc """
  Create a draft translation of `record` in `target_locale`: same slug, the
  content fields copied (blocks included, dumped to their storage shape and
  re-cast), workflow starting at `:draft` with the acting user as author.
  Raises if the variant already exists (the `[slug, locale]` identity).
  """
  @spec create_translation!(atom() | String.t() | map(), struct(), String.t(), keyword()) ::
          struct()
  def create_translation!(kind, record, target_locale, opts \\ []) do
    # Re-fetch with tags so the copy carries them regardless of what the
    # caller had loaded.
    record = ContentTypes.get_record!(kind, record.id, Keyword.put(opts, :load, [:tags]))

    attrs =
      @copied_attrs
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(record, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)
      |> Map.put(:locale, target_locale)
      |> Map.put(:blocks, dump_blocks(record))
      |> Map.put(:tag_ids, tag_ids(record))

    ContentTypes.create!(kind, attrs, opts)
  end

  # Blocks are stored union structs; dump them back to the storage shape so
  # the create action re-casts them — minus their ids, so the copy gets fresh
  # stable block ids. The union dumps nested (`%{"type" => …, "value" => %{…}}`),
  # so the id lives inside the value map.
  defp dump_blocks(record) do
    attribute = Ash.Resource.Info.attribute(record.__struct__, :blocks)

    {:ok, dumped} =
      Ash.Type.dump_to_embedded(attribute.type, record.blocks || [], attribute.constraints)

    Enum.map(dumped, &strip_block_id/1)
  end

  defp strip_block_id(%{"value" => value} = dumped) when is_map(value),
    do: %{dumped | "value" => Map.drop(value, ["id", :id])}

  defp strip_block_id(dumped), do: Map.drop(dumped, ["id", :id])

  # The source's tags, as the ids the create action's `tag_ids` argument takes.
  defp tag_ids(record) do
    case record.tags do
      tags when is_list(tags) -> Enum.map(tags, & &1.id)
      _not_loaded -> []
    end
  end
end
