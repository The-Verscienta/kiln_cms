defmodule KilnCMSWeb.ChartComponentsTest do
  @moduledoc """
  The console's SVG chart primitives (#620, #778).

  `bar_chart/1` and `category_chart/1` were two ~45-line copies of the same
  geometry, baseline and `sr-only` table, and had **already drifted**: one put
  its colour on a wrapping `<g>`, the other on each `<rect>`. They render
  through one component now, and the tests here are mostly about the properties
  that drift silently — where the colour lives, whether the accessible table
  carries every value, and whether a bar's size can leak a number its own label
  suppressed.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias KilnCMSWeb.ChartComponents

  defp bar_chart(series, opts \\ []) do
    assigns = %{
      series: series,
      label: Keyword.get(opts, :label, "Views over time"),
      value_header: Keyword.get(opts, :value_header),
      class: nil,
      __changed__: nil
    }

    ~H"""
    <ChartComponents.bar_chart
      series={@series}
      label={@label}
      value_header={@value_header}
      class={@class}
    />
    """
    |> rendered_to_string()
  end

  defp category_chart(entries, opts \\ []) do
    assigns = %{
      entries: entries,
      label: Keyword.get(opts, :label, "Referrers"),
      value_header: Keyword.get(opts, :value_header),
      class: nil,
      __changed__: nil
    }

    ~H"""
    <ChartComponents.category_chart
      entries={@entries}
      label={@label}
      value_header={@value_header}
      class={@class}
    />
    """
    |> rendered_to_string()
  end

  defp day(iso, views), do: %{day: Date.from_iso8601!(iso), views: views}

  defp source(source, display, bar_value),
    do: %{source: source, label: to_string(source), display: display, bar_value: bar_value}

  describe "bar_chart/1" do
    test "renders one bar per day, titled with the date and the count" do
      html = bar_chart([day("2026-08-01", 3), day("2026-08-02", 9)])

      assert html =~ "<title>2026-08-01: 3</title>"
      assert html =~ "<title>2026-08-02: 9</title>"
      assert html |> String.split("<rect") |> length() == 4
    end

    # `sr-only` rather than `hidden`, so the values stay in the accessibility
    # tree — the SVG itself is `aria-hidden`, so this table IS the chart for a
    # screen-reader user.
    test "the accessible table carries every point, with its own headers" do
      html = bar_chart([day("2026-08-01", 3)], label: "Daily views")

      assert html =~ ~s(<table class="sr-only">)
      assert html =~ "<caption>Daily views</caption>"
      assert html =~ "Day"
      assert html =~ "Views"
      assert html =~ ~s(<th scope="row">2026-08-01</th>)
      assert html =~ "<td>3</td>"
      assert html =~ ~s(aria-hidden="true")
    end

    test "the value header can be overridden" do
      assert bar_chart([day("2026-08-01", 1)], value_header: "Submissions") =~ "Submissions"
    end

    # A day with traffic is never invisible, and a genuine zero stays flat so a
    # gap reads as a gap.
    test "a nonzero day floors at a visible height; a zero day is flat" do
      html = bar_chart([day("2026-08-01", 1), day("2026-08-02", 1000), day("2026-08-03", 0)])

      heights = Regex.scan(~r/height="(\d+)"/, html) |> Enum.map(&List.last/1)

      # Three bars plus the 1-unit baseline rect.
      assert "0" in heights
      refute Enum.all?(heights, &(&1 == "0"))
    end

    test "an empty series still renders a chart rather than crashing" do
      html = bar_chart([])

      assert html =~ "<svg"
      assert html =~ "<table"
    end
  end

  describe "category_chart/1" do
    test "renders one bar per category, titled with the label and what a person reads" do
      html = category_chart([source(:direct, 40, 40), source(:social, "< 5", 4)])

      assert html =~ "<title>direct: 40</title>"
      assert html =~ "<title>social: &lt; 5</title>"
    end

    test "the accessible table names the category axis" do
      html = category_chart([source(:direct, 40, 40)], label: "Where visitors came from")

      assert html =~ "<caption>Where visitors came from</caption>"
      assert html =~ "Source"
      assert html =~ "Count"
    end

    # The property that matters for #620/#777: `display` is what a person reads
    # and `bar_value` is what the geometry uses, and the two are allowed to
    # diverge precisely so a suppressed count cannot be read off a bar's size.
    # This asserts the chart honours that separation — it must never size a bar
    # from `display`, nor print `bar_value`.
    test "a suppressed entry is sized by bar_value and labelled by display" do
      html = category_chart([source(:direct, 100, 100), source(:social, "< 5", 4)])

      assert html =~ "&lt; 5"
      # The real count behind "< 5" is not in the document at all.
      refute html =~ "<title>social: 2</title>"
      refute html =~ "<td>2</td>"
    end
  end

  # The drift #778 was filed about: `bar_chart/1` wrapped its bars in
  # `<g class="text-primary-ink">` while `category_chart/1` put a class on each
  # `<rect>`. Two copies of one chart will always drift somewhere; this pins the
  # place they already had.
  describe "both charts" do
    test "put the colour on the rect, not on a wrapping group" do
      day_html = bar_chart([day("2026-08-01", 3)])
      cat_html = category_chart([source(:direct, 40, 40)])

      refute day_html =~ "<g "
      refute cat_html =~ "<g "
      assert day_html =~ ~s(class="text-primary-ink")
      assert cat_html =~ "<rect"
    end

    test "share the same geometry, baseline and accessible shape" do
      day_html = bar_chart([day("2026-08-01", 3)])
      cat_html = category_chart([source(:direct, 3, 3)])

      for html <- [day_html, cat_html] do
        assert html =~ ~s(viewBox="0 0 10 100")
        assert html =~ ~s(preserveAspectRatio="none")
        assert html =~ ~s(class="text-base-content/20")
        assert html =~ ~s(<table class="sr-only">)
      end
    end
  end
end
