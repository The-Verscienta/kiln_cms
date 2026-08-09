defmodule KilnCMS.Seo.Patterns do
  @moduledoc """
  Applies a content type's default SEO patterns (#805) to a record at render
  time — the context-building half of `KilnCMS.Seo.Pattern`, and the sibling of
  `KilnCMS.CMS.Slugs` for the slug engine.

  ## A default, never an overwrite

  A pattern fills in for a record whose own `seo_title` / `seo_description` is
  blank. It is resolved **at read time** by `apply_to/3`, never written into the
  column, and that is the whole design:

    * an author who types a title keeps it, always — `apply_to/3` only touches
      a field that is nil or blank
    * changing a type's pattern re-titles every record that never had one, with
      no backfill, no migration and nothing to re-publish
    * a record's stored SEO fields still say exactly what a human chose, so the
      editor's SEO panel, `KilnCMS.Seo.Analyzer` and `KilnCMS.Seo.Draft` keep
      meaning what they meant — "empty" there still means "nobody wrote one"

  Writing the expansion into the column would have made all three false, and
  would have left "is this title mine or the type's?" unanswerable a week later.

  ## Where it is applied

  At the delivery boundary in `KilnCMSWeb.ContentController`, on the *canonical*
  record, before anything reads its metadata. So the `<title>`, the meta
  description, the schema.org graph and a paywall teaser all see the same
  resolved values and cannot disagree — the property `KilnCMSWeb.Teaser`'s
  moduledoc already asks for between a teaser and a member render.

  Surfaces that hand a record's own fields to a machine as *stored data* —
  the export (#487), the content serializer, the version history — deliberately
  do not call this. A patterned title is a rendering of the type's
  configuration, not a value the record holds, and an export that materialized
  it would reimport as an author-typed override, which is exactly the confusion
  the read-time rule above exists to prevent.
  """

  alias KilnCMS.Branding
  alias KilnCMS.Seo.Pattern

  # {record field, the descriptor key holding its pattern, its length ceiling}.
  # Spelled out rather than derived, so no atom is ever built from a string at
  # runtime — and so the ceiling sits beside the field it governs.
  @fields [
    {:seo_title, :seo_title_pattern, KilnCMS.Limits.line()},
    {:seo_description, :seo_description_pattern, KilnCMS.Limits.paragraph()}
  ]

  @doc """
  Fill blank `seo_title` / `seo_description` on `record` from `ct`'s patterns.

  Returns `record` untouched when the type has no patterns, when both fields are
  already written, or when `ct` is nil (a record whose type is no longer
  registered still renders).
  """
  @spec apply_to(struct(), map() | nil, term()) :: struct()
  def apply_to(record, ct, org \\ nil)
  def apply_to(record, nil, _org), do: record

  def apply_to(record, ct, org) do
    case Enum.reject(pattern_pairs(ct), &skip?(record, &1)) do
      [] -> record
      pairs -> fill(record, pairs, org)
    end
  end

  defp fill(record, pairs, org) do
    context = context(record, org)

    Enum.reduce(pairs, record, fn {field, pattern, limit}, acc ->
      case Pattern.expand(pattern, context) do
        nil -> acc
        expanded -> Map.put(acc, field, clamp(expanded, limit))
      end
    end)
  end

  # The expansion goes where an authored value would, so it lives under the same
  # ceiling. `Map.put/3` writes past the attribute's `max_length` constraint —
  # nothing validates a value that is never saved — and `[excerpt]` is a legal
  # token in a TITLE pattern, so `"[title] — [excerpt]"` otherwise emitted a
  # paragraph-length `<title>` on every page of the type. Cut on a word boundary
  # where one is near the end, since a title severed mid-word reads as broken
  # rather than as long.
  defp clamp(text, limit) when byte_size(text) <= limit, do: text

  defp clamp(text, limit) do
    cut = binary_part(text, 0, limit)

    case :binary.matches(cut, " ") do
      [] -> cut
      matches -> at_word_boundary(cut, elem(List.last(matches), 0), limit)
    end
  end

  defp at_word_boundary(cut, last_space, limit) do
    if limit - last_space <= div(limit, 10),
      do: binary_part(cut, 0, last_space),
      else: cut
  end

  # Nothing to do when the type sets no pattern for the field, when the record
  # carries its own value, or when the resource has no such attribute at all.
  defp skip?(record, {field, pattern, _limit}) do
    is_nil(pattern) or not Map.has_key?(record, field) or present?(Map.get(record, field))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  @doc "The type's `{field, pattern, limit}` triples, from a `ContentTypes` descriptor."
  @spec pattern_pairs(map()) :: [{atom(), String.t() | nil, pos_integer()}]
  def pattern_pairs(ct) do
    Enum.map(@fields, fn {field, key, limit} -> {field, Map.get(ct, key), limit} end)
  end

  @doc """
  The expansion context for a stored record.

  The date anchor is the same chain the slug engine uses — publish date, else
  scheduled date, else creation date — so a `[yyyy]` in a title and a `[yyyy]`
  in a slug can never name different years for the same record.
  """
  @spec context(struct(), term()) :: Pattern.context()
  def context(record, org) do
    %{
      title: Map.get(record, :title),
      # `Map.get/2`: `excerpt` only exists on types that opted into it.
      excerpt: Map.get(record, :excerpt),
      category_name: category_name(record),
      site_name: Branding.for_org(org_id(record, org)).site_name,
      custom_fields: loaded(Map.get(record, :custom_fields)),
      date:
        loaded(Map.get(record, :published_at)) || loaded(Map.get(record, :scheduled_at)) ||
          loaded(Map.get(record, :inserted_at))
    }
  end

  # `%Ash.NotLoaded{}` is TRUTHY, so an unselected column short-circuits a `||`
  # chain and hands the struct on as if it were a value. For the date chain that
  # was the worst possible failure: `Pattern.date/1` matches neither `%Date{}`
  # nor `%DateTime{}`, falls through to `Date.utc_today()`, and a 2019 post's
  # paywall teaser rendered `[yyyy]` as the CURRENT year. An unloaded field must
  # read as absent, so the next link in the chain gets its turn.
  defp loaded(%Ash.NotLoaded{}), do: nil
  defp loaded(value), do: value

  # An unloaded relationship is `%Ash.NotLoaded{}`, which has no `:name` key, so
  # this clause simply doesn't match and `[category]` expands empty rather than
  # raising. `loads/1` is what gets it loaded on the delivery read; the paywall
  # teaser's read is pinned to a fixed column set and cannot take a load, so
  # there the empty expansion is the answer — and the separator elision means
  # that reads as a shorter title, not a broken one.
  defp category_name(%{category: %{name: name}}) when is_binary(name), do: name
  defp category_name(_record), do: nil

  defp org_id(_record, %{id: id}), do: id
  defp org_id(record, _org), do: Map.get(record, :org_id)
end
