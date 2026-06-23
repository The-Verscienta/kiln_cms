defmodule KilnCMS.I18n do
  @moduledoc """
  Locale configuration for content delivery.

  Content is modelled per-locale already (each record has a `locale`, unique on
  `[slug, locale]`), so translations of a page are just same-slug records in
  different locales. This module centralises the supported set and the default.

      config :kiln_cms, :i18n, default_locale: "en", locales: ["en", "fr"]
  """
  @spec default_locale() :: String.t()
  def default_locale, do: Keyword.get(config(), :default_locale, "en")

  @spec locales() :: [String.t()]
  def locales, do: Keyword.get(config(), :locales, [default_locale()])

  @spec supported?(String.t()) :: boolean()
  def supported?(locale), do: locale in locales()

  @doc "The locale to actually use for `requested`, falling back to the default."
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(requested) when is_binary(requested) do
    if supported?(requested), do: requested, else: default_locale()
  end

  def normalize(_), do: default_locale()

  @doc """
  Pick the best supported locale from an `Accept-Language` header value (e.g.
  `"fr-CA,fr;q=0.9,en;q=0.8"`), matching on the primary subtag. Returns `nil`
  when nothing matches, so callers can fall back.
  """
  @spec negotiate(String.t() | nil) :: String.t() | nil
  def negotiate(header) when is_binary(header) do
    header
    |> parse_accept_language()
    |> Enum.find_value(&match_supported/1)
  end

  def negotiate(_), do: nil

  # Languages from an Accept-Language header, highest q-value first.
  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_lang, q} -> q end, :desc)
    |> Enum.map(fn {lang, _q} -> lang end)
  end

  defp parse_language(part) do
    case part |> String.trim() |> String.split(";") do
      [""] -> nil
      [lang | rest] -> {lang |> String.trim() |> String.downcase(), quality(rest)}
    end
  end

  defp quality(params) do
    Enum.find_value(params, 1.0, fn p ->
      with ["q", v] <- p |> String.trim() |> String.split("="),
           {q, _} <- Float.parse(v) do
        q
      else
        _ -> nil
      end
    end)
  end

  # Match a header language (possibly region-qualified, e.g. "fr-ca") to a
  # supported locale: exact match, else by primary subtag.
  defp match_supported(lang) do
    primary = lang |> String.split("-") |> hd()

    cond do
      supported?(lang) -> lang
      supported?(primary) -> primary
      true -> nil
    end
  end

  defp config, do: Application.get_env(:kiln_cms, :i18n, [])
end
