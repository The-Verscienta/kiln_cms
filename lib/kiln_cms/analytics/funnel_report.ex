defmodule KilnCMS.Analytics.FunnelReport do
  @moduledoc """
  A funnel's steps in order, each with its view count within a window and a
  **labelled population ratio** against the previous step (#622, phase 5 of
  `docs/advanced-analytics-plan.md`) — the report half of #621's definitions.

  Derived, not stored: a funnel step is a content item, and every view of it
  is already bucketed by `KilnCMS.Analytics.ContentViewDay`. This queries
  only the buckets for the funnel's own step content — a small, targeted
  `content_type == ^type and content_id in ^ids` read per distinct step type
  (one funnel has a handful of steps), not a scan of the org's whole window
  like the dashboard's own cross-content aggregate.

  **Not a cohort conversion rate.** Steps are counted independently — there
  is no stored notion of "the same visitor reached step 2 then step 3". A
  later step's count includes traffic that arrived directly and never saw an
  earlier step, so the ratio is a *population statistic* and can exceed
  100%. Every caller rendering `ratio` must say so; see the design doc,
  "The ratio must be labelled, not presented as GA conversion".

  A step whose content has since been deleted still gets a report row — its
  count is whatever the window's buckets say (buckets outlive the content
  they described, same as everywhere else in this domain) and its title
  falls back to `"(deleted)"` via `KilnCMS.Analytics.Titles`, exactly like
  `AnalyticsLive`'s own title lookup.
  """

  require Ash.Query

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.Analytics.Titles

  @doc """
  A funnel's steps, oldest-position-first, each as `%{step:, title:, count:,
  display:, ratio:}`:

    * `count` — the exact view total within `[from, to]`, never shown to a user.
    * `display` — `count`, low-count-suppressed the same way #620 suppresses
      referrer hits (`Analytics.suppress_low_count/1`).
    * `ratio` — `round(count / previous_count * 100, 1)` as a percent, or
      `nil` for the first step, when the previous step had zero views (no
      denominator), or when **either** step's count is suppressed — a ratio
      computed from a suppressed count would let a reader back-calculate an
      approximate exact value from the other, defeating the suppression.
  """
  @spec report(map(), Date.t(), Date.t(), term(), term()) :: [map()]
  def report(funnel, from, to, org, actor) do
    steps = Analytics.funnel_steps_for!(funnel.id, actor: actor, tenant: org)
    counts = step_counts(steps, from, to, org, actor)
    titles = Titles.resolve(steps, org, actor)

    steps
    |> Enum.map(&build_row(&1, counts, titles, org))
    |> with_ratios()
  end

  defp step_counts([], _from, _to, _org, _actor), do: %{}

  defp step_counts(steps, from, to, org, actor) do
    steps
    |> Enum.group_by(& &1.content_type, & &1.content_id)
    |> Enum.reduce(%{}, fn {type, ids}, acc ->
      ContentViewDay
      |> Ash.Query.for_read(:in_range, %{from: from, to: to})
      |> Ash.Query.filter(content_type == ^type and content_id in ^ids)
      |> Ash.read!(actor: actor, tenant: org)
      |> Enum.reduce(acc, fn row, acc ->
        Map.update(acc, {row.content_type, row.content_id}, row.views, &(&1 + row.views))
      end)
    end)
  end

  defp build_row(step, counts, titles, org) do
    count = Map.get(counts, {step.content_type, step.content_id}, 0)

    %{
      step: step,
      title: Titles.title_for(step, titles, org),
      count: count,
      display: Analytics.suppress_low_count(count)
    }
  end

  defp with_ratios(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> Map.put(row, :ratio, ratio_at(rows, index)) end)
  end

  defp ratio_at(_rows, 0), do: nil

  defp ratio_at(rows, index) do
    prev = Enum.at(rows, index - 1)
    row = Enum.at(rows, index)

    cond do
      is_binary(prev.display) or is_binary(row.display) -> nil
      prev.count == 0 -> nil
      true -> Float.round(row.count / prev.count * 100, 1)
    end
  end
end
