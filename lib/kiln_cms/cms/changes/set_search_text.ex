defmodule KilnCMS.CMS.Changes.SetSearchText do
  @moduledoc """
  Maintains the denormalized `search_text` attribute used for full-text search.

  Combines the resource's textual fields (whichever of `title`, `seo_title`,
  `seo_description`, `excerpt` exist) with the plain text of the embedded block
  tree. Runs before the action so it sees the effective (merged) values on both
  create and update.

  ## Each distinct value once (#1758)

  A field value equal to one already written (case- and whitespace-blind) is
  left out, and so is a body whose **first block** repeats one — the page whose
  `seo_title` is its title and whose body opens with that title as an H1. The
  `highlight` snippet is a `ts_headline` over this text, and it read the title
  back two or three times before reaching a word of body. Nothing is lost to
  ranking: `title` has its own `A`-weighted leg in `search_vector`, and this
  text still carries it once.

  A stored row is rewritten on its next save, or on its next fire for a
  published document (`mix kiln.refire_all` sweeps every one).

  ## Searchable custom fields (#1585)

  The values of the custom fields flagged `searchable` follow the body
  (`KilnCMS.CMS.SearchableFields`), so a record is found by a structured
  identity field its prose never repeats. A value equal to one already
  written is left out, as above.

  ## Weighted by role (#2175 A3)

  Beside `search_text` it writes `search_weighted`, the same text bucketed
  by what each part *is* to the record, for the `search_vector` trigger to
  weight:

    * `A` — the title and every field that `names_record` (searchable or
      not: a name is a name);
    * `B` — the summary fields (`seo_title`, `seo_description`,
      `seo_keywords`, `excerpt`) and the first 48 words of the searchable
      custom fields, in extractor order — where a record states what it is
      ("clears heat and dries dampness");
    * `C` — the rest of the searchable custom fields;
    * `D` — the body.

  Ranked with `ts_rank_cd` plus a phrase score (`search_rank`), a phrase
  stated in a record's own field then outranks the same words scattered
  through a long body, where `search_text` as one `B` run let a monograph
  that repeats them win. A row whose
  `search_weighted` is `nil` (written before this, or by a release that does
  not know it) keeps the old vector until it is next saved or fired.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.BlockText
  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.SearchableFields

  @text_fields [:title, :seo_title, :seo_description, :seo_keywords, :excerpt]

  # How many leading words of the searchable custom fields weigh `B`, the
  # rest `C`. Enough for the fields a type leads with — a definition, a
  # property list — and not a long field's whole text.
  @lead_words 48

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &set_search_text/1)
  end

  defp set_search_text(changeset) do
    field_text =
      @text_fields
      |> Enum.filter(&Ash.Resource.Info.attribute(changeset.resource, &1))
      |> Enum.map(&Ash.Changeset.get_attribute(changeset, &1))

    block_texts = BlockText.block_texts(Ash.Changeset.get_attribute(changeset, :blocks))
    {search_text, weighted} = build(field_text, block_texts, custom_texts(changeset))

    changeset
    |> Ash.Changeset.force_change_attribute(:search_text, search_text)
    |> Ash.Changeset.force_change_attribute(:search_weighted, weighted)
  end

  # The definitions `ApplyCustomFields` already read for this write, when it
  # ran; otherwise read here — in the caller's process, inside the write's
  # transaction, never through a cache (whose fallback would run in another
  # process and need a second connection).
  defp custom_texts(changeset) do
    case Ash.Changeset.get_attribute(changeset, :custom_fields) do
      fields when is_map(fields) and map_size(fields) > 0 ->
        definitions =
          ApplyCustomFields.stashed_definitions(changeset) ||
            ApplyCustomFields.definitions(
              changeset.resource,
              Ash.Changeset.get_attribute(changeset, :type_definition_id),
              changeset.to_tenant
            )

        SearchableFields.role_texts(fields, definitions)

      _none ->
        []
    end
  end

  @doc """
  The same `search_text` computation as `change/3`, over a loaded **struct**
  and pre-derived block text rather than a changeset (#910). `blocks_text` is
  the per-block texts in order — what lets a leading block that repeats the
  title be recognised — or one already-joined string.

  For `KilnCMS.Firing.Engine.fire/2`, whose `blocks_text` comes from the
  fragment-expanded tree (`body_text/1` there) rather than `record.blocks`
  raw — a `%Fragment{}` block's own `search_text/1` is always `""`, so
  `search_text` never carried a fragment's words until something recomputed
  it against the expanded tree. Kept in this module rather than duplicated so
  `@text_fields` has one definition either way a caller arrives.
  """
  @spec compute(struct(), String.t() | [String.t()]) :: String.t()
  def compute(record, blocks_text), do: record |> compute_weighted(blocks_text) |> elem(0)

  @doc """
  `compute/2`, plus the `search_weighted` buckets (`[a, b, c, d]`) the
  same text is weighted by — what `KilnCMS.Firing.Engine.fire/2` writes
  through `:reindex_search_text`.
  """
  @spec compute_weighted(struct(), String.t() | [String.t()]) :: {String.t(), [String.t()]}
  def compute_weighted(record, blocks_text) do
    field_text =
      @text_fields
      |> Enum.filter(&Ash.Resource.Info.attribute(record.__struct__, &1))
      |> Enum.map(&Map.get(record, &1))

    build(field_text, blocks_text, SearchableFields.record_role_texts(record))
  end

  defp build(field_text, blocks_text, custom) when is_binary(blocks_text),
    do: build(field_text, [blocks_text], custom)

  # `field_text` is in `@text_fields` order, so a present title is its head.
  defp build(field_text, block_texts, role_texts) do
    {name_only, custom} = Enum.split_with(role_texts, &(elem(&1, 0) == :name_only))
    {fields, body, custom} = join(field_text, block_texts, custom)
    search_text = Enum.join(fields ++ body ++ Enum.map(custom, &elem(&1, 1)), " ")

    {title, summary} =
      case field_text do
        [title | _] when is_binary(title) and title != "" ->
          {[title], Enum.reject(fields, &(normalize(&1) == normalize(title)))}

        _no_title ->
          {[], fields}
      end

    names = for {:name, text} <- custom, do: text
    {lead, rest} = lead_words(for({:field, text} <- custom, do: text), @lead_words)

    a =
      (title ++ names ++ Enum.map(name_only, &elem(&1, 1)))
      |> Enum.reject(&blank?/1)
      |> Enum.uniq_by(&normalize/1)

    weighted = Enum.map([a, summary ++ lead, rest, body], &Enum.join(&1, " "))
    {search_text, weighted}
  end

  # The first `budget` words of `texts`, in order, and the rest — a text
  # that straddles the budget is split between the two.
  defp lead_words(texts, budget) do
    {lead, rest, _left} =
      Enum.reduce(texts, {[], [], budget}, fn text, {lead, rest, left} ->
        words = String.split(text)

        cond do
          left == 0 -> {lead, [text | rest], 0}
          length(words) <= left -> {[text | lead], rest, left - length(words)}
          true -> split_text(words, left, lead, rest)
        end
      end)

    {Enum.reverse(lead), Enum.reverse(rest)}
  end

  defp split_text(words, left, lead, rest) do
    {head, tail} = Enum.split(words, left)
    {[Enum.join(head, " ") | lead], [Enum.join(tail, " ") | rest], 0}
  end

  defp join(field_text, block_texts, custom) do
    fields = field_text |> Enum.reject(&blank?/1) |> Enum.uniq_by(&normalize/1)
    seen = MapSet.new(fields, &normalize/1)

    body =
      case Enum.reject(block_texts, &blank?/1) do
        [first | rest] ->
          if MapSet.member?(seen, normalize(first)), do: rest, else: [first | rest]

        [] ->
          []
      end

    seen = Enum.reduce(body, seen, &MapSet.put(&2, normalize(&1)))

    custom =
      custom
      |> Enum.uniq_by(&normalize(elem(&1, 1)))
      |> Enum.reject(&MapSet.member?(seen, normalize(elem(&1, 1))))

    {fields, body, custom}
  end

  defp blank?(value), do: value in [nil, ""]

  # Case- and whitespace-blind: "Welcome to  KilnCMS" and "welcome to kilncms"
  # are one value to a reader of the snippet.
  defp normalize(value),
    do: value |> String.trim() |> String.replace(~r/\s+/u, " ") |> String.downcase()
end
