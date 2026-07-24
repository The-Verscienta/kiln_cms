defmodule KilnCMS.Slug.Pattern do
  @moduledoc """
  Pathauto-style URL patterns.

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
  def uses?(nil, _token), do: false
  def uses?(pattern, token), do: String.contains?(pattern, "[#{token}]")

  @doc "Whether `pattern` mentions any date token."
  @spec uses_dates?(String.t() | nil) :: boolean()
  def uses_dates?(pattern), do: Enum.any?(~w(yyyy mm dd), &uses?(pattern, &1))

  @doc ~S/Expand `pattern` against `context` into a slug ("" when nothing usable)./
  @spec expand(String.t(), context()) :: String.t()
  def expand(pattern, context) do
    ~r/\[([a-z0-9:_-]+)\]/
    |> Regex.replace(pattern, fn _match, token -> token_value(token, context) end)
    |> String.replace(~r{[/._\s]+}, "-")
    |> Slug.slugify()
  end

  @doc ~S"""
  Expand an **alias pattern** into a full multi-segment path
  (`/acupuncture/needle/size/14mm`), or `nil` when every segment expands
  empty. Each `/`-separated segment expands like a slug pattern; empty
  segments (e.g. `[category]` on an uncategorized record) drop out.
  """
  @spec expand_path(String.t(), context()) :: String.t() | nil
  def expand_path(pattern, context) do
    segments =
      pattern
      |> String.split("/", trim: true)
      |> Enum.map(&expand(&1, context))
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

    # `*` (not `+`) so the empty-bracket pattern "[]" is caught as an unknown
    # token instead of slipping through and expanding to "" on every record.
    unknown =
      ~r/\[([^\]]*)\]/
      |> Regex.scan(pattern, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&allowed_token?(&1, usage))

    cond do
      unknown != [] ->
        {:error,
         "unknown token(s) #{Enum.map_join(unknown, ", ", &"[#{&1}]")} — supported: " <>
           Enum.map_join(@tokens, ", ", &"[#{&1}]") <>
           ", [field:<name>]" <> if(usage == :alias, do: ", [slug]", else: "")}

      String.trim(pattern) == "" ->
        {:error, "can't be blank — leave it unset for the default derivation"}

      true ->
        :ok
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

  defp allowed_token?(token, usage) do
    token in @tokens or Regex.match?(@field_token, token) or
      (usage == :alias and token == "slug")
  end

  defp token_value("title", context), do: Slug.derive(context[:title] || "")

  defp token_value("focus-keyphrase", context) do
    case Slug.focus_keyphrase(context[:seo_keywords]) do
      "" -> Slug.derive(context[:title] || "")
      keyphrase -> Slug.derive(keyphrase)
    end
  end

  defp token_value("category", context), do: Slug.slugify(context[:category_slug] || "")

  defp token_value("yyyy", context), do: context |> date() |> then(& &1.year) |> pad(4)
  defp token_value("mm", context), do: context |> date() |> then(& &1.month) |> pad(2)
  defp token_value("dd", context), do: context |> date() |> then(& &1.day) |> pad(2)

  defp token_value("slug", context), do: Slug.slugify(to_string(context[:slug] || ""))

  # Scalar custom-field values only; lists/maps (multi-selects) expand empty.
  defp token_value("field:" <> name, context) do
    case Map.get(context[:custom_fields] || %{}, name) do
      value when is_binary(value) -> Slug.slugify(value)
      value when is_number(value) -> value |> to_string() |> Slug.slugify()
      _other -> ""
    end
  end

  # Unknown tokens are rejected at write/compile time; expand nils them out.
  defp token_value(_unknown, _context), do: ""

  defp date(%{date: %DateTime{} = datetime}), do: DateTime.to_date(datetime)
  defp date(%{date: %Date{} = date}), do: date
  defp date(_context), do: Date.utc_today()

  defp pad(int, width), do: int |> Integer.to_string() |> String.pad_leading(width, "0")
end
