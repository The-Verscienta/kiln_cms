defmodule Kiln.Advisory.LensesTest do
  @moduledoc """
  Two panels over one set of checks (#495).

  The property that matters is that neither panel shows the other's noise
  while both still see the checks they share — a skipped heading level is an
  accessibility finding AND a search one, and an author fixing it should not
  have to find it twice.
  """
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Finding
  alias Kiln.Advisory.Registry
  alias Kiln.Advisory.Report

  defmodule BothCheck do
    @moduledoc false
    use Kiln.Advisory
    def check(_context), do: finding(:warning, :in_both)
  end

  defmodule SeoOnlyCheck do
    @moduledoc false
    use Kiln.Advisory
    def check(_context), do: finding(:warning, :seo_only)
    def lenses, do: [:seo]
  end

  defmodule A11yOnlyCheck do
    @moduledoc false
    use Kiln.Advisory
    def check(_context), do: finding(:warning, :a11y_only)
    def lenses, do: [:accessibility]
  end

  defmodule MixedCheck do
    @moduledoc false
    use Kiln.Advisory

    def check(_context) do
      [
        finding(:warning, :mixed_shared),
        finding(:warning, :mixed_seo_only) |> lensed([:seo])
      ]
    end
  end

  defmodule PassingCheck do
    @moduledoc false
    use Kiln.Advisory
    def check(_context), do: :ok
    def lenses, do: [:accessibility]
  end

  defp context, do: %Context{body: %Body{}}

  # A document messy enough that most real checks actually produce findings —
  # an empty one makes them all `:n_a` and turns any assertion about their
  # findings vacuous.
  defp rich_context do
    body = %Body{
      text: "Alpha beta gamma.",
      folded_text: "alpha beta gamma.",
      folded_words: ~w[alpha beta gamma],
      word_count: 3,
      first_paragraph: "Alpha beta gamma.",
      headings: [%{level: 3, text: "Skipped down to three"}],
      sentence_count: 1,
      sentence_word_counts: [3],
      paragraph_word_counts: [3],
      image_count: 1,
      images_missing_alt: [0],
      links: [%{text: "click here", href: "https://example.com", index: 0}],
      empty_headings: [0],
      capitalised_runs: ["THIS IS A REALLY IMPORTANT NOTICE"]
    }

    Context.new(%{title: "", slug: "", seo_description: ""}, body, locale: "en")
  end

  defp codes(outcomes, lens) do
    outcomes
    |> Registry.by_lens(lens)
    |> Registry.findings()
    |> Enum.map(& &1.code)
  end

  test "a check defaults to appearing in BOTH panels" do
    # The default matters: a plugin author who never thought about the
    # distinction should get a panel, not silence.
    assert BothCheck.lenses() == [:seo, :accessibility]
  end

  test "each lens sees the shared check plus only its own" do
    outcomes =
      Registry.run(context(), [BothCheck, SeoOnlyCheck, A11yOnlyCheck])

    assert codes(outcomes, :seo) == [:in_both, :seo_only]
    assert codes(outcomes, :accessibility) == [:in_both, :a11y_only]
  end

  describe "a finding may narrow past its own check" do
    test "so one check can report into both panels and still keep a finding out of one" do
      outcomes = Registry.run(context(), [MixedCheck])

      assert codes(outcomes, :seo) == [:mixed_shared, :mixed_seo_only]
      assert codes(outcomes, :accessibility) == [:mixed_shared]
    end

    test "lensed/2 sets it, and an ordinary finding leaves it nil" do
      assert %Finding{lenses: nil} = Kiln.Advisory.finding(:warning, :plain)

      assert %Finding{lenses: [:seo]} =
               Kiln.Advisory.finding(:warning, :plain) |> Kiln.Advisory.lensed([:seo])
    end
  end

  test "a passing check counts toward its own lens's tally and not the other's" do
    outcomes = Registry.run(context(), [PassingCheck, SeoOnlyCheck])

    a11y = outcomes |> Registry.by_lens(:accessibility) |> Report.from_outcomes(%Body{})
    seo = outcomes |> Registry.by_lens(:seo) |> Report.from_outcomes(%Body{})

    assert {a11y.passed, a11y.total} == {1, 1}
    assert {seo.passed, seo.total} == {0, 1}
  end

  test "grading is per lens, so a clean panel reads green beside a failing one" do
    outcomes = Registry.run(context(), [PassingCheck, SeoOnlyCheck])

    assert (outcomes |> Registry.by_lens(:accessibility) |> Report.from_outcomes(%Body{})).grade ==
             :good

    assert (outcomes |> Registry.by_lens(:seo) |> Report.from_outcomes(%Body{})).grade == :ok
  end

  describe "the real registry" do
    test "every configured check declares lenses, and every lens has checks" do
      for module <- Registry.checks() do
        lenses = module.lenses()

        assert lenses != [],
               "#{inspect(module)} declares no lenses, so its findings render nowhere"

        assert Enum.all?(lenses, &(&1 in [:seo, :accessibility, :compliance])),
               "#{inspect(module)} declares an unknown lens: #{inspect(lenses)}"
      end
    end

    # `:compliance` (#377) is the one lens NOT in the default `lenses/0`, so an
    # ordinary check must never land in it. That panel's value depends on it
    # not crying wolf, and a generic check drifting into it is exactly how that
    # would happen without anyone noticing.
    test "only checks that opt in report into the compliance panel" do
      for module <- Registry.checks(), :compliance in module.lenses() do
        assert module.lenses() == [:compliance],
               "#{inspect(module)} mixes :compliance with another lens: " <>
                 "#{inspect(module.lenses())}"
      end

      refute :compliance in KilnCMS.Seo.Checks.Meta.lenses()
      refute :compliance in Kiln.Advisory.Checks.Headings.lenses()
    end

    # `by_lens/2` reads a per-FINDING `lenses` before falling back to the
    # check's, so pinning `lenses/0` alone leaves a way in: any check may call
    # `Kiln.Advisory.lensed/2` to narrow one finding, and `Seo.Checks.Readability`
    # already does. Nothing outside the compliance namespace may use it to
    # reach that panel.
    test "no non-compliance check narrows a finding INTO the compliance panel" do
      for module <- Registry.checks(), module.lenses() != [:compliance] do
        outcomes = Registry.run(rich_context(), [module])

        assert [] == Registry.by_lens(outcomes, :compliance),
               "#{inspect(module)} produced a finding lensed into :compliance"
      end
    end

    test "thin content is search-only — a short page is perfectly accessible" do
      # Readability reports into both panels, but not every one of its
      # findings belongs in both; this is the case that forced per-finding
      # lensing to exist.
      body = %Body{word_count: 12, sentence_word_counts: [12], paragraph_word_counts: [12]}
      outcomes = Registry.run(%Context{body: body}, [KilnCMS.Seo.Checks.Readability])

      assert :thin_content in codes(outcomes, :seo)
      refute :thin_content in codes(outcomes, :accessibility)
    end
  end
end
