defmodule Kiln.Advisory.Checks.AllCaps do
  @moduledoc """
  Runs of text set in capitals (#495).

  Two separate problems, one cause:

    * Some screen readers spell an all-caps word out letter by letter, because
      that is how they distinguish an acronym from a word. `IMPORTANT NOTICE`
      is then read "eye em pee oh…", which is unintelligible.
    * Capitals remove word-shape, the cue dyslexic readers and anyone skimming
      rely on. A capitalised paragraph is measurably slower to read for
      everyone and materially harder for some.

  The fix is presentational — capitals belong in CSS (`text-transform`), where
  they change how text looks without changing what it *is*.

  ## Only long runs, and never acronyms

  Finding the runs is `Kiln.Advisory.Body`'s job, not this module's — it is
  full-text work, and `Body` is the half the editor memoizes on the block
  digest, so a keystroke in the title doesn't rescan a 50k-word article. This
  check reads `capitalised_runs` and decides whether there are enough of them
  to say something.

  A run needs **six** consecutive capitalised words of two letters or more,
  counted within a single block. That threshold is the whole design: four is
  the length of an ordinary list of acronyms (`PDF CSV XML JSON`), and a check
  that flags those on a technical page is one an author turns off — at which
  point it also stops catching the shouted paragraph it exists for. Six is
  long enough to be prose.

  ## Accessibility lens only

  Search engines stopped caring about capitalisation long ago, so putting this
  in the SEO panel would be noise there.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  # An empty draft has nothing to judge — reporting a pass there would flatter
  # it, which is the rule the whole framework follows (`Kiln.Advisory`).
  @impl Kiln.Advisory
  def check(%Context{body: %{text: text}}) when text in [nil, ""], do: :n_a

  def check(%Context{body: %{capitalised_runs: []}}), do: :ok

  # No second threshold on total matched words. There used to be one, and it
  # was unreachable: `Body` only keeps runs already at or above its own
  # minimum, so the sum always cleared it. A gate that cannot fail is worse
  # than no gate — it reads as a safeguard while doing nothing.
  def check(%Context{body: %{capitalised_runs: runs}}) do
    finding(:warning, :all_caps_run, :body, %{
      count: length(runs),
      example: runs |> hd() |> truncate()
    })
  end

  @max_example_length 60

  # Graphemes, not bytes: `byte_size/1` would let a 60-character CJK example
  # through at ~180 bytes, and slicing by byte count can split a character.
  defp truncate(text) do
    if String.length(text) <= @max_example_length,
      do: text,
      else: String.slice(text, 0, @max_example_length - 1) <> "…"
  end

  @impl Kiln.Advisory
  def lenses, do: [:accessibility]
end
