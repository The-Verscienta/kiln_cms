defmodule Mix.Tasks.Kiln.Gettext.Check do
  @moduledoc """
  Fails when a translated locale carries an untranslated or fuzzy message.

  The existing CI gate (`gettext.extract --merge` + `git diff --exit-code`)
  only proves the catalogs are **in sync with the source**. It says nothing
  about whether they are any good, so two failure modes have shipped past it
  repeatedly:

    * **Empty msgstr.** Gettext falls back to the msgid, so the Spanish UI
      silently renders English. Nothing anywhere goes red.
    * **Bogus fuzzy.** `gettext.merge` matches messages by Jaro distance on the
      msgid and copies the old translation across. At the 0.8 default our short
      UI strings collide constantly — "Site name" inherited the Spanish for
      "Set name" ("Establecer nombre"), and "Powered by %{name}." inherited
      "Se restauró %{name}." ("It was restored"). These are worse than an empty
      msgstr: they read as finished work and are wrong in a language the
      reviewer usually can't check.

  `mix.exs` sets `gettext: [fuzzy_threshold: 1.0]`, which stops new bogus
  fuzzies being generated. This task is the other half — it catches what that
  leaves behind, and it fails on any *pre-existing* fuzzy too, since a fuzzy
  mark means "a machine guessed this and nobody confirmed it".

  The source locale (`en`) is skipped: its msgstrs are empty by design and
  gettext correctly falls back to the msgid.

      mix kiln.gettext.check
  """
  @shortdoc "Fails when a translated locale has untranslated or fuzzy messages"

  use Mix.Task

  # `en` is the source language — empty msgstrs there are correct.
  @source_locale "en"

  @impl Mix.Task
  def run(_args) do
    problems =
      "priv/gettext/*/LC_MESSAGES/*.po"
      |> Path.wildcard()
      |> Enum.reject(&(locale(&1) == @source_locale))
      |> Enum.flat_map(&check_file/1)

    if problems == [] do
      Mix.shell().info("Gettext catalogs: every translated locale is complete.")
    else
      shell = Mix.shell()
      Enum.each(problems, &shell.error/1)

      Mix.raise("""
      #{length(problems)} untranslated or unverified message(s).

      Translate them in priv/gettext/<locale>/LC_MESSAGES/*.po and remove any
      `#, fuzzy` flag once the translation is confirmed correct. A fuzzy mark is
      a machine guess, not a translation — check it rather than trusting it.
      """)
    end
  end

  defp check_file(path) do
    path
    |> Expo.PO.parse_file!()
    |> Map.fetch!(:messages)
    |> Enum.flat_map(&check_message(&1, path))
  end

  # The PO header is `msgid ""` with the metadata in its msgstr — not a message.
  defp check_message(%Expo.Message.Singular{msgid: [""]}, _path), do: []

  defp check_message(%Expo.Message.Singular{} = message, path) do
    cond do
      fuzzy?(message) -> [problem(path, message.msgid, "fuzzy (unverified machine guess)")]
      blank?(message.msgstr) -> [problem(path, message.msgid, "untranslated")]
      true -> []
    end
  end

  defp check_message(%Expo.Message.Plural{} = message, path) do
    cond do
      fuzzy?(message) ->
        [problem(path, message.msgid, "fuzzy (unverified machine guess)")]

      Enum.any?(Map.values(message.msgstr), &blank?/1) ->
        [problem(path, message.msgid, "untranslated (some plural forms)")]

      true ->
        []
    end
  end

  defp fuzzy?(message), do: "fuzzy" in List.flatten(message.flags)

  defp blank?(strings), do: strings |> Enum.join() |> String.trim() == ""

  defp problem(path, msgid, reason) do
    "#{path}: #{reason} — #{msgid |> Enum.join() |> String.slice(0, 70) |> inspect()}"
  end

  defp locale(path) do
    path |> Path.split() |> Enum.at(-3)
  end
end
