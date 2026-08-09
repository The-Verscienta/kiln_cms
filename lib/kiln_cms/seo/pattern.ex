defmodule KilnCMS.Seo.Pattern do
  @moduledoc """
  The token vocabulary for a content type's default `seo_title` /
  `seo_description` (#805), built on the shared `Kiln.Tokens` engine (#468).

  `"[title] | [site-name]"` on a content type means every record of that type
  gets that `<title>` without anyone typing it — the same shape
  `KilnCMS.Slug.Pattern` gives URLs, aimed at the two fields search engines and
  social cards actually read. This module is the vocabulary only;
  `KilnCMS.Seo.Patterns` builds the context and applies the result.

  ## Prose, not a slug

  This is the reason it is a separate vocabulary rather than a flag on
  `KilnCMS.Slug.Pattern`. That engine slugifies — lowercase, hyphens, stop
  words stripped — because it composes URL segments. A `<title>` is a sentence:
  `[title]` here is the title as written, and a separator is whatever the
  operator typed between the brackets.

  Empty tokens collapse cleanly: `"[title] | [category]"` on an uncategorized
  record renders `Kiln guide`, not `Kiln guide | `. `expand/2` returns `nil`
  rather than `""` when nothing usable is left, so a caller falls through to its
  own default with a plain `||`.

  ## Tokens

    * `[title]` — the record's title, verbatim
    * `[excerpt]` — the excerpt, for types that have one
    * `[category]` — the category's **name** (not its slug — this is prose)
    * `[site-name]` — the org's white-label site name (#48)
    * `[yyyy]` / `[mm]` / `[dd]` — the same date anchor the slug engine uses
    * `[field:<name>]` — a custom field's scalar value, as written

  ## Why the vocabulary stops there

  Deliberately no `c:Kiln.FieldType.tokens/1` extras (#804), which slug and
  alias patterns do admit. Those are resolved by reading the type's
  `FieldDefinition` rows; a slug pays that once per *write*, but an SEO pattern
  is resolved once per *delivery render*, so admitting them would put a database
  read on every page view to serve a `<title>`. Everything above resolves from
  the record already in hand plus `KilnCMS.Branding.for_org/1`, which is cached.
  """

  alias Kiln.Tokens

  @tokens ~w(title excerpt category site-name yyyy mm dd)
  @field_token ~r/\Afield:[a-z0-9_]+\z/

  # One `[token]`, matching `Kiln.Tokens`' own grammar. The pattern is split on
  # this so an empty token can be elided STRUCTURALLY — see `assemble/1`.
  @whole_token ~r/\A\[[a-z0-9:._-]+\]\z/
  @token_part ~r/\[[a-z0-9:._-]+\]/

  # A literal that exists only to sit between two parts. Deliberately narrow:
  # only whitespace and the punctuation people actually put between title parts,
  # so a pattern's own prose is never dropped.
  @separator ~r/\A[\s|\-–—·:,]*\z/u

  @type context :: %{
          optional(:title) => String.t() | nil,
          optional(:excerpt) => String.t() | nil,
          optional(:category_name) => String.t() | nil,
          optional(:site_name) => String.t() | nil,
          optional(:date) => Date.t() | DateTime.t() | nil,
          optional(:custom_fields) => map() | nil
        }

  @doc "Base token names, without brackets (`[field:<name>]` is extra)."
  @spec tokens() :: [String.t()]
  def tokens, do: @tokens

  @doc """
  Expand `pattern` against `context`, or `nil` when nothing usable is left.

  `nil` rather than `""` so a caller can fall through to its own default with a
  plain `||` — a pattern whose every token expanded empty has said nothing, and
  publishing a bare `" | "` would be worse than publishing nothing.
  """
  @spec expand(String.t() | nil, context()) :: String.t() | nil
  def expand(nil, _context), do: nil

  def expand(pattern, context) do
    @token_part
    |> Regex.split(pattern, include_captures: true, trim: false)
    |> Enum.map(&classify(&1, context))
    |> assemble()
  end

  # Each part is either a token (resolved now, and remembered as *empty* if it
  # resolved to nothing), a separator literal, or the pattern's own prose.
  defp classify(part, context) do
    if Regex.match?(@whole_token, part) do
      case part |> Tokens.expand(definitions(), context) |> String.trim() do
        "" -> :empty
        value -> {:value, value}
      end
    else
      if Regex.match?(@separator, part), do: {:separator, part}, else: {:value, part}
    end
  end

  # Elide the separators an empty token orphaned — structurally, on the parts,
  # never by rewriting the expanded string. Repairing the string afterwards
  # cannot tell `"[yyyy]-[mm]"`'s hyphen (the operator's, and load-bearing) from
  # one left dangling by an empty `[category]`, and mangled the first.
  #
  # Edge separators go entirely; a run of them left adjacent by an empty token
  # in the middle collapses to the first, so `"[a] | [b] | [c]"` without `b`
  # reads `A | C` rather than `A | | C` or `AC`.
  defp assemble(parts) do
    parts
    |> Enum.reject(&(&1 == :empty))
    |> trim_separators()
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      [{:separator, _text} = first | _rest] -> [first]
      chunk -> chunk
    end)
    |> Enum.map_join("", fn {_kind, text} -> text end)
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp trim_separators(parts) do
    separator? = &match?({:separator, _text}, &1)

    parts
    |> Enum.drop_while(separator?)
    |> Enum.reverse()
    |> Enum.drop_while(separator?)
    |> Enum.reverse()
  end

  @doc """
  Validate a pattern's tokens; `nil` (no pattern) is always ok.

  Blank-but-present is an error rather than a silent no-op: a whitespace-only
  pattern is someone half-clearing the field, and "leave it unset" is the
  answer that leaves the record's own metadata alone.
  """
  @spec validate(String.t() | nil) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok

  def validate(pattern) when is_binary(pattern) do
    case Tokens.validate(pattern, definitions()) do
      {:error, unknown} ->
        {:error,
         "unknown token(s) #{Enum.map_join(unknown, ", ", &"[#{&1}]")} — supported: " <>
           Enum.map_join(@tokens, ", ", &"[#{&1}]") <> ", [field:<name>]"}

      :ok ->
        if String.trim(pattern) == "",
          do: {:error, "can't be blank — leave it unset for no pattern"},
          else: :ok
    end
  end

  @doc "Compile-time assertion for the `Content` macro's pattern options."
  @spec validate!(String.t() | nil) :: String.t() | nil
  def validate!(pattern) do
    case validate(pattern) do
      :ok -> pattern
      {:error, message} -> raise ArgumentError, "invalid SEO pattern: #{message}"
    end
  end

  defp definitions do
    [
      %{match: "title", resolve: fn _token, ctx -> text(ctx[:title]) end},
      %{match: "excerpt", resolve: fn _token, ctx -> text(ctx[:excerpt]) end},
      %{match: "category", resolve: fn _token, ctx -> text(ctx[:category_name]) end},
      %{match: "site-name", resolve: fn _token, ctx -> text(ctx[:site_name]) end},
      %{
        match: "yyyy",
        resolve: fn _token, ctx -> ctx |> date() |> Map.fetch!(:year) |> pad(4) end
      },
      %{
        match: "mm",
        resolve: fn _token, ctx -> ctx |> date() |> Map.fetch!(:month) |> pad(2) end
      },
      %{match: "dd", resolve: fn _token, ctx -> ctx |> date() |> Map.fetch!(:day) |> pad(2) end},
      %{match: @field_token, resolve: &field_value/2}
    ]
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()

  # Scalar values only, as written — no slugification. A list or map expands
  # empty, the same answer the slug engine gives, because there is no honest
  # single-line rendering of one.
  defp field_value("field:" <> name, ctx) do
    case Map.get(ctx[:custom_fields] || %{}, name) do
      value when is_binary(value) -> String.trim(value)
      value when is_number(value) -> to_string(value)
      _other -> ""
    end
  end

  defp date(%{date: %DateTime{} = datetime}), do: DateTime.to_date(datetime)
  defp date(%{date: %Date{} = date}), do: date
  defp date(_context), do: Date.utc_today()

  defp pad(int, width), do: int |> Integer.to_string() |> String.pad_leading(width, "0")
end
