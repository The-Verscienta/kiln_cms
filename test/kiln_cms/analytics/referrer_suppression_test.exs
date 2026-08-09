defmodule KilnCMS.Analytics.ReferrerSuppressionTest do
  @moduledoc """
  Whether a suppressed referrer count can be recovered from what is published
  beside it (#1073).

  The claim under test is not "a number was replaced by a label" — #620 had
  that and it was recoverable anyway. It is the property the labels are for: no
  suppressed value is **uniquely determined** by the rest of the published
  breakdown *plus the view total*, which both the dashboard and the export print
  right next to it.

  So the tests brute-force it. `consistent/2` reconstructs what a reader who
  knows the algorithm can construct — every assignment of counts to the hidden
  categories consistent with the published exacts, the announced ranges, and the
  total — and asserts there is more than one. That is how the old algorithm was
  caught, and reasoning about it is how it shipped.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Analytics

  setup do
    previous = Application.get_env(:kiln_cms, :analytics_referrers, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, previous) end)
    %{threshold: Analytics.low_count_threshold()}
  end

  defp published(totals), do: Analytics.suppress_referrer_group(totals)

  defp suppressed?(rows), do: Enum.any?(rows, fn {_s, _h, display} -> is_binary(display) end)

  # Every assignment a reader could construct, given the published projection
  # and the item's own view total. Deliberately re-derived here rather than
  # calling `Analytics.ambiguous?/3`: that function is the claim, so a test
  # sharing its arithmetic would agree with it about being wrong.
  #
  # Lazy, and that is not an optimisation. A `"hidden"` category ranges over
  # `0..residual`, so a busy document's breakdown has millions of candidate
  # tuples — and every caller here only ever asks whether there are two.
  defp consistent(totals, rows) do
    total = totals |> Map.values() |> Enum.sum()
    exact = for {_s, _h, d} <- rows, is_integer(d), do: d
    residual = total - Enum.sum(exact)

    ranges =
      for {source, _hits, display} <- rows, is_binary(display) do
        case display do
          "hidden" -> {source, 0..residual//1}
          "< " <> n -> {source, 1..(String.to_integer(n) - 1)//1}
        end
      end

    residual |> assignments(ranges) |> Enum.take(2)
  end

  defp assignments(0, []), do: [[]]
  defp assignments(_residual, []), do: []

  defp assignments(residual, [{source, range} | rest]) do
    range
    |> Stream.take_while(&(&1 <= residual))
    |> Stream.flat_map(fn value ->
      residual
      |> Kernel.-(value)
      |> assignments(rest)
      |> Stream.map(&[{source, value} | &1])
    end)
  end

  defp assert_not_recoverable(totals) do
    rows = published(totals)

    if suppressed?(rows) do
      assignments = consistent(totals, rows)

      assert length(assignments) > 1,
             """
             #{inspect(totals)} publishes as #{inspect(Enum.map(rows, fn {s, _h, d} -> {s, d} end))}
             and exactly one assignment is consistent with it plus the view total
             (#{Enum.sum(Map.values(totals))}) — the suppressed value is recoverable.
             """
    end

    rows
  end

  describe "the breakdowns #1073 brute-forced" do
    # Each row of the issue's table, which the previous algorithm published in
    # a form admitting exactly one assignment.
    test "a single low category with four genuine zeros" do
      rows = assert_not_recoverable(%{direct: 3})

      # Nowhere to hide at three views total, so the whole breakdown goes —
      # including the zeros, which would otherwise each remove an unknown.
      assert Enum.all?(rows, fn {_s, _h, display} -> display == "hidden" end)
    end

    test "a low category beside three large ones" do
      rows = assert_not_recoverable(%{direct: 2, search: 40, social: 50, other: 60})

      # The largest is the partner: it is bounded below by every published
      # exact and unbounded above, so the residual splits many ways.
      assert {:other, 60, "hidden"} in rows
      assert {:search, 40, 40} in rows
    end

    test "a low category beside four equal ones at the threshold" do
      assert_not_recoverable(%{direct: 4, internal: 5, search: 5, social: 5, other: 5})
    end

    test "two low categories with three genuine zeros" do
      rows = assert_not_recoverable(%{direct: 1, internal: 1})

      assert Enum.all?(rows, fn {_s, _h, display} -> display == "hidden" end)
    end

    test "a low category beside four large ones" do
      assert_not_recoverable(%{direct: 4, internal: 100, search: 200, social: 300, other: 400})
    end
  end

  describe "across the shape of a real breakdown" do
    # The systematic version: small totals are where the export lives, because
    # its grain is per day.
    test "no small breakdown is recoverable" do
      for direct <- 0..6, internal <- 0..6, search <- 0..6 do
        assert_not_recoverable(%{direct: direct, internal: internal, search: search})
      end
    end

    test "no breakdown with one small category beside a large one is recoverable" do
      for low <- 1..4, big <- [5, 6, 20, 500] do
        assert_not_recoverable(%{direct: low, internal: big})
        assert_not_recoverable(%{direct: low, internal: big, search: big, social: big})
        assert_not_recoverable(%{direct: low, internal: 0, search: big})
      end
    end

    test "no breakdown is recoverable at a tighter or looser threshold" do
      for threshold <- [2, 3, 10] do
        Application.put_env(:kiln_cms, :analytics_referrers, low_count_threshold: threshold)

        for direct <- 0..12, internal <- [0, 1, threshold, threshold + 3, 40] do
          assert_not_recoverable(%{direct: direct, internal: internal})
        end
      end
    end
  end

  describe "what is still published" do
    # The cost has to be bounded, or "suppress everything" would pass every
    # test above and make the feature pointless.
    test "a breakdown with nothing small is published exactly" do
      rows = published(%{direct: 10, internal: 20, search: 30, social: 40, other: 50})

      assert Enum.all?(rows, fn {_s, hits, display} -> display == hits end)
    end

    test "an empty breakdown publishes zeros, not hidden" do
      rows = published(%{})

      assert Enum.all?(rows, fn {_s, _h, display} -> display == 0 end)
    end

    # The busy document keeps most of its breakdown: one category goes to the
    # label, one to the partner, the rest stay exact.
    test "a busy document keeps the categories that are not the partner" do
      rows = published(%{direct: 2, internal: 100, search: 200, social: 300, other: 400})

      exact = for {_s, _h, display} <- rows, is_integer(display), do: display

      assert length(exact) == 3
    end

    test "every category is present, including ones with no hits" do
      rows = published(%{direct: 7})

      assert Enum.map(rows, &elem(&1, 0)) == Analytics.referrer_sources()
    end
  end

  describe "the labels" do
    test "a naturally low category announces its own range" do
      rows = published(%{direct: 2, internal: 100, search: 200, social: 300, other: 400})

      assert {:direct, 2, "< 5"} in rows
    end

    # `"< n"` would be a lie: the partner's real value is at or above the
    # threshold whenever there is one to be the partner.
    test "a forced partner is 'hidden', never '< n'" do
      rows = published(%{direct: 2, internal: 100, search: 200, social: 300, other: 400})

      assert {:other, 400, "hidden"} in rows
    end
  end

  describe "ambiguous?/3" do
    # It is public so a test can check it against the brute force rather than
    # against itself.
    test "agrees with the brute force about every small breakdown" do
      threshold = Analytics.low_count_threshold()

      for direct <- 0..6, internal <- 0..6 do
        totals = %{direct: direct, internal: internal}
        raw = Enum.map(Analytics.referrer_sources(), &{&1, Map.get(totals, &1, 0)})
        rows = published(totals)
        hidden = for {source, _h, display} <- rows, is_binary(display), do: source

        if hidden != [] and length(hidden) < length(raw) do
          assert Analytics.ambiguous?(raw, hidden, threshold),
                 "#{inspect(totals)} was published partially, so it must be ambiguous"

          assert length(consistent(totals, rows)) > 1
        end
      end
    end
  end
end
