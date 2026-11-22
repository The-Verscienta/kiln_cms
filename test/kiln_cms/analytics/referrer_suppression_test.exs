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
  knows the algorithm can construct — every breakdown with the same view total
  that `Analytics.suppress_referrer_group/1` would have published *identically* —
  and asserts there is more than one. That is how the old algorithm was caught,
  and reasoning about it is how it shipped.

  An earlier version of this search let a `"hidden"` cell range over the whole
  residual, a weaker reader than a real one: it did not know the partner is the
  first largest of the categories that are not naturally low, so it agreed with
  `ambiguous?/3` when both were wrong (#2752). Re-running the algorithm on every
  candidate is the reader's whole knowledge, with nothing left to restate.

  That search fills in a partial publication's cells one at a time, so it
  cannot reach an all-hidden one, whose reader has only the total. Those are
  checked by enumerating every breakdown of each small total and grouping them
  by what the algorithm publishes (#2981): every category of an all-hidden
  group must take at least two values, and no suppressed category of a partial
  group may be pinned to a nonzero one. A `"hidden"` partner pinned to `0` is
  allowed — it says what a published `0` would.

  None of this covers a reader holding two publications of overlapping traffic
  (#2989): `referrer_differencing_test.exs` does.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Analytics

  setup do
    previous = Application.get_env(:kiln_cms, :analytics_referrers, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, previous) end)
    %{threshold: Analytics.low_count_threshold()}
  end

  defp published(totals), do: Analytics.suppress_referrer_group(totals)

  defp published(totals, sources), do: Analytics.suppress_referrer_group(totals, sources)

  defp suppressed?(rows), do: Enum.any?(rows, fn {_s, _h, display} -> is_binary(display) end)

  defp displays(rows), do: Enum.map(rows, fn {source, _hits, display} -> {source, display} end)

  defp all_hidden?(rows), do: Enum.all?(rows, fn {_s, _h, display} -> display == "hidden" end)

  # Every breakdown a reader could construct for a partial publication, given
  # the item's own view total: the same exacts, each `"< n"` somewhere in
  # `1..n-1`, the `"hidden"` partner taking whatever is left — kept only when
  # the algorithm, run on it, publishes exactly what the reader sees.
  #
  # Deliberately not calling `Analytics.ambiguous?/3` for the verdict: that
  # function is the claim, so a test sharing its arithmetic would agree with it
  # about being wrong. Running the whole algorithm on each candidate is what
  # the reader can do, and it carries every rule they know — the partner's
  # bounds, its tie-break — without this file restating any of them.
  defp consistent(totals, rows) do
    total = totals |> Map.values() |> Enum.sum()
    readings(total, displays(rows), &displays(Analytics.suppress_referrer_group(&1)))
  end

  # Candidates for `displays` over `total`, filtered by `project`, the
  # function the reader believes produced them. Lazy and truncated at two:
  # "more than one" is the whole question.
  defp readings(total, displays, project) do
    exact = for {source, display} <- displays, is_integer(display), do: {source, display}
    lows = for {source, "< " <> n} <- displays, do: {source, String.to_integer(n)}
    partner = for {source, "hidden"} <- displays, do: source
    residual = total - (exact |> Enum.map(&elem(&1, 1)) |> Enum.sum())

    lows
    |> low_values()
    |> Stream.flat_map(fn assigned ->
      slack = residual - (assigned |> Enum.map(&elem(&1, 1)) |> Enum.sum())

      case partner do
        [] when slack == 0 -> [Map.new(exact ++ assigned)]
        [source] when slack >= 0 -> [Map.new([{source, slack} | exact ++ assigned])]
        _other -> []
      end
    end)
    |> Stream.filter(&(project.(&1) == displays))
    |> Enum.take(2)
  end

  defp low_values([]), do: [[]]

  defp low_values([{source, n} | rest]) do
    Stream.flat_map(1..(n - 1)//1, fn value ->
      Stream.map(low_values(rest), &[{source, value} | &1])
    end)
  end

  defp assert_not_recoverable(totals) do
    rows = published(totals)

    # An all-hidden breakdown is out of reach of this search; the class sweep
    # in "an all-hidden breakdown (#2981)" covers it.
    if suppressed?(rows) and not all_hidden?(rows) do
      assignments = consistent(totals, rows)

      assert length(assignments) > 1,
             """
             #{inspect(totals)} publishes as #{inspect(displays(rows))}
             and exactly one breakdown is consistent with it plus the view total
             (#{Enum.sum(Map.values(totals))}) — the suppressed value is recoverable.
             """
    end

    rows
  end

  # The shape a breakdown with something naturally low would take if published
  # partially: its own ranges, the partner `"hidden"`, the rest exact. This is
  # the documented rule a reader knows — the partner is the FIRST largest of
  # the categories that are not naturally low, in source order — restated so
  # `ambiguous?/3` can be checked against it in the direction where the
  # algorithm itself publishes nothing to compare with: the breakdowns it hid
  # entirely.
  defp partial_form(totals, threshold) do
    raw = Enum.map(Analytics.referrer_sources(), &{&1, Map.get(totals, &1, 0)})

    partner =
      raw
      |> Enum.reject(fn {_source, hits} -> hits > 0 and hits < threshold end)
      |> case do
        [] -> nil
        candidates -> candidates |> Enum.max_by(&elem(&1, 1)) |> elem(0)
      end

    Enum.map(raw, fn
      {^partner, _hits} -> {partner, "hidden"}
      {source, hits} when hits > 0 and hits < threshold -> {source, "< #{threshold}"}
      {source, hits} -> {source, hits}
    end)
  end

  defp put_threshold(threshold) do
    Application.put_env(:kiln_cms, :analytics_referrers, low_count_threshold: threshold)
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

  describe "a partner that cannot be zero (#2752)" do
    # The issue's breakdown. It was published as `< 5, 0, < 5, hidden, 5` with
    # 12 views, and the published `5` means the partner — the largest — is at
    # least 5, so the two lows hold 2 views and the partner exactly 5.
    test "two low categories beside two at the threshold" do
      totals = %{direct: 1, search: 1, social: 5, other: 5}
      rows = assert_not_recoverable(totals)

      refute displays(rows) == [
               direct: "< 5",
               internal: 0,
               search: "< 5",
               social: "hidden",
               other: 5
             ]

      # No other partner is open to it, so nothing partial can be published.
      assert all_hidden?(rows)
    end

    # The tie-break: `social` and an equal `other` are both largest, and the
    # first wins, so a published exact before the partner bounds it strictly.
    test "the breakdowns the tie-break pins" do
      assert_not_recoverable(%{search: 1, social: 5, other: 1})

      put_threshold(3)
      assert_not_recoverable(%{direct: 3, internal: 1, search: 1, social: 4, other: 1})
      assert_not_recoverable(%{direct: 1, search: 1, social: 1, other: 3})
    end

    # Every five-category breakdown with values up to just past the threshold:
    # small enough to enumerate, and it holds what the older sweeps missed —
    # two or more lows beside published exacts at or near the threshold, and
    # ties between those exacts and the partner.
    test "no partial publication is recoverable, and ambiguous?/3 agrees" do
      for threshold <- [3, 5] do
        put_threshold(threshold)
        values = 0..(threshold + 2)

        cache =
          for direct <- values,
              internal <- values,
              search <- values,
              social <- values,
              other <- values,
              reduce: %{} do
            cache ->
              totals = %{
                direct: direct,
                internal: internal,
                search: search,
                social: social,
                other: other
              }

              check_breakdown(totals, threshold, cache)
          end

        assert map_size(cache) > 0
      end
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
        put_threshold(threshold)

        for direct <- 0..12, internal <- [0, 1, threshold, threshold + 3, 40] do
          assert_not_recoverable(%{direct: direct, internal: internal})
        end
      end
    end
  end

  describe "an all-hidden breakdown (#2981)" do
    # The issue's case: at a threshold of 5, a total of 5 was hidden whole only
    # as five 1s, so a reader who knows the algorithm read every category off
    # five "hidden" labels and the view total.
    test "five views at a threshold of 5 leave every category open" do
      put_threshold(5)

      hidden_whole =
        for breakdown <- breakdowns(5), all_hidden?(published(breakdown)), do: breakdown

      assert %{direct: 1, internal: 1, search: 1, social: 1, other: 1} in hidden_whole
      assert %{direct: 2, internal: 1, search: 1, social: 1, other: 0} in hidden_whole

      for {source, values} <- values_by_category(hidden_whole) do
        assert length(values) >= 2, "#{source} is pinned to #{inspect(values)}"
      end
    end

    # The reader's whole view of one publication is its total and its labels,
    # so every breakdown of a total, grouped by what the algorithm publishes,
    # is every candidate class there is. Totals run to the threshold plus
    # four to keep the test fast; that covers the classes the rule was built
    # around (threshold 5, total 5) but not every total. Larger totals rest on
    # the wider search described in `Analytics.suppress_referrer_group/1`.
    test "no small total leaves a suppressed category pinned" do
      for threshold <- [2, 3, 5, 10], total <- 0..(threshold + 4) do
        put_threshold(threshold)

        total
        |> breakdowns()
        |> Enum.group_by(&displays(published(&1)))
        |> Enum.each(fn {form, members} -> check_class(form, members, threshold, total) end)
      end
    end
  end

  describe "suppress_referrer_group/2 (#3123)" do
    # The explicit-list arity is a test seam; the live one must be it with
    # `referrer_sources/0`, or the sweep below would be checking another function.
    test "the live arity publishes exactly what /2 does over the live list" do
      for threshold <- [2, 3, 5, 10], total <- 0..12, breakdown <- breakdowns(total) do
        put_threshold(threshold)

        assert Analytics.suppress_referrer_group(breakdown) ==
                 Analytics.suppress_referrer_group(breakdown, Analytics.referrer_sources())
      end
    end
  end

  # The wide search behind the #2981 rule (#3123): thresholds 2-20, view totals
  # up to 20-40 (by width) and four to six categories, through `suppress_referrer_group/2`
  # with a generated category list. Excluded by default (`:slow_sweep`, see
  # test_helper.exs); run it with
  #
  #     mix test --only slow_sweep test/kiln_cms/analytics/referrer_suppression_test.exs
  #
  # after any change to the algorithm or to `referrer_sources/0`.
  describe "the wide sweep (#3123)" do
    @describetag :slow_sweep
    @describetag timeout: :infinity

    # {categories, largest view total}. The cost is the number of breakdowns,
    # C(total + width - 1, width - 1) summed over totals, times 19 thresholds:
    # width 5 to a total of 50 is 3.5M per threshold, about an hour, so the
    # wider the categories the lower the bound. The tightest classes sit at
    # totals near the category count and the threshold, well inside these.
    @sweep [{4, 40}, {5, 30}, {6, 20}]

    test "no all-hidden or partial publication leaves a category pinned" do
      for {width, max_total} <- @sweep, threshold <- 2..20 do
        put_threshold(threshold)
        sources = sweep_sources(width)

        for total <- 0..max_total do
          total
          |> breakdowns(sources)
          |> Enum.group_by(&displays(published(&1, sources)))
          |> Enum.each(fn {form, members} -> check_class(form, members, threshold, total) end)
        end
      end
    end

    # The criterion has to be able to fail, or the sweep above proves nothing:
    # three categories at a threshold of 3 is where the rule does not hold.
    test "three categories at a threshold of 3 still fail it" do
      put_threshold(3)
      sources = sweep_sources(3)

      form = displays(published(%{s1: 2, s2: 2, s3: 2}, sources))
      members = Enum.filter(breakdowns(6, sources), &(displays(published(&1, sources)) == form))

      assert_raise ExUnit.AssertionError, ~r/pins/, fn ->
        check_class(form, members, 3, 6)
      end
    end
  end

  defp sweep_sources(width), do: for(n <- 1..width, do: :"s#{n}")

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

    # The #2981 rule hides a handful of views only when they are spread over
    # all but one category. Each of these sits just outside it, and goes
    # all-hidden if the rule is loosened by one category or one view.
    test "a small breakdown over fewer categories stays partial" do
      rows = published(%{direct: 3, internal: 1, search: 1})
      assert suppressed?(rows) and not all_hidden?(rows)

      for threshold <- [3, 5] do
        put_threshold(threshold)
        rows = published(%{direct: 2, internal: 2, search: 1, social: 1})

        assert suppressed?(rows) and not all_hidden?(rows),
               "six views over four categories at #{threshold}: #{inspect(displays(rows))}"
      end
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

  # Every breakdown of `total` over `Analytics.referrer_sources/0`, as totals
  # maps — so a change to the category list re-runs the #2981 sweep over it.
  defp breakdowns(total, sources \\ Analytics.referrer_sources()) do
    total
    |> compositions(length(sources))
    |> Enum.map(&Map.new(Enum.zip(sources, &1)))
  end

  defp compositions(total, 1), do: [[total]]

  defp compositions(total, parts) do
    for value <- 0..total, rest <- compositions(total - value, parts - 1), do: [value | rest]
  end

  defp values_by_category(members) do
    Map.new(members |> hd() |> Map.keys(), fn source ->
      {source, members |> Enum.map(&Map.fetch!(&1, source)) |> Enum.uniq() |> Enum.sort()}
    end)
  end

  # One class of the #2981 sweep: every breakdown of `total` the algorithm
  # publishes as `form`.
  defp check_class(form, members, threshold, total) do
    where = "#{inspect(form)} at threshold #{threshold}, total #{total}"
    values = values_by_category(members)
    suppressed = for {source, display} <- form, is_binary(display), do: source

    cond do
      suppressed == [] ->
        :ok

      Enum.all?(form, fn {_source, display} -> display == "hidden" end) ->
        for {source, seen} <- values do
          assert length(seen) >= 2, "#{where} pins #{source} to #{inspect(seen)}"
        end

      true ->
        assert length(members) >= 2, "#{where} is consistent with one breakdown only"

        # A partner pinned to 0 is allowed: it says what a published 0 would.
        for source <- suppressed do
          seen = Map.fetch!(values, source)
          refute match?([n] when n > 0, seen), "#{where} pins #{source} to #{inspect(seen)}"
        end
    end
  end

  # One breakdown of the sweep above. `cache` holds the reader's count per
  # `{total, partial form}` — every breakdown in that class sees the same
  # candidates, so it is computed once.
  defp check_breakdown(totals, threshold, cache) do
    raw = Enum.map(Analytics.referrer_sources(), &{&1, Map.get(totals, &1, 0)})
    rows = published(totals)

    if suppressed?(rows) do
      total = totals |> Map.values() |> Enum.sum()
      form = partial_form(totals, threshold)
      key = {total, form}

      cache =
        Map.put_new_lazy(cache, key, fn ->
          length(readings(total, form, &partial_form(&1, threshold)))
        end)

      reader = Map.fetch!(cache, key)
      suppressed = for {source, display} <- form, is_binary(display), do: source

      # Both directions: ambiguous?/3 says yes exactly when the reader of the
      # partial form is left with two or more. A breakdown it calls ambiguous
      # can still be hidden whole — the #2981 rule hides some ambiguous ones
      # too — so the published rows are compared only when they are partial.
      assert Analytics.ambiguous?(raw, suppressed, threshold) == reader >= 2,
             "#{inspect(totals)} at #{threshold}: ambiguous?/3 disagrees with " <>
               "the #{reader} breakdown(s) a reader finds for #{inspect(form)}"

      if not all_hidden?(rows) do
        assert displays(rows) == form
        assert length(consistent(totals, rows)) > 1, "#{inspect(totals)} is recoverable"
      end

      cache
    else
      cache
    end
  end
end
