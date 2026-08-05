defmodule Kiln.Advisory.Checks.AllCapsTest do
  @moduledoc """
  Shouted text (#495).

  Nearly every test here is a NEGATIVE one, deliberately. A check that flags
  every acronym on a technical page gets ignored, and an ignored check is
  worse than none: it also isn't catching the shouted paragraph it exists for.
  """
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Checks.AllCaps
  alias Kiln.Advisory.Context

  # Through `Body.compute/1`, not a hand-built `%Body{}`: the run detection
  # lives in the walk (so the editor memoizes it), and a test that set
  # `capitalised_runs` by hand would pass with the detection deleted.
  defp check(text) do
    blocks = [
      %{
        "_type" => "rich_text",
        "body" => [
          %{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}
        ]
      }
    ]

    AllCaps.check(%Context{body: Body.compute(blocks)})
  end

  defp flagged?(text), do: match?(%{code: :all_caps_run}, check(text))

  test "an empty body has nothing to judge" do
    assert AllCaps.check(%Context{body: %Body{}}) == :n_a
    assert Body.compute([]) |> then(&AllCaps.check(%Context{body: &1})) == :n_a
  end

  describe "stays quiet about" do
    test "ordinary prose" do
      refute flagged?("The quick brown fox jumps over the lazy dog, repeatedly and at length.")
    end

    test "acronyms scattered through a technical sentence" do
      refute flagged?(
               "The WCAG 2.4.4 rule applies to every HTML page served over HTTPS, per the W3C."
             )
    end

    test "a list of acronyms, which is what the six-word threshold is FOR" do
      # Four capitalised tokens in a row is an ordinary list, not shouting.
      # These are the exact strings that were false positives at four.
      refute flagged?("Formats: PDF CSV XML JSON are supported.")
      refute flagged?("Use HTTP HTTPS TLS SSL as needed.")
      refute flagged?("See NASA JPL ESA NOAA for data.")
    end

    test "two short shouted headings, which the joined text would merge" do
      # `BlockText.to_text/1` joins blocks with a SPACE and a heading has no
      # terminal punctuation, so scanning the joined text turns these into one
      # four-word "sentence". Runs are found per block precisely for this.
      blocks = [
        %{"_type" => "heading", "level" => 2, "text" => "SHIPPING INFO"},
        %{"_type" => "heading", "level" => 2, "text" => "RETURNS POLICY"}
      ]

      refute match?(%{code: :all_caps_run}, AllCaps.check(%Context{body: Body.compute(blocks)}))
    end

    test "a single short shouted phrase in a long document" do
      refute flagged?("Everything was fine. STOP. Then it was not, and we carried on regardless.")
    end

    test "a title in title case" do
      refute flagged?("An Introduction To Accessible Content Authoring For Editors")
    end
  end

  describe "flags" do
    test "a fully capitalised sentence" do
      assert flagged?("PLEASE READ THIS NOTICE BEFORE CONTINUING WITH YOUR APPLICATION.")
    end

    test "a shouted sentence whose only gap is a one-letter word" do
      # Sized so it FAILS under a two-way classify: with "A" treated as
      # lowercase the run splits into 2 + 4, both under the six-word
      # threshold, and the sentence passes silently. Three-way — where an
      # uncased or too-short token is transparent — keeps it as one run of 6.
      assert flagged?("PLEASE READ A VERY IMPORTANT LEGAL NOTICE")
    end

    test "a shouted sentence whose only gap is a number" do
      # Same property, different neutral token.
      assert flagged?("SAVE UP TO 50 PERCENT THIS WEEK ONLY")
    end

    test "a long shouted run" do
      assert flagged?("SAVE UP TO 50 PERCENT ON EVERY ORDER PLACED THIS WEEK.")
    end
  end

  describe "the finding" do
    test "is a warning and quotes an example" do
      finding = check("PLEASE READ THIS NOTICE BEFORE CONTINUING WITH YOUR APPLICATION.")

      assert finding.severity == :warning
      assert finding.args.example =~ "PLEASE READ THIS"
    end

    test "truncates a very long example rather than pasting a paragraph into the panel" do
      finding = check(String.duplicate("SHOUTING ", 40))

      assert String.length(finding.args.example) <= 60
    end
  end

  test "it is an accessibility finding only — search stopped caring about case" do
    assert AllCaps.lenses() == [:accessibility]
  end
end
