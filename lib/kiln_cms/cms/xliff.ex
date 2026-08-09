defmodule KilnCMS.CMS.Xliff do
  @moduledoc """
  **XLIFF 2.0 export/import** — the translation-vendor seam (#502).

  Kiln's localization workflow (`KilnCMS.CMS.Translations`) is strong in-house:
  coverage and staleness per locale, one-click translation into a new draft.
  What it had no answer for was the other way people translate content — send
  it to Smartling, Lokalise, Crowdin, Phrase or a freelancer with a CAT tool
  and get it back. Every one of them speaks XLIFF, so XLIFF is the seam, and a
  direct API connector to any single vendor becomes a thin plugin on top of it
  rather than a second content pipeline.

      {:ok, %{xliff: xml}} = Xliff.export("post", post, "fr", actor: user, tenant: org)
      {:ok, [report]} = Xliff.import(xml, actor: user, tenant: org)

  ## Export

  `export/4` (and `export_many/3` for a batch off the coverage dashboard) reads
  the **source** record, cuts it into trans-units
  (`KilnCMS.CMS.Xliff.Units` — read that first; the unit-id scheme is the
  design centre), and writes one `<file>` per record.

  When the target-locale variant already exists, its own prose is pre-filled as
  `<target state="translated">` for every unit that has actually diverged from
  the source. A vendor's tool then shows what is already done, and a second
  round costs the difference rather than the whole document.

  Export does not create anything. A record with no target variant exports
  fine — every unit simply arrives untranslated, which is what a first round
  is.

  ## Import

  `import/2` resolves each `<file>` back to a record from the notes the export
  wrote (type, slug, source locale) and the document's own `trgLang`, creating
  the target-locale draft through `Translations.create_translation!/4` — the
  same path the one-click button uses — when it does not exist yet.

  Nothing is applied silently. Every unit id in the file lands in exactly one
  of `applied`, `unchanged` or `unknown` in the returned report, plus
  `by_position` for the ids that only resolved through the positional fallback
  and `untranslated` for the units the vendor left empty. An empty `<target>`
  never clears a field: a partial delivery is normal while a job is in
  progress.

  ## Staleness

  Applying a file writes the target-locale record, which moves its
  `updated_at` past the source's — so `Translations.coverage/3` stops reporting
  it as outdated. That marker is document-level by design (see
  `KilnCMS.CMS.Translations`); Kiln does not track per-unit staleness, and an
  import cannot invent it. A partial delivery therefore clears the whole
  document's marker, which is the same thing that happens when an editor fixes
  one paragraph by hand.

  ## Authorization

  Reads and writes run under the caller's `:actor`/`:tenant`. There is no
  `authorize?: false` anywhere here: an export endpoint that bypassed policy
  would be an efficient way to lift every draft on the site into a file, and an
  import that bypassed it would be a way to write into content the actor cannot
  edit.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Translations
  alias KilnCMS.CMS.Xliff.Document
  alias KilnCMS.CMS.Xliff.Units
  alias KilnCMS.I18n

  # One document is assembled in memory as a single binary, and a translation
  # vendor is quoted per job rather than per thousand pages. The dashboard and
  # the download controller both read this rather than each carrying their own
  # number kept in sync by a comment.
  @max_batch 50

  @note_type "kiln:type"
  @note_slug "kiln:slug"
  @note_source_locale "kiln:sourceLocale"
  @note_source_id "kiln:sourceId"

  @typedoc "What `export/4` produced, and what it left out."
  @type export_result :: %{
          xliff: String.t(),
          source_locale: String.t(),
          target_locale: String.t(),
          units: non_neg_integer(),
          warnings: [map()]
        }

  @typedoc "What `import/2` did to one `<file>` in the document."
  @type import_report :: %{
          original: String.t() | nil,
          kind: String.t() | nil,
          slug: String.t() | nil,
          locale: String.t() | nil,
          record: struct() | nil,
          created?: boolean(),
          applied: [String.t()],
          unchanged: [String.t()],
          by_position: [String.t()],
          unknown: [String.t()],
          untranslated: [String.t()],
          error: term() | nil
        }

  @doc """
  Export one record for `target_locale`.

  `record` is the **source**: whatever locale it is in becomes `srcLang`.
  """
  @spec export(atom() | String.t() | map(), struct(), String.t(), keyword()) ::
          {:ok, export_result()} | {:error, term()}
  def export(kind, record, target_locale, opts \\ []),
    do: export_many([{kind, record}], target_locale, opts)

  @doc """
  Export several records into one document, for the same target locale.

  Every record must share a source locale — `srcLang`/`trgLang` are properties
  of the XLIFF document, not of a file inside it, so a mixed batch is not
  representable and is refused rather than silently split.
  """
  @spec export_many([{atom() | String.t() | map(), struct()}], String.t(), keyword()) ::
          {:ok, export_result()} | {:error, term()}
  def export_many([], _target_locale, _opts), do: {:error, :no_records}

  def export_many(entries, target_locale, opts) when is_list(entries) do
    with :ok <- validate_locale(target_locale),
         :ok <- validate_batch(entries),
         {:ok, source_locale} <- single_source_locale(entries, target_locale) do
      variants = target_variants(entries, target_locale, opts)

      {files, warnings} =
        Enum.map_reduce(entries, [], fn {kind, record}, warnings ->
          {file, record_warnings} = export_file(kind, record, variants, opts)
          {file, warnings ++ record_warnings}
        end)

      xliff =
        Document.build(%{
          source_locale: source_locale,
          target_locale: target_locale,
          files: files
        })

      {:ok,
       %{
         xliff: xliff,
         source_locale: source_locale,
         target_locale: target_locale,
         units: files |> Enum.map(&length(&1.units)) |> Enum.sum(),
         warnings: warnings
       }}
    end
  end

  @doc "The largest number of records one exported document may carry."
  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @doc """
  A filename for an export, stable enough to recognize in a downloads folder
  and safe enough to put in a `content-disposition` header.
  """
  @spec filename(String.t(), String.t(), String.t() | nil) :: String.t()
  def filename(source_locale, target_locale, slug \\ nil) do
    base =
      [slug, source_locale, target_locale]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map_join("-", &String.replace(&1, ~r/[^A-Za-z0-9_-]+/, "-"))

    base <> ".xlf"
  end

  @doc """
  Apply a returned XLIFF document, one report per `<file>` in it.

  A file that cannot be resolved to a record reports its `error` and the rest
  of the document still imports: a vendor returning a fifty-document batch with
  one stale slug in it should land the other forty-nine.
  """
  @spec import(binary(), keyword()) :: {:ok, [import_report()]} | {:error, term()}
  def import(xml, opts \\ []) when is_binary(xml) do
    with {:ok, parsed} <- Document.parse(xml),
         :ok <- validate_locale(parsed.target_locale) do
      {:ok, Enum.map(parsed.files, &import_file(&1, parsed, opts))}
    end
  end

  # ── export ─────────────────────────────────────────────────────────────────

  defp export_file(kind, record, variants, _opts) do
    {units, warnings} = Units.extract(record)
    type = type_name(kind)

    targets =
      case Map.get(variants, {type, record.slug}) do
        nil -> %{}
        variant -> target_index(units, variant)
      end

    file = %{
      id: "f-" <> record.id,
      original: "#{type}/#{record.slug}",
      notes: [
        {@note_type, type},
        {@note_slug, record.slug},
        {@note_source_locale, record.locale},
        {@note_source_id, record.id}
      ],
      units: Enum.map(units, &to_document_unit(&1, type, targets))
    }

    {file, Enum.map(warnings, &Map.merge(&1, %{type: type, slug: record.slug}))}
  end

  defp to_document_unit(unit, type, targets) do
    %{
      id: unit.id,
      position_id: unit.position_id,
      name: "#{type} / #{unit.label}",
      source: unit.runs,
      target: pending_target(unit, targets),
      mark_defs: unit.mark_defs
    }
  end

  # Pre-fill only what the existing variant has actually translated. A target
  # draft starts life as a verbatim clone of the source, so emitting its text
  # unconditionally would mark every unit `state="translated"` when none of it
  # is — and a vendor tool that trusts the state ships the source back as the
  # translation.
  defp pending_target(unit, targets) do
    case Map.get(targets, unit.id) do
      nil -> nil
      runs -> if runs == unit.runs, do: nil, else: runs
    end
  end

  # The existing target-locale variant's own units, keyed by the address this
  # pair actually shares.
  #
  # Identity when the two trees share block ids, position only when they share
  # none — the same all-or-nothing rule `Units.apply_translations/3` applies on
  # the way back in, and for the same reason. Mixing per unit is what puts the
  # wrong paragraph in the file: a source block the target no longer holds frees
  # its index for its neighbour, whose text is then emitted as
  # `<target state="translated">` for a paragraph it has nothing to do with —
  # and unlike the import side, an export says nothing about how it matched.
  defp target_index(units, variant) do
    {target_units, _warnings} = Units.extract(variant)
    by_id = Map.new(target_units, &{&1.id, &1.runs})

    if Enum.any?(units, &Map.has_key?(by_id, &1.id)),
      do: by_id,
      else: Map.new(target_units, &{&1.position_id, &1.runs}) |> position_keyed(units)
  end

  # Re-key a positional index onto the source's own ids, so `pending_target/2`
  # only ever does an identity lookup.
  defp position_keyed(by_position, units) do
    Enum.reduce(units, %{}, fn unit, acc ->
      case Map.fetch(by_position, unit.position_id) do
        {:ok, runs} -> Map.put(acc, unit.id, runs)
        :error -> acc
      end
    end)
  end

  # Every entry's target-locale variant, in one read per content type.
  #
  # The obvious shape — ask `Translations.siblings/3` per record — is a query
  # per record that also loads every *other* locale's full row, block tree
  # included. On a 50-record batch with three locales configured that is 50
  # round trips materializing 150 documents to use 50, on the synchronous path
  # of a file download.
  defp target_variants(entries, target_locale, opts) do
    entries
    |> Enum.group_by(fn {kind, _record} -> kind end, fn {_kind, record} -> record.slug end)
    |> Enum.flat_map(fn {kind, slugs} ->
      kind
      |> ContentTypes.list!(
        Keyword.merge(opts,
          query: [filter: [slug: [in: Enum.uniq(slugs)], locale: target_locale]]
        )
      )
      |> Enum.map(&{{type_name(kind), &1.slug}, &1})
    end)
    |> Map.new()
  end

  defp validate_batch(entries) do
    if length(entries) > @max_batch,
      do: {:error, {:too_many_records, length(entries), @max_batch}},
      else: :ok
  end

  defp single_source_locale(entries, target_locale) do
    entries
    |> Enum.map(fn {_kind, record} -> record.locale end)
    |> Enum.uniq()
    |> case do
      [locale] when locale == target_locale -> {:error, {:same_locale, locale}}
      [locale] -> {:ok, locale}
      locales -> {:error, {:mixed_source_locales, Enum.sort(locales)}}
    end
  end

  defp validate_locale(locale) do
    cond do
      is_nil(locale) or locale == "" -> {:error, :missing_locale}
      I18n.supported?(locale) -> :ok
      true -> {:error, {:unknown_locale, locale}}
    end
  end

  defp type_name(%{type: type}), do: to_string(type)
  defp type_name(kind), do: to_string(kind)

  # ── import ─────────────────────────────────────────────────────────────────

  defp import_file(file, parsed, opts) do
    base = %{
      original: file.original,
      kind: nil,
      slug: nil,
      locale: parsed.target_locale,
      record: nil,
      created?: false,
      applied: [],
      unchanged: [],
      by_position: [],
      unknown: [],
      untranslated: file.untranslated,
      error: nil
    }

    case identify(file, parsed) do
      {:ok, kind, slug, source_locale} ->
        base
        |> Map.merge(%{kind: kind, slug: slug})
        |> apply_file(file, source_locale, opts)

      {:error, reason} ->
        %{base | error: reason}
    end
  end

  # The notes the export wrote are authoritative; `original` is the fallback for
  # a file that has been through a tool which dropped them, and it carries the
  # same two values in the same order for exactly that reason.
  defp identify(file, parsed) do
    notes = file.notes

    kind = notes[@note_type] || original_part(file.original, 0)
    slug = notes[@note_slug] || original_part(file.original, 1)
    source_locale = notes[@note_source_locale] || parsed.source_locale

    if is_nil(kind) or is_nil(slug) do
      {:error, {:unidentifiable_file, file.original}}
    else
      {:ok, kind, slug, source_locale}
    end
  end

  defp original_part(nil, _index), do: nil

  defp original_part(original, index) do
    case String.split(original, "/", parts: 2) do
      parts when length(parts) == 2 -> parts |> Enum.at(index) |> presence()
      _other -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp apply_file(report, file, source_locale, opts) do
    with {:ok, record, created?} <- resolve_target(report, source_locale, opts),
         {:ok, written} <- write(report.kind, record, file, opts) do
      %{report | record: written.record, created?: created?}
      |> Map.merge(written.report)
    else
      {:error, reason} -> %{report | error: reason}
    end
  end

  # The target-locale variant, created from the source through the one-click
  # path when it does not exist. Creating it here rather than refusing is the
  # point of the feature: the first round of a vendor translation is exactly
  # the case where the target draft does not exist yet.
  defp resolve_target(report, source_locale, opts) do
    case fetch_variant(report.kind, report.slug, report.locale, opts) do
      {:ok, record} ->
        {:ok, record, false}

      {:error, :not_found} ->
        create_target(report, source_locale, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_target(report, source_locale, opts) do
    with {:ok, source} <- fetch_source(report, source_locale, opts) do
      {:ok, Translations.create_translation!(report.kind, source, report.locale, opts), true}
    end
  rescue
    error -> {:error, {:create_translation_failed, Exception.message(error)}}
  end

  defp fetch_source(report, source_locale, opts) do
    locale = source_locale || I18n.default_locale()

    case fetch_variant(report.kind, report.slug, locale, opts) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:error, {:source_not_found, report.slug, locale}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_variant(kind, slug, locale, opts) do
    kind
    |> ContentTypes.list!(
      Keyword.merge(opts, query: [filter: [slug: slug, locale: locale], limit: 1])
    )
    |> case do
      [record] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  rescue
    error -> {:error, {:lookup_failed, Exception.message(error)}}
  end

  defp write(kind, record, file, opts) do
    {attrs, report} =
      Units.apply_translations(record, file.translations, Map.get(file, :aliases, %{}))

    if attrs == %{} do
      {:ok, %{record: record, report: report}}
    else
      case ContentTypes.update(kind, record, attrs, opts) do
        {:ok, updated} -> {:ok, %{record: updated, report: report}}
        {:error, error} -> {:error, {:update_failed, error}}
      end
    end
  end
end
