defmodule KilnCMS.Experiments.Results do
  @moduledoc """
  What an experiment's counters say, and — more importantly — what they do
  **not** say yet (#982).

  `VariantDay` holds two integers per variant per day. This folds them into a
  per-variant total, a plain proportion, and one decision: whether the panel
  may point at a leader at all. It may not until **every** variant has at least
  `floor/0` impressions. Below that the numbers are shown but no arm is called
  — a rate over a handful of impressions is not a small number, it is a
  number that cannot be produced, and a panel that bolds one anyway invites a
  decision the data cannot support (the same reason `mix kiln.experiment show`
  prints the ratio and no confidence claim).

  Deliberately **no sequential testing and no peeking correction** — see
  `docs/content-experiments-plan.md`. The floor is a sample-size floor, not a
  significance test: above it, "leader" means "the highest rate so far", said
  plainly, and the editor decides. Setting the floor is `config :kiln_cms,
  KilnCMS.Experiments, results_floor: N` (default 100 impressions per variant).

  Blocked and anomalous states are the caller's to phrase
  (`KilnCMS.Experiments.blocked_reason/1`, `anomaly_reason/2`); this module
  reports them alongside so a panel cannot render a rate without them.
  """

  alias KilnCMS.Experiments

  @default_floor 100

  @typedoc "One variant's totals."
  @type row :: %{
          variant: KilnCMS.Experiments.Variant.t(),
          impressions: non_neg_integer(),
          conversions: non_neg_integer(),
          rate: float() | nil,
          anomaly: KilnCMS.Experiments.Health.reason() | nil
        }

  @typedoc """
  The summary a results panel renders from. `leader` is `nil` until every
  variant is at or over the floor and one has strictly the highest rate;
  `blocked` is the experiment's `blocked_reason/1`, which the panel must show
  ABOVE any rate.
  """
  @type summary :: %{
          rows: [row()],
          floor: pos_integer(),
          decidable?: boolean(),
          leader: KilnCMS.Experiments.Variant.t() | nil,
          blocked: KilnCMS.Experiments.Health.reason() | nil,
          total_impressions: non_neg_integer(),
          total_conversions: non_neg_integer()
        }

  @doc "Impressions every variant needs before the panel may point at a leader."
  @spec floor() :: pos_integer()
  def floor do
    case Keyword.get(Application.get_env(:kiln_cms, KilnCMS.Experiments, []), :results_floor) do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_floor
    end
  end

  @doc """
  Summarize `experiment` (variants loaded) from its stored counters, read as
  the system under `org_id`.
  """
  @spec summarize(KilnCMS.Experiments.Experiment.t(), Ash.UUID.t()) :: summary()
  def summarize(experiment, org_id) do
    variants = experiment.variants |> List.wrap() |> Enum.reject(&match?(%Ash.NotLoaded{}, &1))
    days = days_for(Enum.map(variants, & &1.id), org_id)

    rows =
      variants
      |> Enum.sort_by(&{!&1.control, &1.name})
      |> Enum.map(fn variant ->
        {impressions, conversions} = Map.get(days, variant.id, {0, 0})

        %{
          variant: variant,
          impressions: impressions,
          conversions: conversions,
          rate: rate(impressions, conversions),
          anomaly: Experiments.anomaly_reason(impressions, conversions)
        }
      end)

    floor = floor()
    decidable? = rows != [] and Enum.all?(rows, &(&1.impressions >= floor))

    %{
      rows: rows,
      floor: floor,
      decidable?: decidable?,
      leader: if(decidable?, do: leader(rows), else: nil),
      blocked: Experiments.blocked_reason(experiment),
      total_impressions: rows |> Enum.map(& &1.impressions) |> Enum.sum(),
      total_conversions: rows |> Enum.map(& &1.conversions) |> Enum.sum()
    }
  end

  @doc "The proportion as a float in `0..1`, or `nil` with no impressions."
  @spec rate(non_neg_integer(), non_neg_integer()) :: float() | nil
  def rate(0, _conversions), do: nil
  def rate(impressions, conversions), do: conversions / impressions

  # Strictly the highest rate; a tie is no leader, and an arm with an anomaly
  # (`conversions > impressions`) never leads — its rate is not a rate.
  defp leader(rows) do
    candidates = Enum.reject(rows, &(is_nil(&1.rate) or not is_nil(&1.anomaly)))

    case Enum.sort_by(candidates, & &1.rate, :desc) do
      [best, second | _] when best.rate == second.rate -> nil
      [best | _] -> best.variant
      [] -> nil
    end
  end

  # One read for the whole experiment: `%{variant_id => {impressions, conversions}}`.
  # `VariantDay` has no `belongs_to :variant` (see its moduledoc), so by ids.
  defp days_for([], _org_id), do: %{}

  defp days_for(variant_ids, org_id) do
    require Ash.Query

    KilnCMS.Experiments.VariantDay
    |> Ash.Query.filter(variant_id in ^variant_ids)
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> Enum.reduce(%{}, fn day, acc ->
      Map.update(acc, day.variant_id, {day.impressions, day.conversions}, fn {i, c} ->
        {i + day.impressions, c + day.conversions}
      end)
    end)
  end
end
