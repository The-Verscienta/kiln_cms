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

        assert Enum.all?(lenses, &(&1 in [:seo, :accessibility])),
               "#{inspect(module)} declares an unknown lens: #{inspect(lenses)}"
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
