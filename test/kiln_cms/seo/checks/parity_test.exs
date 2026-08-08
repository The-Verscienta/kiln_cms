defmodule KilnCMS.Seo.Checks.ParityTest do
  @moduledoc """
  The three Yoast-parity checks from #551.

  Two of them are estimates with known error bars, and the tests say so out
  loud — including the cases they are documented to get wrong. A heuristic
  whose failures are only described in a moduledoc drifts; one whose failures
  are asserted cannot.
  """
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias KilnCMS.Seo.Checks.Keyphrase
  alias KilnCMS.Seo.Checks.PassiveVoice
  alias KilnCMS.Seo.Checks.PixelWidth

  # Through `Body.compute/1` rather than a hand-built `%Body{}`, for the same
  # reason `AllCapsTest` does: the facts these checks read are produced by the
  # walk, and a test that set them by hand would pass with the walk deleted.
  defp context(fields, blocks \\ []) do
    {locale, fields} = Map.pop(fields, :locale, "en")

    Context.new(Map.merge(%{title: "T", slug: "t"}, fields), Body.compute(blocks), locale: locale)
  end

  defp paragraph(text) do
    %{
      "_type" => "rich_text",
      "body" => [
        %{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}
      ]
    }
  end

  defp heading(text, level \\ 2) do
    %{"_type" => "heading", "level" => level, "text" => text}
  end

  defp codes(findings) do
    findings
    |> List.wrap()
    |> Enum.filter(&is_struct/1)
    |> Enum.map(& &1.code)
  end

  # ── 1. Keyphrase in headings ───────────────────────────────────────────────

  describe "keyphrase in headings" do
    test "flags a keyphrase that appears nowhere in a subheading" do
      findings =
        %{seo_keywords: "otter husbandry", seo_description: "otter husbandry"}
        |> context([heading("Something else entirely"), paragraph("otter husbandry matters")])
        |> Keyphrase.check()

      assert :keyphrase_not_in_headings in codes(findings)
    end

    test "passes when a subheading carries it" do
      findings =
        %{seo_keywords: "otter husbandry"}
        |> context([heading("Otter husbandry basics"), paragraph("otter husbandry matters")])
        |> Keyphrase.check()

      refute :keyphrase_not_in_headings in codes(findings)
    end

    test "says nothing about a document with no headings" do
      # `:n_a`, not a pass and not a warning — a short page with no subheadings
      # has nothing to be told off about, and a warning here would push editors
      # to add headings the page does not need.
      findings =
        %{seo_keywords: "otter husbandry"}
        |> context([paragraph("otter husbandry matters")])
        |> Keyphrase.check()

      refute :keyphrase_not_in_headings in codes(findings)
    end

    test "says nothing when there is no keyphrase" do
      findings =
        %{seo_keywords: ""}
        |> context([heading("Anything"), paragraph("words")])
        |> Keyphrase.check()

      refute :keyphrase_not_in_headings in codes(findings)
    end
  end

  # ── 2. Pixel widths ────────────────────────────────────────────────────────

  describe "pixel width" do
    test "the whole point: same character count, very different widths" do
      # A character count cannot tell these apart, and Google truncates on the
      # difference. If this ever stops holding, the check is measuring nothing.
      assert PixelWidth.estimate(String.duplicate("W", 20)) >
               3 * PixelWidth.estimate(String.duplicate("i", 20))
    end

    test "an unknown glyph measures as an average, not as zero" do
      # Otherwise a title of emoji or accented characters reads as empty and
      # every width check silently passes.
      assert PixelWidth.estimate("é😀") > 0
    end

    test "flags a wide title and stays quiet on a narrow one of the same length" do
      wide = %{seo_title: String.duplicate("W", 60)} |> context() |> PixelWidth.check()
      narrow = %{seo_title: String.duplicate("i", 60)} |> context() |> PixelWidth.check()

      assert :seo_title_wide in codes(wide)
      refute :seo_title_wide in codes(narrow)
    end

    test "is silent outside Latin scripts rather than confidently wrong" do
      findings =
        %{locale: "ja", seo_title: String.duplicate("W", 200)}
        |> context()
        |> PixelWidth.check()

      # Per-character summing is meaningless for CJK, so the check declines to
      # answer instead of reporting a number it has no basis for.
      assert codes(findings) == []
    end

    test "falls back to the document title when no SEO title is set" do
      findings = %{title: String.duplicate("W", 60)} |> context() |> PixelWidth.check()

      assert :seo_title_wide in codes(findings)
    end
  end

  # ── 3. Passive voice ───────────────────────────────────────────────────────

  describe "passive voice" do
    test "counts a plain passive" do
      assert PassiveVoice.count_passive("The report was approved by the board.") == 1
    end

    test "counts a passive with an adverb between the parts" do
      assert PassiveVoice.count_passive("The report was quickly approved.") == 1
      assert PassiveVoice.count_passive("The report was not approved.") == 1
    end

    test "counts an irregular participle" do
      assert PassiveVoice.count_passive("The cake was eaten.") == 1
      assert PassiveVoice.count_passive("It has been written.") == 1
    end

    test "does not count the progressive" do
      assert PassiveVoice.count_passive("She was running to the shop.") == 0
    end

    test "does not count a predicate adjective on the stop-list" do
      # The documented false-positive class. The stop-list catches the frequent
      # ones; this pins that it does.
      assert PassiveVoice.count_passive("She was tired.") == 0
      assert PassiveVoice.count_passive("They were interested.") == 0
    end

    test "the documented misses stay documented" do
      # `get`-passives are not detected at all, and an off-list predicate
      # adjective is a false positive. Asserted rather than described, so that
      # if someone fixes either one they update this deliberately.
      assert PassiveVoice.count_passive("He got promoted last year.") == 0
      assert PassiveVoice.count_passive("The room was overcrowded.") == 1
    end

    test "reports a proportion only above the sentence floor" do
      short = context(%{}, [paragraph("The report was approved. It was fine.")])

      # Two sentences: one passive is 50%, which says nothing about a document.
      assert PassiveVoice.check(short) == :n_a
    end

    test "is info-severity, never a warning" do
      passive = String.duplicate("The report was approved by the board. ", 10)
      findings = %{} |> context([paragraph(passive)]) |> PassiveVoice.check()

      # Assert a finding EXISTS first: a severity loop over an empty list passes
      # for the wrong reason, and would keep passing if the check went silent.
      assert :passive_voice_high in codes(findings)

      # Passive voice is not categorically bad writing, so this never rises to
      # something an editor is told to fix.
      for finding <- List.wrap(findings), is_struct(finding) do
        assert finding.severity == :info
      end
    end

    test "is silent outside English" do
      passive = String.duplicate("The report was approved by the board. ", 10)

      assert PassiveVoice.check(context(%{locale: "fr"}, [paragraph(passive)])) == :n_a
    end
  end
end
