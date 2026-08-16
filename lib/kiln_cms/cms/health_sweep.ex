defmodule KilnCMS.CMS.HealthSweep do
  @moduledoc """
  The daily freshness sweep (`docs/content-lifecycles.md`): finds published
  content whose `health` has gone `:overdue` or `:expired`, reports the counts
  as telemetry, and dispatches an automation event per record so a team can turn
  staleness into assigned work.

  ## Why a sweep exists at all

  Every other editorial trigger hangs off a write: something was published,
  returned to draft, assigned. Freshness lapses because **time passed** — nobody
  did anything, which is exactly the problem — so there is no write to hang it
  off. Something has to come looking.

  ## It changes nothing

  The sweep is a read plus an event. It does not write to the content, does not
  create tasks, and does not touch `health` (which is a calculation and has
  nothing to store). What happens next is an `Automation` rule the team
  configured, or nothing at all — which is the point: "overdue" means different
  things to a newsroom and to a clinical library, and the one hard-coded
  reaction would be wrong for one of them.

  That also makes it safe to leave enabled everywhere. A site with no review
  cadences matches nothing: `health` is `:fresh` for every row without a
  `review_after_days`, and the filter runs in Postgres.

  ## Daily, and idempotent by repetition

  It re-fires every day a record stays overdue, which is what makes it a
  reminder rather than a one-shot notification that can be missed. The cost of
  that is pushed onto the reaction: `:create_task` is idempotent per
  {content, kind} precisely because this repeats. A reaction that is not
  idempotent will be noisy, and that is a property of the reaction, not of the
  sweep.

  ## Telemetry

  `[:kiln_cms, :lifecycle, :health_sweep]` per org, measuring `overdue` and
  `expired` counts. A dashboard that wants "is the library rotting?" reads this
  rather than re-running the query.
  """
  import Ash.Expr

  require Logger

  alias KilnCMS.CMS.ContentTypes

  # The health values worth telling anyone about. `:due` and `:due_soon` are
  # deliberately absent: a sweep that fired on "falls due next week" would send
  # a reminder every day for a week before the deadline, which is how a team
  # learns to filter the reminders out.
  @actionable [:overdue, :expired]

  # Per type, per org, per run. A ceiling rather than a page: this is a
  # reminder mechanism, and a site with more than this many overdue records has
  # a problem that a longer job queue will not fix. Logged when hit, so the
  # truncation is visible rather than silently shaping the numbers.
  @per_type_limit 500

  @doc "Sweep every org."
  @spec run() :: :ok
  def run do
    KilnCMS.Accounts.ListOrgIds.list_tenants([])
    |> Enum.each(&run_org/1)
  end

  @doc """
  Sweep one org: emit telemetry with the counts, and dispatch one automation
  event per actionable record.
  """
  @spec run_org(Ash.UUID.t()) :: :ok
  def run_org(org_id) do
    # `{type, record}` pairs: the type is the registry's, not something the
    # record carries, and stuffing it onto the struct with `Map.put/3` would
    # leave a key Ash never declared on a value that still looks like a Page.
    records =
      org_id
      |> ContentTypes.all_for_org()
      |> Enum.flat_map(&stale_records(&1, org_id))

    counts =
      Enum.reduce(@actionable, %{}, fn health, acc ->
        Map.put(acc, health, Enum.count(records, fn {_type, r} -> r.health == health end))
      end)

    :telemetry.execute([:kiln_cms, :lifecycle, :health_sweep], counts, %{org_id: org_id})

    Enum.each(records, fn {type, record} -> dispatch(type, record, org_id) end)
  end

  # One query per type. `health` is an expression calculation, so this is a
  # `WHERE` in Postgres rather than a full read filtered in Elixir — which is
  # the whole reason it was built as an expression.
  #
  # `authorize?: false` is correct here and only here: a scheduled sweep has no
  # actor, and the alternative (an actorless authorized read) would silently see
  # only published-and-public content, which is most but not all of what has a
  # cadence. Nothing leaves this module except an automation event carrying the
  # same payload a webhook would.
  defp stale_records(ct, org_id) do
    ct
    |> ContentTypes.list!(
      authorize?: false,
      tenant: org_id,
      query: [
        filter: expr(health in ^@actionable),
        select: [:id, :title, :slug, :state, :author_id],
        load: [:health],
        limit: @per_type_limit
      ]
    )
    |> tap(&log_if_truncated(&1, ct, org_id))
    |> Enum.map(&{ct.type, &1})
  rescue
    error ->
      # One misbehaving type must not stop the sweep for the rest.
      Logger.warning("Health sweep failed for #{inspect(ct.type)}: #{inspect(error)}")
      []
  end

  defp log_if_truncated(records, ct, org_id) when length(records) >= @per_type_limit do
    Logger.warning(
      "Health sweep hit its #{@per_type_limit} cap for #{inspect(ct.type)} in org #{org_id} — " <>
        "some overdue records were not dispatched this run."
    )
  end

  defp log_if_truncated(_records, _ct, _org_id), do: :ok

  # `"<type>.health_overdue"` / `"<type>.health_expired"` through the same funnel
  # every other editorial event uses, so a rule scoped to a content type matches
  # these exactly as it matches `published`.
  defp dispatch(type, record, org_id) do
    KilnCMS.Automation.handle_event(
      "#{type}.health_#{record.health}",
      %{
        "id" => record.id,
        "title" => record.title,
        "slug" => record.slug,
        "author_id" => record.author_id,
        "health" => to_string(record.health)
      },
      org_id
    )
  end
end
