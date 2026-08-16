defmodule KilnCMS.CMS.HealthSummary do
  @moduledoc """
  "Is the library rotting?" — one org's content freshness, counted
  (`docs/content-lifecycles.md`).

  `KilnCMS.CMS.HealthSweep` answers the same question for a *scheduler*, and
  deliberately only about the two states worth waking someone for. This answers
  it for a *person* looking at the governance dashboard, so it also counts what
  is merely approaching a deadline — that is the half an editor can act on
  cheaply, before anything is late.

  ## Only the unhealthy rows are read

  The query filters on `health in [:due_soon, :due, :overdue, :expired]`, which
  is an expression calculation and therefore a `WHERE` in Postgres. So a site
  with forty thousand fresh pages reads none of them: the result set is the
  problem list, not the library. That is what makes this cheap enough to compute
  on a page load rather than storing counts that would immediately be wrong.

  ## "Nothing overdue" and "nothing has a cadence" are opposite facts

  A dashboard that renders `0 overdue` for a site that has never set a review
  cadence is stating something false in a reassuring voice. So `in_use?` is
  resolved separately — one bounded existence probe per type — and the panel
  says which of the two it is looking at. Same argument the claims panel makes
  for rendering "off" rather than skipping itself.
  """
  import Ash.Expr

  require Logger

  alias KilnCMS.CMS.ContentTypes

  # Everything that is not `:fresh`, worst first — the order the dashboard
  # lists them in, and the order that makes `worst/1` a plain `Enum.take`.
  @unhealthy [:expired, :overdue, :due, :due_soon]

  # Per type, per call. Well past what a dashboard can usefully show, and the
  # count is reported as "at least" when it is hit rather than quietly
  # understating the problem.
  @per_type_limit 500

  @typedoc """
  `counts` covers every unhealthy state (zeroes included, so a template can
  render the row without deciding what a missing key means). `worst` is the
  most urgent handful across all types.
  """
  @type t :: %{
          in_use?: boolean(),
          truncated?: boolean(),
          counts: %{atom() => non_neg_integer()},
          worst: [
            %{
              type: atom() | String.t(),
              label: String.t(),
              id: Ash.UUID.t(),
              title: String.t(),
              health: atom(),
              due_at: DateTime.t() | nil
            }
          ]
        }

  @doc "Every unhealthy state Kiln reports, worst first."
  @spec unhealthy() :: [atom()]
  def unhealthy, do: @unhealthy

  @doc """
  Summarize one org's content health.

  `worst` is capped at `limit` (default 10) — a dashboard section is a prompt to
  act, not a work queue; the queue is `/editor?health=overdue`.
  """
  @spec for_org(Ash.UUID.t(), pos_integer()) :: t()
  def for_org(org_id, limit \\ 10) do
    types = ContentTypes.all_for_org(org_id)
    rows = Enum.flat_map(types, &unhealthy_rows(&1, org_id))

    %{
      in_use?: Enum.any?(types, &cadenced?(&1, org_id)),
      truncated?: Enum.any?(types, &(row_count(rows, &1) >= @per_type_limit)),
      counts:
        Map.new(@unhealthy, fn health -> {health, Enum.count(rows, &(&1.health == health))} end),
      worst: rows |> Enum.sort_by(&sort_key/1) |> Enum.take(limit)
    }
  end

  @doc """
  The unhealthy rows as CSV lines, for the dashboard's export.

  Unbounded by `limit` — the export exists precisely because the panel shows ten
  and a compliance officer wants all of them. Still bounded per type by
  `@per_type_limit`, which the panel's own "at least" wording covers.
  """
  @spec csv_rows(Ash.UUID.t()) :: [[String.t() | nil]]
  def csv_rows(org_id) do
    org_id
    |> ContentTypes.all_for_org()
    |> Enum.flat_map(&unhealthy_rows(&1, org_id))
    |> Enum.sort_by(&sort_key/1)
    |> Enum.map(fn row ->
      [
        to_string(row.type),
        row.title,
        to_string(row.health),
        row.due_at && DateTime.to_iso8601(row.due_at),
        row.id
      ]
    end)
  end

  # Worst state first, then soonest-due within it. A `nil` `due_at` (an expiry,
  # which has no review deadline) sorts before dated rows in the same state
  # rather than to the end — it is already the more urgent kind.
  defp sort_key(row) do
    {Enum.find_index(@unhealthy, &(&1 == row.health)), row.due_at || ~U[1970-01-01 00:00:00Z]}
  end

  defp row_count(rows, ct), do: Enum.count(rows, &(&1.type == ct.type))

  defp unhealthy_rows(ct, org_id) do
    ct
    |> ContentTypes.list!(
      authorize?: false,
      tenant: org_id,
      query: [
        filter: expr(health in ^@unhealthy),
        select: [:id, :title],
        load: [:health, :due_at],
        limit: @per_type_limit
      ]
    )
    |> Enum.map(fn record ->
      %{
        type: ct.type,
        label: ct.label,
        id: record.id,
        title: record.title,
        health: record.health,
        due_at: record.due_at
      }
    end)
  rescue
    error ->
      # One misbehaving type must not blank the whole panel.
      Logger.warning("Health summary failed for #{inspect(ct.type)}: #{inspect(error)}")
      []
  end

  # Does anything published on this type carry a lifecycle at all? An existence
  # probe, not a count — the panel only needs to know which sentence to write.
  defp cadenced?(ct, org_id) do
    ct
    |> ContentTypes.list!(
      authorize?: false,
      tenant: org_id,
      query: [
        filter:
          expr(
            state == :published and
              (not is_nil(effective_review_after_days) or not is_nil(unpublish_at))
          ),
        select: [:id],
        limit: 1
      ]
    )
    |> Enum.any?()
  rescue
    error ->
      Logger.warning("Health cadence probe failed for #{inspect(ct.type)}: #{inspect(error)}")
      false
  end
end
