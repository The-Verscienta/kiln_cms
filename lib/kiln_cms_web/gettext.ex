defmodule KilnCMSWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://gettext.hexdocs.pm), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: KilnCMSWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://gettext.hexdocs.pm) for detailed usage.

  ## Regional locales fall back to their language (#2637)

  A message missing from the request locale's catalog is looked up in its
  parent's before it falls back to the English msgid: `fr-CA` tries `fr_CA`
  (the directory spelling Gettext catalogs use), then `fr`. So a site that
  configures `fr-CA` while only `fr` ships renders French chrome under
  `<html lang="fr-CA">`, not English words marked as French. A regional
  catalog, when one exists, still wins for the messages it translates.

  The Gettext locale stays the request's own (`fr-CA`): the layouts, forms and
  newsletters read it back as the reader's locale, so only the lookup falls
  back, never the locale.

      iex> KilnCMSWeb.Gettext.parent_locale("fr-CA")
      "fr_CA"
      iex> KilnCMSWeb.Gettext.parent_locale("fr_CA")
      "fr"
      iex> KilnCMSWeb.Gettext.parent_locale("fr")
      nil
  """
  use Gettext.Backend, otp_app: :kiln_cms

  @impl Gettext.Backend
  def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
    case parent_locale(locale) do
      nil -> super(locale, domain, msgctxt, msgid, bindings)
      parent -> lgettext(parent, domain, msgctxt, msgid, bindings)
    end
  end

  @impl Gettext.Backend
  def handle_missing_plural_translation(locale, domain, msgctxt, msgid, plural, n, bindings) do
    case parent_locale(locale) do
      nil -> super(locale, domain, msgctxt, msgid, plural, n, bindings)
      parent -> lngettext(parent, domain, msgctxt, msgid, plural, n, bindings)
    end
  end

  @doc """
  The next locale to look a missing message up in, or `nil` at a bare
  language. Each step is strictly shorter or swaps a `-` for a `_`, so the
  chain always ends.
  """
  @spec parent_locale(String.t()) :: String.t() | nil
  def parent_locale(locale) when is_binary(locale) do
    cond do
      String.contains?(locale, "-") ->
        String.replace(locale, "-", "_")

      String.contains?(locale, "_") ->
        locale |> String.split("_") |> Enum.drop(-1) |> Enum.join("_")

      true ->
        nil
    end
  end

  def parent_locale(_locale), do: nil
end
