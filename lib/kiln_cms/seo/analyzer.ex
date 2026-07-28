defmodule KilnCMS.Seo.Analyzer do
  @moduledoc """
  Yoast-style SEO and readability analysis (#476) — advisory signals the content
  editor renders as a non-blocking checklist. Nothing here ever prevents a save.

  This is the deterministic half of Kiln's SEO assistance: pure functions over
  the authored fields plus a precomputed `KilnCMS.Seo.BodyStats`. It needs no
  configuration, no network, and no model, so it works on every install.

  ## Findings carry codes, not prose

  A finding is `%{code:, severity:, field:, args:}`. The `args` map holds the
  numbers a message wants to interpolate ("34 characters"), and the message
  itself lives in `KilnCMSWeb.SeoComponents.finding_message/1` as `gettext`
  clauses. This mirrors the split `KilnCMS.Slug.Lint` already uses and keeps
  this module free of any web or gettext dependency.

  ## Every check is one of three outcomes

  `:ok` (passed), `:n_a` (nothing to judge — an empty draft must not read as a
  wall of failures), or a finding. `report/0` exposes `passed`/`total` counts
  over the applicable checks so the editor can show "9 of 12 checks passing"
  without inventing a 0–100 score.

  ## Locale honesty

  `KilnCMS.Slug.derive/1` strips **English** stop words, so keyphrase and
  density comparisons are en-biased. Length and presence checks are
  locale-robust and always run. Flesch Reading Ease is English-only — the
  syllable heuristic is meaningless elsewhere — and returns `:n_a` for other
  locales rather than emitting confidently wrong advice.
  """

  alias KilnCMS.Seo.BodyStats
  alias KilnCMS.Slug

  @type severity :: :error | :warning | :info
  @type finding :: %{code: atom(), severity: severity(), field: atom(), args: map()}
  @type grade :: :good | :ok | :poor

  @type report :: %{
          grade: grade(),
          findings: [finding()],
          passed: non_neg_integer(),
          total: non_neg_integer(),
          stats: BodyStats.t()
        }

  @title_min 30
  @title_max 60
  @description_min 70
  @description_max 160
  @thin_content 300
  @density_min 0.5
  @density_max 2.5
  @long_sentence_words 25
  @long_sentence_ratio 0.25
  @long_paragraph_words 150

  @doc """
  Analyze the authored fields against the body.

  `fields` is a plain map (string or atom keys) of `:title`, `:slug`,
  `:seo_title`, `:seo_description`, `:seo_keywords`, `:seo_image`,
  `:featured_image_id` and `:locale` — whatever subset is available.
  """
  @spec analyze(map(), BodyStats.t()) :: report()
  def analyze(fields, %BodyStats{} = stats) do
    fields = normalize_fields(fields)
    outcomes = run_checks(fields, stats)
    findings = for {_check, {_s, _c, _a} = f} <- outcomes, do: to_finding(f)
    passed = Enum.count(outcomes, &match?({_, :ok}, &1))
    total = Enum.count(outcomes, &(not match?({_, :n_a}, &1)))

    %{
      grade: grade(findings, passed, total),
      findings: findings,
      passed: passed,
      total: total,
      stats: stats
    }
  end

  @doc "Analyze with body stats derived from `blocks` in one call."
  @spec analyze_blocks(map(), term()) :: report()
  def analyze_blocks(fields, blocks), do: analyze(fields, BodyStats.compute(blocks))

  # ── Check table ───────────────────────────────────────────────────────────

  defp run_checks(f, stats) do
    lints = MapSet.new(slug_lint(f))
    keyphrase = Slug.focus_keyphrase(f.seo_keywords)
    key_words = words(keyphrase)

    [
      {:seo_title, check_title(f)},
      {:seo_description, check_description(f)},
      {:keyphrase_set, check_keyphrase_set(keyphrase)},
      {:keyphrase_in_title, from_lint(lints, :keyphrase_not_in_title, key_words, :warning)},
      {:keyphrase_in_slug, from_lint(lints, :keyphrase_not_in_slug, key_words, :warning)},
      {:slug_length, check_slug_length(f, lints)},
      {:keyphrase_in_description, check_keyphrase_in_description(f, key_words)},
      {:keyphrase_in_first_paragraph, check_keyphrase_in_first_paragraph(stats, key_words)},
      {:keyphrase_density, check_density(stats, keyphrase)},
      {:content_length, check_content_length(stats)},
      {:headings_present, check_headings_present(stats)},
      {:heading_order, check_heading_order(stats)},
      {:image_alt, check_image_alt(stats)},
      {:og_image, check_og_image(f)},
      {:sentence_length, check_sentence_length(stats)},
      {:paragraph_length, check_paragraph_length(stats)},
      {:readability, check_readability(f, stats)}
    ]
  end

  # ── Meta fields ───────────────────────────────────────────────────────────

  # A blank SEO title is only advisory: delivery falls back to `title`.
  defp check_title(%{seo_title: "", title: ""}), do: :n_a
  defp check_title(%{seo_title: ""}), do: {:info, :seo_title_missing, %{}}

  defp check_title(%{seo_title: seo_title, title: title}) do
    length = String.length(seo_title)

    cond do
      length < @title_min -> {:warning, :seo_title_short, len(length, @title_min, @title_max)}
      length > @title_max -> {:warning, :seo_title_long, len(length, @title_min, @title_max)}
      same?(seo_title, title) -> {:info, :seo_title_duplicates_title, %{}}
      true -> :ok
    end
  end

  defp check_description(%{seo_description: ""}), do: {:warning, :seo_description_missing, %{}}

  defp check_description(%{seo_description: description}) do
    length = String.length(description)
    args = len(length, @description_min, @description_max)

    cond do
      length < @description_min -> {:warning, :seo_description_short, args}
      length > @description_max -> {:warning, :seo_description_long, args}
      true -> :ok
    end
  end

  # Delivery emits `og:image` from `seo_image` alone — `ContentController`'s
  # `render_content_body/6` does **not** fall back to the featured image — so a
  # featured image does not satisfy this. Saying otherwise would promise a
  # social preview that never ships. The editor offers a one-click "use
  # featured image" to fix it.
  defp check_og_image(%{seo_image: ""}), do: {:info, :og_image_missing, %{}}
  defp check_og_image(_fields), do: :ok

  # ── Keyphrase ─────────────────────────────────────────────────────────────

  defp check_keyphrase_set(""), do: {:info, :keyphrase_missing, %{}}
  defp check_keyphrase_set(_keyphrase), do: :ok

  # `Slug.Lint` reports only failures, so applicability is decided here: a
  # keyphrase check is `:n_a` until a keyphrase exists.
  defp from_lint(_lints, _code, [], _severity), do: :n_a

  defp from_lint(lints, code, _key_words, severity) do
    if MapSet.member?(lints, code), do: {severity, code, %{}}, else: :ok
  end

  defp check_slug_length(%{slug: ""}, _lints), do: :n_a

  defp check_slug_length(_fields, lints) do
    if MapSet.member?(lints, :slug_long), do: {:warning, :slug_long, %{}}, else: :ok
  end

  defp check_keyphrase_in_description(_fields, []), do: :n_a
  defp check_keyphrase_in_description(%{seo_description: ""}, _key_words), do: :n_a

  defp check_keyphrase_in_description(%{seo_description: description}, key_words) do
    if subset?(key_words, words(description)),
      do: :ok,
      else: {:warning, :keyphrase_not_in_description, %{}}
  end

  defp check_keyphrase_in_first_paragraph(_stats, []), do: :n_a
  defp check_keyphrase_in_first_paragraph(%{first_paragraph: ""}, _key_words), do: :n_a

  defp check_keyphrase_in_first_paragraph(stats, key_words) do
    if subset?(key_words, words(stats.first_paragraph)),
      do: :ok,
      else: {:warning, :keyphrase_not_in_first_paragraph, %{}}
  end

  defp check_density(_stats, ""), do: :n_a
  defp check_density(%{word_count: count}, _keyphrase) when count < 50, do: :n_a

  defp check_density(stats, keyphrase) do
    density = density(stats, keyphrase)
    args = %{density: Float.round(density, 2), min: @density_min, max: @density_max}

    cond do
      density < @density_min -> {:warning, :keyphrase_density_low, args}
      density > @density_max -> {:warning, :keyphrase_density_high, args}
      true -> :ok
    end
  end

  # Occurrences of the keyphrase over the body's total word count. Matched as a
  # literal substring against the folded body: `:binary.matches/2` is fast
  # enough for the keystroke path, and matching "kiln firing" literally is truer
  # to what density means than comparing stop-word-stripped token runs.
  defp density(%{word_count: 0}, _keyphrase), do: 0.0

  defp density(stats, keyphrase) do
    case BodyStats.fold(keyphrase) do
      "" -> 0.0
      needle -> length(:binary.matches(stats.folded_text, needle)) * 100 / stats.word_count
    end
  end

  # ── Structure ─────────────────────────────────────────────────────────────

  defp check_content_length(%{word_count: 0}), do: :n_a

  defp check_content_length(%{word_count: count}) when count < @thin_content,
    do: {:warning, :thin_content, %{count: count, min: @thin_content}}

  defp check_content_length(_stats), do: :ok

  defp check_headings_present(%{word_count: 0}), do: :n_a
  defp check_headings_present(%{word_count: count}) when count < @thin_content, do: :n_a
  defp check_headings_present(%{headings: []}), do: {:warning, :no_headings, %{}}
  defp check_headings_present(_stats), do: :ok

  defp check_heading_order(%{headings: []}), do: :n_a

  defp check_heading_order(%{headings: headings}) do
    levels = Enum.map(headings, & &1.level)

    case skipped_level(levels) do
      nil -> :ok
      {from, to} -> {:warning, :heading_levels_skipped, %{from: from, to: to}}
    end
  end

  defp skipped_level(levels) do
    levels
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [a, b] -> if b - a > 1, do: {a, b} end)
  end

  # ── Images ────────────────────────────────────────────────────────────────

  defp check_image_alt(%{image_count: 0}), do: :n_a
  defp check_image_alt(%{images_missing_alt: []}), do: :ok

  defp check_image_alt(%{images_missing_alt: indexes}),
    do: {:error, :images_missing_alt, %{count: length(indexes), indexes: indexes}}

  # ── Readability ───────────────────────────────────────────────────────────

  defp check_sentence_length(%{sentence_word_counts: []}), do: :n_a

  defp check_sentence_length(%{sentence_word_counts: counts}) do
    long = Enum.count(counts, &(&1 > @long_sentence_words))
    ratio = long / length(counts)

    if ratio > @long_sentence_ratio,
      do: {:info, :long_sentences, %{percent: round(ratio * 100), max: @long_sentence_words}},
      else: :ok
  end

  defp check_paragraph_length(%{paragraph_word_counts: []}), do: :n_a

  defp check_paragraph_length(%{paragraph_word_counts: counts}) do
    long = Enum.count(counts, &(&1 > @long_paragraph_words))

    if long > 0,
      do: {:info, :long_paragraphs, %{count: long, max: @long_paragraph_words}},
      else: :ok
  end

  # English-only: the syllable heuristic has no meaning in other languages, and
  # a wrong reading grade is worse than none. `normalize_fields/1` guarantees a
  # binary locale, defaulting to the configured one.
  defp check_readability(%{locale: locale} = fields, stats) do
    if String.starts_with?(locale, "en"),
      do: flesch(fields, stats),
      else: :n_a
  end

  defp flesch(_fields, %{sentence_count: 0}), do: :n_a
  defp flesch(_fields, %{word_count: count}) when count < 100, do: :n_a

  # Pure arithmetic over counts the body walk already produced.
  defp flesch(_fields, stats) do
    score =
      206.835 - 1.015 * (stats.word_count / stats.sentence_count) -
        84.6 * (stats.syllable_count / stats.word_count)

    rounded = score |> max(0.0) |> min(100.0) |> Float.round(1)

    if rounded < 50.0,
      do: {:info, :hard_to_read, %{score: rounded}},
      else: :ok
  end

  # ── Grade ─────────────────────────────────────────────────────────────────

  # Driven by severity, not by the pass ratio: `:info` findings are nudges, and
  # a document whose only findings are nudges is in good shape. The
  # `passed`/`total` counter carries the finer-grained picture.
  defp grade(findings, _passed, _total) do
    errors = Enum.count(findings, &(&1.severity == :error))
    warnings = Enum.count(findings, &(&1.severity == :warning))

    cond do
      errors > 0 or warnings >= 3 -> :poor
      warnings > 0 -> :ok
      true -> :good
    end
  end

  # ── Shared helpers ────────────────────────────────────────────────────────

  defp slug_lint(f) do
    KilnCMS.Slug.Lint.lint(%{
      slug: f.slug,
      title: f.title,
      seo_title: f.seo_title,
      seo_keywords: f.seo_keywords
    })
  end

  defp to_finding({severity, code, args}),
    do: %{code: code, severity: severity, field: field_for(code), args: args}

  # Which input a finding is *about* — drives where the editor renders it (the
  # slug-scoped ones appear inline under the slug field). Anything unmapped is
  # about the body itself.
  @finding_fields %{
    seo_title_missing: :seo_title,
    seo_title_short: :seo_title,
    seo_title_long: :seo_title,
    seo_title_duplicates_title: :seo_title,
    seo_description_missing: :seo_description,
    seo_description_short: :seo_description,
    seo_description_long: :seo_description,
    keyphrase_not_in_description: :seo_description,
    keyphrase_missing: :seo_keywords,
    keyphrase_not_in_title: :seo_keywords,
    keyphrase_density_low: :seo_keywords,
    keyphrase_density_high: :seo_keywords,
    slug_long: :slug,
    keyphrase_not_in_slug: :slug,
    og_image_missing: :seo_image,
    images_missing_alt: :images
  }

  defp field_for(code), do: Map.get(@finding_fields, code, :body)

  # Content words, stop words stripped — the same normalization `Slug.Lint`
  # uses on both sides of every comparison. Only ever applied to short strings
  # (the keyphrase, the description, the opening paragraph); the whole body goes
  # through the much cheaper `BodyStats.fold/1` instead.
  defp words(text), do: text |> to_string() |> Slug.derive() |> String.split("-", trim: true)

  defp subset?(needles, haystack), do: Enum.all?(needles, &(&1 in haystack))

  defp same?(a, b), do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  defp len(length, min, max), do: %{length: length, min: min, max: max}

  defp normalize_fields(fields) do
    %{
      title: get(fields, :title),
      slug: get(fields, :slug),
      seo_title: get(fields, :seo_title),
      seo_description: get(fields, :seo_description),
      seo_keywords: get(fields, :seo_keywords),
      seo_image: get(fields, :seo_image),
      featured_image_id: fetch_field(fields, :featured_image_id),
      locale: get(fields, :locale, KilnCMS.I18n.default_locale())
    }
  end

  defp get(fields, key, default \\ "") do
    case fetch_field(fields, key) do
      nil -> default
      value -> value |> to_string() |> String.trim()
    end
  end

  # Tolerates atom- or string-keyed maps: the editor hands us form values, tests
  # and callers hand us plain maps.
  defp fetch_field(fields, key) do
    case Map.get(fields, key) do
      nil -> Map.get(fields, to_string(key))
      value -> value
    end
  end
end
