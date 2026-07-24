defmodule KilnCMS.Slug.Pattern do
  @moduledoc """
  Pathauto-style slug patterns (#454): a per-type template composing the URL's
  final segment, e.g. `"[yyyy]-[mm]-[title]"` → `2026-07-my-post` (so a post
  URL becomes `/blog/2026-07-my-post`).

  A pattern composes the **slug only** — one URL segment. The type's path
  prefix stays in front, and any literal separators between tokens (`/`, `.`,
  spaces) normalize to hyphens; multi-segment aliases are intentionally out of
  scope (they'd ripple through routing, identities, caching, and the headless
  by-slug reads).

  Tokens:

    * `[title]` — the title, stop words stripped
    * `[focus-keyphrase]` — the first `seo_keywords` entry, falling back to
      the title when unset
    * `[category]` — the record's category slug (blank without a category)
    * `[yyyy]` / `[mm]` / `[dd]` — the published date, falling back to the
      scheduled date, then today

  `nil` pattern = the default derivation chain (focus keyphrase → title).
  """

  alias KilnCMS.Slug

  @tokens ~w(title focus-keyphrase category yyyy mm dd)

  @type context :: %{
          optional(:title) => String.t() | nil,
          optional(:seo_keywords) => String.t() | nil,
          optional(:category_slug) => String.t() | nil,
          optional(:date) => Date.t() | DateTime.t() | nil
        }

  @doc "Supported token names, without brackets."
  @spec tokens() :: [String.t()]
  def tokens, do: @tokens

  @doc "Whether `pattern` mentions `token` (used to skip needless lookups)."
  @spec uses?(String.t() | nil, String.t()) :: boolean()
  def uses?(nil, _token), do: false
  def uses?(pattern, token), do: String.contains?(pattern, "[#{token}]")

  @doc ~S/Expand `pattern` against `context` into a slug ("" when nothing usable)./
  @spec expand(String.t(), context()) :: String.t()
  def expand(pattern, context) do
    ~r/\[([a-z-]+)\]/
    |> Regex.replace(pattern, fn _match, token -> token_value(token, context) end)
    |> String.replace(~r{[/._\s]+}, "-")
    |> Slug.slugify()
  end

  @doc "Validate a pattern's tokens; `nil` (default derivation) is always ok."
  @spec validate(String.t() | nil) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok

  def validate(pattern) when is_binary(pattern) do
    unknown =
      ~r/\[([^\]]+)\]/
      |> Regex.scan(pattern, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&(&1 in @tokens))

    cond do
      unknown != [] ->
        {:error,
         "unknown token(s) #{Enum.map_join(unknown, ", ", &"[#{&1}]")} — supported: " <>
           Enum.map_join(@tokens, ", ", &"[#{&1}]")}

      String.trim(pattern) == "" ->
        {:error, "can't be blank — leave it unset for the default derivation"}

      true ->
        :ok
    end
  end

  @doc "Compile-time assertion for the Content macro's `slug_pattern:` option."
  @spec validate!(String.t() | nil) :: String.t() | nil
  def validate!(pattern) do
    case validate(pattern) do
      :ok -> pattern
      {:error, message} -> raise ArgumentError, "invalid slug_pattern: #{message}"
    end
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

  # Unknown tokens are rejected at write/compile time; expand nils them out.
  defp token_value(_unknown, _context), do: ""

  defp date(%{date: %DateTime{} = datetime}), do: DateTime.to_date(datetime)
  defp date(%{date: %Date{} = date}), do: date
  defp date(_context), do: Date.utc_today()

  defp pad(int, width), do: int |> Integer.to_string() |> String.pad_leading(width, "0")
end
