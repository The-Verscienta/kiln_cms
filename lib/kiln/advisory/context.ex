defmodule Kiln.Advisory.Context do
  @moduledoc """
  The snapshot every advisory check is judged against.

  Deliberately feature-neutral. An accessibility check and an SEO check want
  the same two things — the authored scalar fields, and the facts derived from
  walking the body — so they share one context rather than each assembling its
  own. `fields` is a plain map with trimmed string values (missing keys become
  `""`), and `body` is a `Kiln.Advisory.Body`.

  Built once per analysis and handed to every registered check, so the
  expensive part — the body walk — is paid once no matter how many checks run.
  """

  alias Kiln.Advisory.Body

  @type t :: %__MODULE__{
          fields: %{atom() => term()},
          body: Body.t(),
          locale: String.t()
        }

  defstruct fields: %{}, body: %Body{}, locale: "en"

  @doc """
  Build a context from loose fields and an already-computed body.

  `fields` may be atom- or string-keyed. Scalar values are trimmed to strings
  so checks can pattern-match on `""` rather than juggling `nil`; anything
  non-textual (an id, a boolean) is passed through untouched.
  """
  @spec new(map(), Body.t(), keyword()) :: t()
  def new(fields, %Body{} = body, opts \\ []) do
    locale = opts |> Keyword.get(:locale) |> presence() || KilnCMS.I18n.default_locale()

    %__MODULE__{fields: normalize(fields), body: body, locale: locale}
  end

  @doc """
  A field's value, defaulting to `""` so checks can match on emptiness.

      field(context, :seo_title)
  """
  @spec field(t(), atom()) :: term()
  def field(%__MODULE__{fields: fields}, key), do: Map.get(fields, key, "")

  @doc "Whether the locale is English — some heuristics only hold there."
  @spec english?(t()) :: boolean()
  def english?(%__MODULE__{locale: locale}), do: String.starts_with?(locale, "en")

  # Text fields become trimmed strings; ids, booleans and structs pass through.
  defp normalize(fields) do
    fields
    |> Enum.flat_map(&normalize_pair/1)
    |> Map.new()
  end

  defp normalize_pair({key, value}) when is_atom(key), do: [{key, normalize_value(value)}]

  # A string key names a field the caller already knows, so its atom exists.
  # Unknown keys are dropped rather than converted — minting atoms from map
  # keys is how you turn a form payload into an unbounded atom table.
  defp normalize_pair({key, value}) when is_binary(key) do
    [{String.to_existing_atom(key), normalize_value(value)}]
  rescue
    ArgumentError -> []
  end

  defp normalize_pair(_pair), do: []

  # `nil` becomes `""` so checks can pattern-match on emptiness with a single
  # clause. Without this, a blank form field arrives as `nil`, misses the `""`
  # clause, and blows up inside the check — which the registry then catches and
  # silently drops, turning a crash into a missing advisory.
  defp normalize_value(nil), do: ""
  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value

  defp presence(nil), do: nil

  defp presence(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
