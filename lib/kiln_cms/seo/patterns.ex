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
  the export (#487), the version history — deliberately do not call this. A
  patterned title is a rendering of the type's configuration, not a value the
  record holds, and an export that materialized it would reimport as an
  author-typed override, which is exactly the confusion the read-time rule
  above exists to prevent.

  ## Everywhere else reads it as a value, through `effective/3` (#1102)

  `apply_to/3` overwrites the field, which is right for the delivery render —
  the whole page, its teaser and its schema.org graph then read one struct and
  cannot disagree. It is wrong for a feed entry, an `.ics` `DESCRIPTION`, an
  ActivityPub `Note` or the fired `:json_ld`, which each want *one* value and
  must not have the record mutated under them.

  `effective/3` is that read. It returns the author's own value where there is
  one, and the type's pattern expanded where there is not — the same answer the
  page renders, from the same code. Two ways to get it, one meaning:

    * the `effective_seo_title` / `effective_seo_description` **calculations**
      (`KilnCMS.CMS.Calculations.EffectiveSeo`), which reach every read API and
      carry their own `load/3` — so `[category]` and `[field:<name>]` resolve
      even on a read with a pinned column set
    * a direct call, which resolves the descriptor itself for a caller holding a
      record it did not read (the fired producer, a webhook payload)

  `effective/3` prefers the loaded calculation when the record carries one, so a
  surface that adds the `load:` pays one query for the page of records rather
  than a registry lookup per record — and gets the same string either way.
  """

  alias KilnCMS.Branding
  alias KilnCMS.CMS.Slugs
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

  @doc """
  The record's effective `seo_title` / `seo_description` — the author's own
  value where there is one, else the type's pattern expanded (#1102).

  This is the single reader every non-HTML surface uses: a feed summary, an
  `.ics` `DESCRIPTION`, `llms.txt`, an auto-posted status, an ActivityPub
  `Note`, the fired `:json_ld` and the webhook payload all resolve here rather
  than each re-deciding what "the description" means.

  Options:

    * `:type` — the `KilnCMS.CMS.ContentTypes` descriptor, when the caller has
      one. Feeds, the calendar and the event index all read *per type*, so
      passing it saves a registry lookup per record — and is required for a
      record read with a pinned column set that omits `org_id`, which is what
      the fallback lookup resolves through.
    * `:org` — the org struct, when the caller has one, for `[site-name]`.
    * `:resolve` — `false` to answer from the loaded calculation and the stored
      column only, never the registry. For a caller inside a write transaction:
      `KilnCMS.CMS.Changes.NotifyWebhooks` serializes from an `after_action`, and
      a read that fails there aborts the publish it is describing.

  Prefers the loaded `effective_seo_*` calculation, so a read that added the
  `load:` resolves nothing twice.
  """
  @spec effective(map(), :seo_title | :seo_description, keyword()) :: String.t() | nil
  def effective(record, field, opts \\ [])

  # A record with no such field has no effective value, and asking is not an
  # error: `KilnCMS.Federation.AnnounceWorker` builds a bare `%{id, title, slug,
  # locale}` for a `Delete` whose document is already gone, and resolving a
  # descriptor for that map raises rather than returning nil.
  def effective(record, field, _opts) when not is_map_key(record, field), do: nil

  def effective(record, field, opts) do
    case Map.get(record, calculation_name(field), :absent) do
      %Ash.NotLoaded{} -> resolve_here(record, field, opts)
      :absent -> resolve_here(record, field, opts)
      value -> value
    end
  end

  # A thunk, not a value: a record carrying its own value never reaches the
  # registry, because an author's description is the answer whatever the type
  # says. Resolving eagerly to find that out put a lookup per record on surfaces
  # (the social composer, a webhook payload) that previously had none.
  defp resolve_here(record, field, opts) do
    resolve(record, fn -> descriptor(record, opts) end, field, opts[:org])
  end

  @doc """
  `effective/3` for a caller that already holds the descriptor and the org — the
  shape `KilnCMS.CMS.Calculations.EffectiveSeo` calls, once per record.

  `ct` may be a descriptor, `nil`, or a zero-arity function returning one, which
  is only called when the answer actually depends on the type.

  `org` is the org struct or id for `[site-name]`, or an already-resolved
  `KilnCMS.Branding` struct — a batch resolves branding once and passes it,
  rather than paying a cache lookup per record for a value that is the same for
  every row.

  A stored value that was never selected reads as `nil` rather than as a licence
  to expand the pattern: `%Ash.NotLoaded{}` says "nobody asked", not "nobody
  wrote one", and expanding on it would replace an author's own description with
  the type's default on any surface whose read forgot the column. Every caller
  here selects it.
  """
  @spec resolve(
          map(),
          map() | nil | (-> map() | nil),
          :seo_title | :seo_description,
          term()
        ) :: String.t() | nil
  def resolve(record, ct, field, org \\ nil)
  def resolve(record, _ct, field, _org) when not is_map_key(record, field), do: nil

  def resolve(record, ct, field, org) do
    case Map.get(record, field) do
      %Ash.NotLoaded{} -> nil
      stored -> if present?(stored), do: stored, else: expand(record, ct, field, org) || stored
    end
  end

  @doc "The calculation name carrying `field`'s resolved value (#1102)."
  @spec calculation_name(:seo_title | :seo_description) :: atom()
  def calculation_name(:seo_title), do: :effective_seo_title
  def calculation_name(:seo_description), do: :effective_seo_description

  @doc """
  The `load:` a read adds to get `fields`' effective values resolved for it —
  `loads()` for the description alone, which is what most surfaces render.

  A list rather than nine spellings of `[:effective_seo_description]`: this
  module owns which calculations exist, and a third one should not be a
  nine-file edit.
  """
  @spec loads([:seo_title | :seo_description]) :: [atom()]
  def loads(fields \\ [:seo_description]), do: Enum.map(fields, &calculation_name/1)

  defp expand(record, ct, field, org) do
    with {_field, key, limit} <- field_spec(field),
         pattern when is_binary(pattern) <- pattern_of(ct, key),
         expanded when is_binary(expanded) <- Pattern.expand(pattern, context(record, org)) do
      clamp(expanded, limit)
    else
      _absent -> nil
    end
  end

  defp field_spec(field), do: List.keyfind(@fields, field, 0)

  defp pattern_of(ct, key) when is_function(ct, 0), do: pattern_of(ct.(), key)
  defp pattern_of(ct, key) when is_map(ct), do: Map.get(ct, key)
  defp pattern_of(_ct, _key), do: nil

  # `is_struct/1`, because `Slugs.descriptor_for_record/1` matches a struct or a
  # map naming a `type_definition_id` and raises `CaseClauseError` on anything
  # else — and every surface here reaches this with plain maps: the `Delete`
  # stand-in `AnnounceWorker` builds for a document that is already gone, and a
  # test asserting on the rule rather than on a record. No struct, no type, so
  # no pattern, which is the same answer an unregistered type gets.
  defp descriptor(record, opts) do
    cond do
      Keyword.has_key?(opts, :type) -> opts[:type]
      not Keyword.get(opts, :resolve, true) -> nil
      is_struct(record) -> Slugs.descriptor_for_record(record)
      true -> nil
    end
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
    cut = text |> binary_part(0, limit) |> whole_characters()

    case :binary.matches(cut, " ") do
      [] -> cut
      matches -> at_word_boundary(cut, elem(List.last(matches), 0), limit)
    end
  end

  # `binary_part/3` counts BYTES, so a ceiling landing inside a multibyte
  # character leaves a half sequence — invalid UTF-8. That was survivable while
  # the expansion only reached a HEEx render; #1102 routes it into four JSON
  # encoders, and `Jason.encode!/1` raises on it (a CJK title has no ASCII space,
  # so the word-boundary branch below never trims the tail off for you).
  defp whole_characters(""), do: ""

  defp whole_characters(cut) do
    if String.valid?(cut),
      do: cut,
      else: cut |> binary_part(0, byte_size(cut) - 1) |> whole_characters()
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

  # The type's `{field, pattern, limit}` triples, from a `ContentTypes` descriptor.
  defp pattern_pairs(ct) do
    Enum.map(@fields, fn {field, key, limit} -> {field, Map.get(ct, key), limit} end)
  end

  @doc """
  The expansion context for a stored record.

  The date anchor is the same chain the slug engine uses — publish date, else
  scheduled date, else creation date — so a `[yyyy]` in a title and a `[yyyy]`
  in a slug can never name different years for the same record.

  `org` is an org struct or id, or an already-resolved `KilnCMS.Branding` — a
  batch resolving fifty records of one org has one site name, and looking it up
  per row is fifty cache reads for one answer.
  """
  @spec context(struct(), term()) :: Pattern.context()
  def context(record, org) do
    %{
      title: Map.get(record, :title),
      # `Map.get/2`: `excerpt` only exists on types that opted into it.
      excerpt: Map.get(record, :excerpt),
      category_name: category_name(record),
      site_name: site_name(record, org),
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

  defp site_name(_record, %Branding{site_name: site_name}), do: site_name
  defp site_name(record, org), do: Branding.for_org(org_id(record, org)).site_name

  defp org_id(_record, %{id: id}), do: id
  defp org_id(record, _org), do: Map.get(record, :org_id)
end
