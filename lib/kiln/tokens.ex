defmodule Kiln.Tokens do
  @moduledoc """
  `[token]` substitution — the shared engine behind #468, generalized out of
  the slug/alias pattern engine (`KilnCMS.Slug.Pattern`, #454/#485) so other
  features can reuse the same bracket syntax and validation shape instead of
  each growing its own.

  A caller doesn't register anything globally — it builds its own list of
  `t:definition/0`s (its available tokens for *this* call) and passes it to
  `expand/3`/`validate/2` alongside a plain context map. There is no runtime
  registry to keep in sync across features with wildly different available
  tokens (a slug pattern's `[category]` means nothing to a workflow email);
  each consumer decides its own vocabulary. `KilnCMS.Slug.Pattern` is the
  first, most elaborate consumer — read it as the worked example, including
  how a *family* of tokens (`[field:<name>]`) is expressed as one definition
  with a `Regex` matcher instead of one definition per field.

  ## Two-layer error philosophy

  `expand/3` never fails — an unknown token expands to `""`, the same "don't
  take the caller down over one bad token" posture `Kiln.Advisory.Registry`
  takes for a raising check. That is only safe because `validate/2` is meant
  to run first, at the point a pattern is *saved* (a slug pattern on a
  content type, an autoresponder subject on a form) — by the time `expand/3`
  runs against a real submission, the pattern has already been proven to
  contain only known tokens. Skipping `validate/2` and going straight to
  `expand/3` on unvalidated input silently swallows typos instead of
  rejecting them.
  """

  @token_regex ~r/\[([a-z0-9:_-]+)\]/
  @capture_regex ~r/\[([^\]]*)\]/

  @type token :: String.t()
  @type context :: map()

  @typedoc """
  One token (or token *family*, via a `Regex` matcher) a caller makes
  available. `resolve` receives the exact matched token text (so a family
  definition can pull the variable part back out, e.g. `"field:size"`) and
  the context map, and returns the substituted value — `nil` and `""` both
  render as empty.
  """
  @type definition :: %{
          required(:match) => token() | Regex.t(),
          required(:resolve) => (token(), context() -> String.t() | nil)
        }

  @doc """
  Substitute every `[token]` in `pattern` using `definitions`. A token with
  no matching definition — including one the pattern's own `validate/2` call
  never saw, if a caller skips it — expands to `""` rather than raising or
  leaving the brackets in place.
  """
  @spec expand(String.t(), [definition()], context()) :: String.t()
  def expand(pattern, definitions, context) do
    Regex.replace(@token_regex, pattern, fn _match, token ->
      token |> resolve(definitions, context) |> to_string()
    end)
  end

  defp resolve(token, definitions, context) do
    case Enum.find(definitions, &matches?(&1, token)) do
      nil -> nil
      %{resolve: resolve} -> resolve.(token, context)
    end
  end

  defp matches?(%{match: match}, token) when is_binary(match), do: match == token
  defp matches?(%{match: %Regex{} = regex}, token), do: Regex.match?(regex, token)

  @doc """
  Validate every `[token]` `pattern` mentions against `definitions`. `nil`
  (no pattern configured) is always `:ok`. On failure, the error carries
  every unrecognized token (not just the first), so a caller with several
  typos sees them all in one pass rather than fixing them one at a time.

  Matches on the widest possible bracket capture (`[^\\]]*`, not `[a-z0-9:_-]+`
  — the same characters `expand/3`'s substitution regex accepts) so a
  pattern like `"[Bad Token]"` or the empty `"[]"` is caught here as unknown
  rather than silently passing validation and then silently expanding to
  `""` on every real record.
  """
  @spec validate(String.t() | nil, [definition()]) :: :ok | {:error, [token()]}
  def validate(nil, _definitions), do: :ok

  def validate(pattern, definitions) do
    unknown =
      @capture_regex
      |> Regex.scan(pattern, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&known?(&1, definitions))

    if unknown == [], do: :ok, else: {:error, unknown}
  end

  defp known?(token, definitions), do: Enum.any?(definitions, &matches?(&1, token))

  @doc "Whether `pattern` mentions `token` — skip a lookup its resolver would otherwise pay for."
  @spec uses?(String.t() | nil, token()) :: boolean()
  def uses?(nil, _token), do: false
  def uses?(pattern, token), do: String.contains?(pattern, "[#{token}]")

  @doc "Every literal (non-family) token name in `definitions`, for hints/error messages."
  @spec names([definition()]) :: [token()]
  def names(definitions), do: for(%{match: match} when is_binary(match) <- definitions, do: match)
end
