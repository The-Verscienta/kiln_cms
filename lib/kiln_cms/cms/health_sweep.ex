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
  things to a newsroom and to a documentation library, and the one hard-coded
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

  # Rows per read. A page, not a ceiling (#2738): the sweep walks every
  # actionable record, `@batch` at a time, so memory stays bounded however
  # large the backlog is. It used to stop at 500 per type with no sort, and
  # since dispatching does not change `health` (a `:create_task` reaction is
  # idempotent but leaves the record overdue), every daily run got the same 500
  # back and the rest never got an event.
  @batch 500

  @doc "Sweep every org."
  @spec run() :: :ok
  def run do
    KilnCMS.Accounts.ListOrgIds.list_tenants([])
    |> Enum.each(&run_org/1)
  end

  @doc """
  Sweep one org: dispatch one automation event per actionable record, then
  emit telemetry with the counts.

  `:batch` sizes each read (tests).
  """
  @spec run_org(Ash.UUID.t(), keyword()) :: :ok
  def run_org(org_id, opts \\ []) do
    batch = Keyword.get(opts, :batch, @batch)
    zero = Map.new(@actionable, &{&1, 0})

    counts =
      org_id
      |> ContentTypes.all_for_org()
      |> Enum.reduce(zero, fn ct, acc ->
        Map.merge(acc, sweep_type(ct, org_id, batch), fn _health, a, b -> a + b end)
      end)

    :telemetry.execute([:kiln_cms, :lifecycle, :health_sweep], counts, %{org_id: org_id})
  end

  # Dispatches page by page, so no more than one page of records is held at a
  # time, and returns this type's counts by health. The type comes from the
  # registry, not the record: stuffing it onto the struct with `Map.put/3`
  # would leave a key Ash never declared on a value that still looks like a
  # Page.
  defp sweep_type(ct, org_id, batch) do
    ct
    |> pages(org_id, batch)
    |> Enum.reduce(%{}, fn record, acc ->
      dispatch(ct.type, record, org_id)
      Map.update(acc, record.health, 1, &(&1 + 1))
    end)
  rescue
    error ->
      # One misbehaving type must not stop the sweep for the rest. What it
      # dispatched before failing goes uncounted; tomorrow's run sends it again.
      Logger.warning("Health sweep failed for #{inspect(ct.type)}: #{inspect(error)}")
      %{}
  end

  # An `id > cursor` keyset, the way `KilnCMS.CMS.Computed.DailyRefresh`
  # pages. Not most-overdue-first: nothing the sweep does takes a record out of
  # the filter, so a sort alone would return the same first page every run,
  # which is the starvation this replaced.
  defp pages(ct, org_id, batch) do
    Stream.unfold(:start, fn
      :done ->
        nil

      cursor ->
        case page(ct, org_id, cursor, batch) do
          [] -> nil
          records when length(records) < batch -> {records, :done}
          records -> {records, List.last(records).id}
        end
    end)
    |> Stream.flat_map(& &1)
  end

  # `health` is an expression calculation, so this is a `WHERE` in Postgres
  # rather than a full read filtered in Elixir — which is the whole reason it
  # was built as an expression.
  defp page(ct, org_id, cursor, batch) do
    filter =
      case cursor do
        :start -> expr(health in ^@actionable)
        last_id -> expr(health in ^@actionable and id > ^last_id)
      end

    # authorize?: false — a scheduled sweep has no actor, and the alternative
    # (an actorless authorized read) would silently see only
    # published-and-public content, which is most but not all of what has a
    # cadence. Nothing leaves this module except an automation event carrying
    # the same payload a webhook would.
    ContentTypes.list!(ct,
      authorize?: false,
      tenant: org_id,
      query: [
        filter: filter,
        select: [:id, :title, :slug, :state, :author_id],
        load: [:health],
        sort: [id: :asc],
        limit: batch
      ]
    )
  end

  # `"<type>.health_overdue"` / `"<type>.health_expired"` through the same funnel
  # every other editorial event uses, so a rule scoped to a content type matches
  # these exactly as it matches `published`.
  defp dispatch(type, record, org_id) do
    KilnCMS.Automation.handle_event(
      "#{type}.health_#{record.health}",
      event_payload(record, record.health),
      org_id
    )
  end

  @doc """
  The payload a `<type>.health_<health>` event carries for `record`.

  Public so the automation builder's preview tries a rule on exactly what the
  sweep would send — this is narrower than an editorial event's serialized
  document, and it is the only one with `author_id`, which `:create_task`
  assigns from.
  """
  @spec event_payload(struct(), atom() | String.t()) :: map()
  def event_payload(record, health) do
    %{
      "id" => record.id,
      "title" => record.title,
      "slug" => record.slug,
      "author_id" => record.author_id,
      "health" => to_string(health)
    }
  end
end
