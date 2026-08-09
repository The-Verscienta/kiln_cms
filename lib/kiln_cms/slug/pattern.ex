defmodule KilnCMS.Slug.Pattern do
  @moduledoc """
  Pathauto-style URL patterns, built on the shared `Kiln.Tokens` engine
  (#468) — this module owns the slug/alias *vocabulary* and the
  slug-specific post-processing (hyphenation, `Slug.slugify/1`); `Kiln.Tokens`
  owns bracket parsing and substitution.

  **Slug patterns** (#454) compose the URL's final segment, e.g.
  `"[yyyy]-[mm]-[title]"` → `2026-07-my-post` (so a post URL becomes
  `/blog/2026-07-my-post`). Literal separators between tokens (`/`, `.`,
  spaces) normalize to hyphens — one segment.

  **Alias patterns** (#485 follow-up) compose a full multi-segment
  `path_alias`, e.g. `"/acupuncture/needle/size/[field:size]"` →
  `/acupuncture/needle/size/14mm` — see `expand_path/2`. Each `/`-separated
  segment expands like a slug pattern; segments that expand empty drop out.

  Tokens:

    * `[title]` — the title, stop words stripped
    * `[focus-keyphrase]` — the first `seo_keywords` entry, falling back to
      the title when unset
    * `[category]` — the record's category slug (blank without a category)
    * `[yyyy]` / `[mm]` / `[dd]` — the published date when set, else the
      scheduled date, else the record's creation date (a stable anchor — never
      re-read from the wall clock once the record exists)
    * `[field:<name>]` — a custom field's value, slugified (`14mm`)
    * `[slug]` — the record's (derived) slug; **alias patterns only** — it
      would be circular in a slug pattern

  `nil` pattern = the default derivation chain (focus keyphrase → title). A
  slug pattern that expands to nothing for a given record falls back to that
  same default chain — see `KilnCMS.CMS.Slugs.derive_base/2`, the single
  entry point both the resource change and the editor use.
  """

  alias Kiln.Tokens
  alias KilnCMS.Slug

  @tokens ~w(title focus-keyphrase category yyyy mm dd)
  @field_token ~r/\Afield:[a-z0-9_]+\z/

  @type context :: %{
          optional(:title) => String.t() | nil,
          optional(:seo_keywords) => String.t() | nil,
          optional(:category_slug) => String.t() | nil,
          optional(:date) => Date.t() | DateTime.t() | nil,
          optional(:slug) => String.t() | nil,
          optional(:custom_fields) => map() | nil
        }

  @doc "Base token names, without brackets (`[field:<name>]`/`[slug]` are extra)."
  @spec tokens() :: [String.t()]
  def tokens, do: @tokens

  @doc "Whether `pattern` mentions `token` (used to skip needless lookups)."
  @spec uses?(String.t() | nil, String.t()) :: boolean()
  def uses?(pattern, token), do: Tokens.uses?(pattern, token)

  # Same character class as `Kiln.Tokens`' own grammar, dot included (#804).
  # Narrower here and `field_names/1` goes blind to `[field:location.lat]`,
  # which sends `Slugs.changeset_custom_fields/2` down its "no field tokens"
  # branch — skipping the computed-field derivation AND `stringify_keys/1`, so
  # an atom-keyed payload from an Elixir/MCP caller derived a different slug
  # than the same record posted through the JSON API.
  @field_in_pattern ~r/\[field:([a-z0-9._]+)\]/

  @doc """
  The custom-field names referenced by `[field:<name>]` tokens in `pattern`,
  de-duplicated (empty for a `nil` or token-free pattern). Lets a caller resolve
  only the fields a pattern actually reads — e.g. deriving a `:computed` field on
  demand for slug/alias expansion (#616).
  """
  @spec field_names(String.t() | nil) :: [String.t()]
  def field_names(nil), do: []

  def field_names(pattern) when is_binary(pattern) do
    @field_in_pattern
    |> Regex.scan(pattern, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "Whether `pattern` mentions any date token."
  @spec uses_dates?(String.t() | nil) :: boolean()
  def uses_dates?(pattern), do: Enum.any?(~w(yyyy mm dd), &uses?(pattern, &1))

  @doc ~S"""
  Expand `pattern` against `context` into a slug ("" when nothing usable).

  `extra` are additional `Kiln.Tokens` definitions to try **after** the built-in
  vocabulary — how a custom field type contributes its own tokens (#804). See
  `KilnCMS.CMS.Slugs.type_token_definitions/1`, which collects them from the
  `c:Kiln.FieldType.tokens/1` of the types actually attached to a content type.

  Built-ins win a name collision, deliberately: a plugin cannot redefine
  `[title]` out from under a pattern that already relies on it.
  """
  @spec expand(String.t(), context(), [Tokens.definition()]) :: String.t()
  def expand(pattern, context, extra \\ []) do
    pattern
    |> Tokens.expand(definitions(extra), context)
    |> String.replace(~r{[/._\s]+}, "-")
    |> Slug.slugify()
  end

  @doc ~S"""
  Expand an **alias pattern** into a full multi-segment path
  (`/acupuncture/needle/size/14mm`), or `nil` when every segment expands
  empty. Each `/`-separated segment expands like a slug pattern; empty
  segments (e.g. `[category]` on an uncategorized record) drop out.
  """
  @spec expand_path(String.t(), context(), [Tokens.definition()]) :: String.t() | nil
  def expand_path(pattern, context, extra \\ []) do
    segments =
      pattern
      |> String.split("/", trim: true)
      |> Enum.map(&expand(&1, context, extra))
      |> Enum.reject(&(&1 == ""))

    case segments do
      [] -> nil
      segments -> "/" <> Enum.join(segments, "/")
    end
  end

  @doc """
  Validate a pattern's tokens; `nil` (no pattern) is always ok. `usage:
  :alias` additionally permits the `[slug]` token, which is circular in a
  slug pattern.
  """
  @spec validate(String.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def validate(pattern, opts \\ [])

  def validate(nil, _opts), do: :ok

  def validate(pattern, opts) when is_binary(pattern) do
    usage = Keyword.get(opts, :usage, :slug)
    extra = Keyword.get(opts, :extra_definitions, [])

    case Tokens.validate(pattern, allowed_definitions(usage, extra)) do
      {:error, unknown} ->
        {:error,
         "unknown token(s) #{Enum.map_join(unknown, ", ", &"[#{&1}]")} — supported: " <>
           Enum.map_join(@tokens, ", ", &"[#{&1}]") <>
           ", [field:<name>]" <> if(usage == :alias, do: ", [slug]", else: "")}

      :ok ->
        if String.trim(pattern) == "",
          do: {:error, "can't be blank — leave it unset for the default derivation"},
          else: :ok
    end
  end

  @doc "Compile-time assertion for the Content macro's pattern options."
  @spec validate!(String.t() | nil, keyword()) :: String.t() | nil
  def validate!(pattern, opts \\ []) do
    case validate(pattern, opts) do
      :ok -> pattern
      {:error, message} -> raise ArgumentError, "invalid pattern: #{message}"
    end
  end

  # Every token `expand/2` can resolve, regardless of usage — `[slug]`
  # included. Whether a *pattern* may contain `[slug]` is a save-time rule
  # (`allowed_definitions/1`, below); by the time a pattern reaches `expand/2`
  # it has already passed that check for its own usage, and a `content`
  # struct passed here always carries whatever `:slug` the caller put in the
  # context regardless of which kind of pattern is expanding.
  @doc """
  Every token a pattern may mention that is **not** in the built-in vocabulary
  for `usage`.

  The cheap pre-check before paying for a field-definition lookup (#804): a
  pattern using only built-ins needs no type tokens at all, which is almost
  every pattern. Returns `[]` for a `nil` pattern.
  """
  @spec unknown_tokens(String.t() | nil, atom()) :: [String.t()]
  def unknown_tokens(nil, _usage), do: []

  def unknown_tokens(pattern, usage) do
    case Tokens.validate(pattern, allowed_definitions(usage, [])) do
      :ok -> []
      {:error, unknown} -> unknown
    end
  end

  # Built-ins first, so `extra` can only ADD names: `Kiln.Tokens.expand/3` takes
  # the first matching definition, and a plugin field type redefining `[title]`
  # for every content type that happens to use it is not a thing a pattern
  # author could debug.
  defp definitions(extra) do
    [
      %{match: "title", resolve: fn _token, ctx -> Slug.derive(ctx[:title] || "") end},
      %{match: "focus-keyphrase", resolve: &focus_keyphrase/2},
      %{
        match: "category",
        resolve: fn _token, ctx -> Slug.slugify(ctx[:category_slug] || "") end
      },
      %{match: "yyyy", resolve: fn _token, ctx -> ctx |> date() |> then(& &1.year) |> pad(4) end},
      %{match: "mm", resolve: fn _token, ctx -> ctx |> date() |> then(& &1.month) |> pad(2) end},
      %{match: "dd", resolve: fn _token, ctx -> ctx |> date() |> then(& &1.day) |> pad(2) end},
      %{match: @field_token, resolve: &field_value/2},
      %{match: "slug", resolve: fn _token, ctx -> Slug.slugify(to_string(ctx[:slug] || "")) end}
    ] ++ extra
  end

  # The subset a *pattern* may validly contain for `usage`. `[slug]` is
  # circular in a slug pattern, so it's excluded there — alias-only.
  # The save-time vocabulary for `usage`, extras included.
  #
  # `extra` is filtered by the SAME rule rather than concatenated after it. A
  # plugin's `c:Kiln.FieldType.tokens/1` list is third-party data, and appending
  # it to an already-filtered list let a definition matching `"slug"` re-admit
  # the very token `:slug` usage removes as circular — validation would then
  # accept `"[slug]-x"` as a slug pattern. Expansion was never at risk (built-ins
  # come first there); this closes the validation half.
  defp allowed_definitions(usage, extra) do
    case usage do
      :alias -> definitions(extra)
      _slug -> Enum.reject(definitions(extra), &matches_slug?/1)
    end
  end

  defp matches_slug?(%{match: match}) when is_binary(match), do: match == "slug"
  defp matches_slug?(%{match: %Regex{} = regex}), do: Regex.match?(regex, "slug")
  defp matches_slug?(_definition), do: false

  defp focus_keyphrase(_token, ctx) do
    case Slug.focus_keyphrase(ctx[:seo_keywords]) do
      "" -> Slug.derive(ctx[:title] || "")
      keyphrase -> Slug.derive(keyphrase)
    end
  end

  # Scalar custom-field values only; lists/maps (multi-selects) expand empty.
  defp field_value("field:" <> name, ctx) do
    case Map.get(ctx[:custom_fields] || %{}, name) do
      value when is_binary(value) -> Slug.slugify(value)
      value when is_number(value) -> value |> to_string() |> Slug.slugify()
      _other -> ""
    end
  end

  defp date(%{date: %DateTime{} = datetime}), do: DateTime.to_date(datetime)
  defp date(%{date: %Date{} = date}), do: date
  defp date(_context), do: Date.utc_today()

  defp pad(int, width), do: int |> Integer.to_string() |> String.pad_leading(width, "0")
end
