defmodule KilnCMS.Analytics.ReferrerDifferencingTest do
  @moduledoc """
  Whether two referrer publications of overlapping traffic can be differenced to
  recover a count each suppressed (#2989).

  `referrer_suppression_test.exs` shows one item-day breakdown is safe on its
  own. Kiln publishes figures wider than that: a span on the dashboard beside
  the export's per-day rows, the site chart beside each item's bar, seven days
  beside thirty. Each is the sum of two or more item-day cells, so the attack
  is the same in every case: a reader holds each cell's publication *and* the
  publication of their sum.

  The reader here knows every algorithm involved. For each pair of cells they
  hold both cells' view totals and displays and the wider figure, and their
  candidates are every pair of breakdowns that publishes all of it
  identically. A cell's suppressed category gains from the wider figure when
  it takes fewer values across those joint candidates than across the
  candidates its own publication already admits. The raw-sum version this
  replaced gains; the derived one must not.
  """
  # async: false — `suppress_referrer_group/1` reads the threshold from
  # Application env, which the setup below pins and restores.
  use ExUnit.Case, async: false

  alias KilnCMS.Analytics

  @threshold 5

  setup do
    previous = Application.get_env(:kiln_cms, :analytics_referrers, [])

    Application.put_env(:kiln_cms, :analytics_referrers,
      enabled: true,
      low_count_threshold: @threshold
    )

    on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, previous) end)
    %{sources: Analytics.referrer_sources()}
  end

  defp displays(cell), do: Enum.map(cell, fn {source, _hits, display} -> {source, display} end)

  # Every breakdown over `sources` with a view total of at most `max_total`.
  defp breakdowns(sources, max_total) do
    sources
    |> Enum.reduce([%{}], fn source, partials ->
      for partial <- partials,
          spent = partial |> Map.values() |> Enum.sum(),
          hits <- 0..(max_total - spent)//1,
          do: Map.put(partial, source, hits)
    end)
  end

  # The wider figure as #2989 found it: the raw sum, suppressed again. Every sum
  # is decided once up front; the pair loop below would otherwise re-run the
  # algorithm on the same few thousand sums two hundred thousand times.
  defp raw_sum_span(sources, max_total) do
    published =
      Map.new(breakdowns(sources, 2 * max_total), fn b ->
        {b, displays(Analytics.suppress_referrer_group(b))}
      end)

    fn b1, b2, _cell1, _cell2 ->
      Map.fetch!(published, Map.merge(b1, b2, fn _s, x, y -> x + y end))
    end
  end

  # The wider figure as it is now: derived from the two cells' displays.
  defp derived_span(_b1, _b2, cell1, cell2), do: Analytics.derive_referrer_group([cell1, cell2])

  describe "two cells and the figure for both (#2989)" do
    # The owner's simulation: a threshold of 5, two item-days, each with up to
    # six views. The same pair models a 2-day span against the export's two
    # per-day rows, and the site chart against two items' bars on one day.
    test "suppressing the raw sum lets the wider figure pin a suppressed cell", %{
      sources: sources
    } do
      assert gains(sources, 6, raw_sum_span(sources, 6)) > 0
    end

    test "deriving it from the cells' displays pins nothing", %{sources: sources} do
      assert gains(sources, 6, &derived_span/4) == 0
    end

    test "a span against the export's per-day rows: other 1 then other 4" do
      day1 = Analytics.suppress_referrer_group(%{other: 1})
      day2 = Analytics.suppress_referrer_group(%{other: 4})

      # Each day is hidden whole in the export.
      assert Enum.all?(displays(day1) ++ displays(day2), &(elem(&1, 1) == "hidden"))

      # The raw sum would publish other: 5 exactly, and with the day totals
      # of 1 and 4 beside it, both days are pinned.
      assert Keyword.fetch!(displays(Analytics.suppress_referrer_group(%{other: 5})), :other) == 5

      assert Keyword.fetch!(Analytics.derive_referrer_group([day1, day2]), :other) == "hidden"
    end

    test "the site chart against two items' bars: direct 10 beside direct 1, search 9" do
      item_a = Analytics.suppress_referrer_group(%{direct: 10})
      item_b = Analytics.suppress_referrer_group(%{direct: 1, search: 9})

      assert Keyword.fetch!(displays(item_a), :direct) == 10
      assert Keyword.fetch!(displays(item_b), :direct) == "< 5"
      assert Keyword.fetch!(displays(item_b), :search) == "hidden"

      # The raw site total publishes direct: 11, so B's direct is 11 - 10 = 1.
      site_raw = displays(Analytics.suppress_referrer_group(%{direct: 11, search: 9}))
      assert Keyword.fetch!(site_raw, :direct) == 11

      site = Analytics.derive_referrer_group([item_a, item_b])
      assert Keyword.fetch!(site, :direct) == "hidden"
      assert Keyword.fetch!(site, :search) == "hidden"
    end
  end

  describe "derive_referrer_group/1" do
    test "sums a category every cell shows as an integer" do
      cells = [
        Analytics.suppress_referrer_group(%{search: 6, direct: 7}),
        Analytics.suppress_referrer_group(%{search: 9}),
        Analytics.suppress_referrer_group(%{})
      ]

      derived = Analytics.derive_referrer_group(cells)
      assert Keyword.fetch!(derived, :search) == 15
      assert Keyword.fetch!(derived, :direct) == 7
      assert Keyword.fetch!(derived, :social) == 0
    end

    test ~s(hides a category any cell suppresses, whether as "< n" or "hidden") do
      partial = Analytics.suppress_referrer_group(%{social: 2, search: 40, other: 50})
      assert Keyword.fetch!(displays(partial), :social) == "< 5"
      assert Keyword.fetch!(displays(partial), :other) == "hidden"

      derived =
        Analytics.derive_referrer_group([
          partial,
          Analytics.suppress_referrer_group(%{social: 30, other: 30})
        ])

      # Never "< n": the sum of a "< n" and a 30 is not below the threshold.
      assert Keyword.fetch!(derived, :social) == "hidden"
      assert Keyword.fetch!(derived, :other) == "hidden"
      assert Keyword.fetch!(derived, :search) == 40
    end

    test "a hidden zero hides the category too" do
      # Hidden whole, zeros included: the zero is a term, not a courtesy.
      tiny = Analytics.suppress_referrer_group(%{search: 1, social: 1})
      assert {:internal, 0, "hidden"} in tiny

      derived =
        Analytics.derive_referrer_group([tiny, Analytics.suppress_referrer_group(%{internal: 8})])

      assert Keyword.fetch!(derived, :internal) == "hidden"
    end

    test "no cells is a zero in every category", %{sources: sources} do
      assert Analytics.derive_referrer_group([]) == Enum.map(sources, &{&1, 0})
    end

    # The structural reason every route is covered: two sets of cells that
    # publish the same displays derive the same figure, whatever their hits.
    test "depends on the displays alone, never the raw hits" do
      a = [Analytics.suppress_referrer_group(%{social: 2, search: 40, other: 50})]
      b = [Analytics.suppress_referrer_group(%{social: 4, search: 40, other: 90})]

      assert Enum.map(a, &displays/1) == Enum.map(b, &displays/1)
      assert Analytics.derive_referrer_group(a) == Analytics.derive_referrer_group(b)
    end
  end

  describe "published_referrer_cells/2" do
    defp bucket(day, id, source, hits),
      do: %{day: day, content_type: "page", content_id: id, source: source, hits: hits}

    test "decides one breakdown per item-day and drops days after the last published one" do
      today = ~D[2026-11-21]
      yesterday = Date.add(today, -1)
      id = Ecto.UUID.generate()
      other = Ecto.UUID.generate()

      cells =
        Analytics.published_referrer_cells(
          [
            bucket(yesterday, id, :search, 6),
            bucket(yesterday, id, :direct, 7),
            bucket(yesterday, other, :search, 9),
            bucket(today, id, :search, 50)
          ],
          yesterday
        )

      assert length(cells) == 2
      {_key, cell} = Enum.find(cells, &match?({{_, "page", ^id}, _}, &1))
      assert {:search, 6, 6} in cell
      assert {:direct, 7, 7} in cell
      refute Enum.any?(cells, &match?({{^today, _, _}, _}, &1))
    end

    test "defaults to yesterday, so today's growing bucket is never published" do
      assert Analytics.last_published_referrer_day() == Date.add(Date.utc_today(), -1)
      id = Ecto.UUID.generate()

      assert Analytics.published_referrer_cells([bucket(Date.utc_today(), id, :search, 9)]) == []
    end
  end

  # Count the joint classes in which the wider figure narrows some suppressed
  # cell category below what that cell's own class allows.
  defp gains(sources, max_total, span_fun) do
    days =
      for b <- breakdowns(sources, max_total) do
        cell = Analytics.suppress_referrer_group(b)
        total = b |> Map.values() |> Enum.sum()
        %{hits: b, cell: cell, class: {total, displays(cell)}}
      end

    # What one cell's publication alone leaves open, per suppressed category.
    alone =
      days
      |> Enum.group_by(& &1.class, & &1.hits)
      |> Map.new(fn {class, members} ->
        {class, Map.new(sources, fn s -> {s, members |> Enum.map(& &1[s]) |> MapSet.new()} end)}
      end)

    joint =
      for d1 <- days, d2 <- days, reduce: %{} do
        acc ->
          key = {d1.class, d2.class, span_fun.(d1.hits, d2.hits, d1.cell, d2.cell)}
          Map.update(acc, key, [{d1.hits, d2.hits}], &[{d1.hits, d2.hits} | &1])
      end

    Enum.count(joint, fn {{class1, class2, _span}, members} ->
      narrows?(class1, alone, sources, Enum.map(members, &elem(&1, 0))) or
        narrows?(class2, alone, sources, Enum.map(members, &elem(&1, 1)))
    end)
  end

  defp narrows?({_total, cell_displays} = class, alone, sources, members) do
    Enum.any?(sources, fn source ->
      values = members |> Enum.map(& &1[source]) |> MapSet.new()

      not is_integer(Keyword.fetch!(cell_displays, source)) and
        MapSet.size(values) < MapSet.size(alone[class][source])
    end)
  end
end
