defmodule Kiln.Forms.SpamCheck.Checks.LocaleMismatch do
  @moduledoc """
  Flags a submission whose free text is predominantly a different writing
  system than its declared locale — a Cyrillic or CJK payload posted to a
  form declaring `en`/`es`/`fr` is a genuine content/locale mismatch, not
  merely "written in a language the site doesn't support."

  Deliberately conservative to avoid false positives: only fires when the
  declared locale is one this check actually has an opinion about (a small,
  explicit Latin-script list — an unrecognized or absent locale is `:ok`,
  never assumed), and only once the text is long enough that a handful of
  foreign characters (a name, a brand) can't tip it.
  """
  use Kiln.Forms.SpamCheck

  alias Kiln.Forms.SpamCheck.Context

  # Locales this check knows are written in Latin script. Absent/unknown
  # locales are skipped rather than assumed — see the moduledoc.
  @latin_script_locales ~w(en es fr de it pt nl)

  # Character ranges for scripts common in link/pharma spam. Not exhaustive —
  # this is a coarse signal, not a language identifier.
  @non_latin_ranges [
    # Cyrillic
    {0x0400, 0x04FF},
    # Arabic
    {0x0600, 0x06FF},
    # Hebrew
    {0x0590, 0x05FF},
    # CJK Unified Ideographs
    {0x4E00, 0x9FFF},
    # Hiragana + Katakana
    {0x3040, 0x30FF},
    # Hangul Syllables
    {0xAC00, 0xD7A3}
  ]

  @min_chars 20
  @flag_ratio 0.3
  @weight 35

  @impl Kiln.Forms.SpamCheck
  def check(%Context{locale: locale}) when not is_binary(locale), do: :ok

  def check(context) do
    if String.downcase(context.locale) in @latin_script_locales do
      judge(Context.text(context))
    else
      :ok
    end
  end

  defp judge(text) do
    codepoints = text |> String.to_charlist() |> Enum.reject(&(&1 in [?\s, ?\n, ?\t, ?\r]))

    if length(codepoints) < @min_chars do
      :ok
    else
      non_latin = Enum.count(codepoints, &non_latin?/1)

      if non_latin / length(codepoints) > @flag_ratio,
        do: flag(:script_mismatch, @weight),
        else: :ok
    end
  end

  defp non_latin?(codepoint),
    do: Enum.any?(@non_latin_ranges, fn {lo, hi} -> codepoint >= lo and codepoint <= hi end)
end
