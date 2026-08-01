defmodule KilnCMS.CMS.Calculations.ReadingTime do
  @moduledoc """
  Estimated reading time in **whole minutes**, derived from `word_count` (#492).

  Every publishing frontend wants this and every consumer was reimplementing
  words ÷ WPM, so it is computed once here and exposed wherever `word_count` is.

      config :kiln_cms, :reading_time_wpm, 230

  230 wpm is the usual mid-range figure for adult silent reading of English
  prose. A value that is not a positive integer is ignored in favour of the
  default rather than being interpreted — a `0` would divide by zero and a
  negative would produce nonsense, and neither is a spelling of an intent.

  Rounded **up**, so any content at all reads as at least one minute and only
  genuinely empty content reads as zero. `ceil/1` already gives that: a
  one-word document is `1`, an empty one is `0`.

  ## The caveat worth knowing

  A single words-per-minute figure is an English-prose assumption. Scripts
  without spaces (Chinese, Japanese, Thai) are counted by
  `KilnCMS.CMS.BlockText` as words rather than characters, so their estimate is
  wrong in a way this calculation cannot see. Locale-aware rates are a
  follow-up; until then treat the number as a hint for English content, which
  is also how the frontends reimplementing it were treating it.
  """
  use Ash.Resource.Calculation

  require Logger

  @default_wpm 230

  @impl true
  def load(_query, _opts, _context), do: [:word_count]

  @impl true
  def calculate(records, _opts, _context) do
    wpm = words_per_minute()

    # Deliberately NO catch-all. `BlockText.word_count/1` ends in `length/1`, so a
    # real count is always a non-negative integer — the only other thing that can
    # arrive is `%Ash.NotLoaded{}`, meaning the `load/3` dependency did not
    # resolve. Reporting that as `0` would tell every consumer the corpus is
    # unreadable-length with nothing raised anywhere; better to fail loudly.
    Enum.map(records, fn
      %{word_count: 0} -> 0
      %{word_count: count} when is_integer(count) and count > 0 -> ceil(count / wpm)
    end)
  end

  @doc """
  The configured words-per-minute rate, or the default when it is unusable.

  Public so the editor can show the rate it is dividing by rather than
  restating the constant.
  """
  @spec words_per_minute() :: pos_integer()
  def words_per_minute do
    case Application.get_env(:kiln_cms, :reading_time_wpm, @default_wpm) do
      wpm when is_integer(wpm) and wpm > 0 ->
        wpm

      other ->
        Logger.warning(
          ":reading_time_wpm must be a positive integer, got #{inspect(other)}; " <>
            "using #{@default_wpm}."
        )

        @default_wpm
    end
  end

  @doc "The default words-per-minute rate, for docs and tests."
  @spec default_wpm() :: pos_integer()
  def default_wpm, do: @default_wpm
end
