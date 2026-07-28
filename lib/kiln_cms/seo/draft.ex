defmodule KilnCMS.Seo.Draft do
  @moduledoc """
  The proposal a `KilnCMS.Seo.Generator` returns — and the boundary where model
  output stops being trusted.

  Two jobs:

    * **Parsing.** `schema/0` drives provider-native structured output; when a
      provider can't do that (small local models often can't),
      `parse_text/1` recovers a JSON object from free text.
    * **Constraining.** `normalize/1` runs over *every* draft regardless of how
      it arrived. This is the highest-value code in the drafting path: the
      values land in `<meta>` tags on the public site, so a successful prompt
      injection would buy SEO cloaking on the operator's domain. Constraining
      the *output* is a far more reliable defence than trying to sanitize the
      untrusted body on the way in — a single-line, 60-character title with no
      markup and no URLs cannot carry much of a payload.

  Nothing here is ever written to a record on its own; a human accepts each
  field in the editor.
  """

  @type t :: %__MODULE__{
          seo_title: String.t() | nil,
          seo_description: String.t() | nil,
          seo_keywords: [String.t()],
          model: String.t() | nil,
          usage: map() | nil
        }

  defstruct seo_title: nil, seo_description: nil, seo_keywords: [], model: nil, usage: nil

  @doc """
  Structured-output schema for `ReqLLM.generate_object/4`.

  Lengths are *not* declared as constraints: a provider that rejects the whole
  generation for a one-character overrun is worse than one that returns
  something slightly long which `normalize/1` then trims.
  """
  @spec schema() :: keyword()
  def schema do
    [
      seo_title: [
        type: :string,
        required: true,
        doc: "Page title for search results, at most #{KilnCMS.Seo.title_max()} characters."
      ],
      seo_description: [
        type: :string,
        required: true,
        doc:
          "Meta description for search results, at most #{KilnCMS.Seo.description_max()} characters."
      ],
      seo_keywords: [
        type: {:list, :string},
        required: true,
        doc:
          "Up to #{KilnCMS.Seo.keyword_max()} keyphrases, most important first. " <>
            "The first is the focus keyphrase."
      ]
    ]
  end

  @doc """
  Build a draft from a decoded object. Tolerates string or atom keys and the
  camelCase a model may produce despite the schema.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid}
  def from_map(map) when is_map(map) do
    draft = %__MODULE__{
      seo_title: pick(map, ["seo_title", "seoTitle", "title"]),
      seo_description: pick(map, ["seo_description", "seoDescription", "description"]),
      seo_keywords: pick_list(map, ["seo_keywords", "seoKeywords", "keywords"])
    }

    # A response that yielded nothing usable is an error, not an empty draft —
    # the caller should fall through to the next parsing tier.
    if blank?(draft), do: {:error, :invalid}, else: {:ok, draft}
  end

  def from_map(_other), do: {:error, :invalid}

  @doc """
  Recover a JSON object from free-form model text.

  Handles ```` ```json ```` fences and commentary either side by taking the
  span from the first `{` to the last `}`.
  """
  @spec parse_text(String.t()) :: {:ok, map()} | {:error, :unparsable}
  def parse_text(text) when is_binary(text) do
    with {:ok, candidate} <- object_span(text),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(candidate) do
      {:ok, decoded}
    else
      _ -> {:error, :unparsable}
    end
  end

  def parse_text(_other), do: {:error, :unparsable}

  @doc """
  Clamp and sanitize a draft. Always runs, whatever produced it.
  """
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{} = draft) do
    %{
      draft
      | seo_title: draft.seo_title |> clean() |> clamp(KilnCMS.Seo.title_max()) |> strip_period(),
        seo_description: draft.seo_description |> clean() |> clamp(KilnCMS.Seo.description_max()),
        seo_keywords: normalize_keywords(draft.seo_keywords)
    }
  end

  @doc "The draft's keywords as the comma-separated string `seo_keywords` stores."
  @spec keywords_string(t()) :: String.t()
  def keywords_string(%__MODULE__{seo_keywords: keywords}), do: Enum.join(keywords, ", ")

  # ── Sanitizing ────────────────────────────────────────────────────────────

  # Collapse to a single line, drop markup, and refuse anything still carrying a
  # link. Returns nil when the value can't be made safe — better to offer no
  # suggestion for a field than a poisoned one.
  defp clean(nil), do: nil

  defp clean(value) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/<[^>]*>/u, " ")
      # Whitespace first: `\p{Cc}` below covers newline and tab, so stripping
      # before this would join "Line one.\n\nLine two." into "Line one.Line
      # two." rather than collapsing to a space.
      |> String.replace(~r/\s+/u, " ")
      # Remaining control (Cc) and format (Cf) characters. A NUL arriving via
      # the free-text JSON tier reaches Postgres, which rejects 0x00 in a text
      # column by *raising* — killing the LiveView and the author's unsaved
      # work rather than returning a changeset error. U+202E and friends are
      # here too: they render the snippet reversed (Trojan-Source style).
      |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "")
      |> String.trim()
      |> String.trim(~s("))
      |> String.trim("`")
      |> String.trim()

    cond do
      cleaned == "" -> nil
      link?(cleaned) -> nil
      true -> cleaned
    end
  end

  # Anything that could function as a link once it lands in a `<meta>` tag or in
  # `/llms.txt`. Deliberately broad, because the cost of a false positive is one
  # unoffered suggestion while the cost of a miss is SEO cloaking on the
  # operator's domain:
  #
  #   * any scheme (`javascript:`, `data:`, `mailto:`) — not just http(s)
  #   * scheme-relative `//host`
  #   * a bare host-like token (`evil.example`, `kiln-support.example/verify`),
  #     which is what a phishing snippet actually uses
  #   * markdown links, and the unicode full stop U+3002 homograph
  @link_patterns [
    # any scheme with an authority, plus the schemeless form
    ~r|[a-z][a-z0-9+.-]*://|iu,
    ~r|//|u,
    # schemes that need no authority to be dangerous
    ~r/\b(javascript|data|vbscript|file|mailto)\s*:/iu,
    ~r/\[[^\]]*\]\(/u,
    # a bare host-like token — what a phishing snippet actually uses
    ~r/\b[\p{L}\p{N}][\p{L}\p{N}-]*(\.|\x{3002})[a-z]{2,}\b/iu
  ]

  defp link?(value), do: Enum.any?(@link_patterns, &Regex.match?(&1, value))

  defp clamp(nil, _max), do: nil
  defp clamp(value, max), do: String.slice(value, 0, max)

  # Search snippets read better without a trailing full stop on the title.
  defp strip_period(nil), do: nil
  defp strip_period(value), do: String.replace(value, ~r/\.\s*$/u, "")

  # `keyword_max` bounds the COUNT; each keyword also needs a length ceiling.
  # Without one a single multi-thousand-character "keyword" survives into
  # `<meta name="keywords">`, JSON-LD, and — since `seo_keywords` is a slug
  # source — into a public URL.
  @keyword_chars 60

  defp normalize_keywords(keywords) do
    keywords
    |> List.wrap()
    |> Enum.flat_map(&split_keyword/1)
    |> Enum.map(&clean/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(&1 |> String.downcase() |> clamp(@keyword_chars)))
    |> Enum.uniq()
    |> Enum.take(KilnCMS.Seo.keyword_max())
  end

  # A model asked for a list sometimes returns one comma-joined string anyway.
  defp split_keyword(value) when is_binary(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1)

  defp split_keyword(_value), do: []

  # ── Parsing helpers ───────────────────────────────────────────────────────

  defp object_span(text) do
    with {start, _} <- :binary.match(text, "{"),
         [_ | _] = closes <- :binary.matches(text, "}"),
         {last, _} <- List.last(closes),
         true <- last > start do
      {:ok, binary_part(text, start, last - start + 1)}
    else
      _ -> {:error, :unparsable}
    end
  end

  defp pick(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) || Map.get(map, safe_atom(key)) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp pick_list(map, keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(map, key) || Map.get(map, safe_atom(key)) do
        value when is_list(value) -> value
        value when is_binary(value) -> [value]
        _ -> nil
      end
    end)
  end

  # Never mint atoms from model output.
  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp blank?(%__MODULE__{seo_title: nil, seo_description: nil, seo_keywords: []}), do: true
  defp blank?(_draft), do: false
end
