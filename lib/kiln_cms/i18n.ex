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

  @doc """
  The locale to actually use for `requested`, falling back to the default.

  Takes `term()` rather than `String.t() | nil` because callers pass raw client
  input straight in — `KilnCMSWeb.ManifestController` hands it `params["locale"]`,
  which Plug decodes as a list for `?locale[]=fr`. The catch-all clause exists
  for exactly that, so the spec has to admit it.
  """
  @spec normalize(term()) :: String.t()
  def normalize(requested) when is_binary(requested) do
    if supported?(requested), do: requested, else: default_locale()
  end

  def normalize(_), do: default_locale()

  @doc """
  Prefixes a public path with the active locale segment so internal links keep
  the reader's locale (`/fr/blog`, `/fr/blog/my-post`). The default locale is
  served unprefixed, and the bare home path `"/"` is never prefixed — a single
  segment like `/fr` is treated as a slug by `Plugs.SetLocale`, not a locale
  prefix. Matches the prefix convention used for hreflang/locale links.
  """
  @spec localized_path(String.t() | nil, String.t()) :: String.t()
  def localized_path(locale, "/" <> _ = path) do
    cond do
      path == "/" -> path
      not is_binary(locale) -> path
      locale == default_locale() -> path
      not supported?(locale) -> path
      true -> "/" <> locale <> path
    end
  end

  @language_names %{
    "en" => "English",
    "fr" => "French",
    "es" => "Spanish",
    "de" => "German",
    "it" => "Italian",
    "pt" => "Portuguese",
    "nl" => "Dutch",
    "ja" => "Japanese",
    "zh" => "Chinese",
    "ar" => "Arabic",
    "fa" => "Persian",
    "hi" => "Hindi",
    "pl" => "Polish",
    "ru" => "Russian",
    "sv" => "Swedish",
    "tr" => "Turkish",
    "ko" => "Korean"
  }

  @doc ~S"""
  A human-readable English name for a locale tag, for prompts.

  Used by the LLM features (`KilnCMS.Seo.Prompt`, `KilnCMS.Assist.Prompt`) to
  pin which language a model must write in. It lives here rather than beside
  either of them because it was written twice, identically, and the copies
  would have drifted: the locale set an operator configures is `locales/0`, and
  a deployment adding one has exactly one map to extend.

  Falls back to naming the tag itself, which still reads as an instruction.

      iex> KilnCMS.I18n.language_name("fr-CA")
      "French"
      iex> KilnCMS.I18n.language_name("cy")
      "the language with IETF tag cy"
  """
  @spec language_name(String.t() | atom() | nil) :: String.t()
  def language_name(locale) do
    tag = locale |> to_string() |> String.split(~r/[-_]/) |> hd() |> String.downcase()

    Map.get(@language_names, tag, "the language with IETF tag #{locale}")
  end

  defp config, do: Application.get_env(:kiln_cms, :i18n, [])
end
