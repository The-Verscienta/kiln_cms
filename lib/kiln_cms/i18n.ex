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

  defp config, do: Application.get_env(:kiln_cms, :i18n, [])
end
