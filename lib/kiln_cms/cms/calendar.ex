defmodule KilnCMS.CMS.Calendar do
  @moduledoc """
  The editorial calendar's projection: everything time-bound in one org, in
  one window, as a flat list of events.

  ## Why a projection and not a table

  Nothing here is stored. Every event is derived from a column that already
  exists — `scheduled_at`, `unpublish_at`, `published_at`, a task's `due_on`, a
  release's `scheduled_at`, and the `due_at` calculation — so the calendar
  cannot disagree with the records it draws. A materialized calendar table
  would need a write path on every one of those columns and would be wrong
  between the write and the sweep; this is wrong never, at the cost of one
  bounded query per content type per window.

  That cost is the reason the window is bounded rather than paginated: the
  caller asks for a month (or a week), each type contributes at most
  `per_type_limit/0` rows, and the whole thing is sorted in Elixir. An editorial
  month is tens of events, not thousands.

  ## The lanes

  Each event carries a `:kind`, which is what the UI colours and filters by:

    * `:publish` — a draft/in-review record with a `scheduled_at` in the window.
    * `:unpublish` / `:archive` / `:expire` — a published record whose embargo
      end falls in the window, split by its `expiry_action` so the calendar says
      what will actually happen rather than "unpublish" three times. `:expire`
      is the `:flag` action: nothing happens to the row, but its `health` goes
      `:expired`, which is a thing an editor plans around.
    * `:published` — when a record actually went live. The past half of the
      calendar; "what went out that week" is the other question it gets asked.
    * `:review_due` — a published record's `due_at`. Its own lane rather than a
      badge on a publish chip, because a re-read is separate work from a
      release.
    * `:task_due` — an open `Task`'s due date (#501).
    * `:release_scheduled` / `:release_published` / `:release_failed` — a
      `ContentRelease`'s go-live, its actual ship, and a go-live that aborted.

  ## Scoping and authorization

  Every read runs as the passed actor under the org's tenant, so the calendar
  can only ever show what that editor could already read one record at a time —
  including the passphrase-lock exclusion, which `Content`'s read policy applies
  to every actorless read and therefore to this one. There is no `authorize?:
  false` anywhere in this module and there must not be: a projection that
  widened a read would be a way to enumerate draft titles through a grid.
  """

  import Ash.Expr

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  @typedoc """
  One thing happening at one moment.

  `health` and `state` are `nil` for the non-content lanes (tasks, releases) —
  they have no freshness axis, and a filter on health simply excludes them.
  """
  @type event :: %{
          id: Ash.UUID.t(),
          type: atom() | String.t(),
          label: String.t(),
          title: String.t(),
          kind: kind(),
          at: DateTime.t(),
          state: atom() | nil,
          health: atom() | nil
        }

  @type kind ::
          :publish
          | :unpublish
          | :archive
          | :expire
          | :published
          | :review_due
          | :task_due
          | :release_scheduled
          | :release_published
          | :release_failed

  @typedoc """
  Filters, all optional and all "nil means everything".

  A list that is present but empty means *nothing*, not everything — an editor
  who unticks every type is asking for an empty calendar, and answering that
  with a full one is the kind of helpfulness that reads as a bug.
  """
  @type filters :: %{
          optional(:types) => [atom() | String.t()] | nil,
          optional(:kinds) => [kind()] | nil,
          optional(:health) => [atom()] | nil
        }

  # Per-type cap for one window — far above any real editorial volume, but it
  # keeps a pathological month bounded rather than letting one type's backlog
  # decide how long the page takes to render.
  @per_type_limit 300

  @doc "The per-content-type row cap applied to each window query."
  @spec per_type_limit() :: pos_integer()
  def per_type_limit, do: @per_type_limit

  @doc "Every kind the projection can emit, in legend order."
  @spec kinds() :: [kind()]
  def kinds,
    do: [
      :publish,
      :published,
      :unpublish,
      :archive,
      :expire,
      :review_due,
      :task_due,
      :release_scheduled,
      :release_published,
      :release_failed
    ]

  @doc """
  The window's events, sorted by time.

  `from` is inclusive, `to` exclusive. Both must be UTC; the caller owns the
  timezone question (today: the console renders UTC, as the rest of the editor
  does).
  """
  @spec events(term(), struct(), DateTime.t(), DateTime.t(), filters()) :: [event()]
  def events(actor, org, from, to, filters \\ %{}) do
    content =
      org
      |> ContentTypes.all_for_org()
      |> Enum.filter(&type_included?(&1, filters))
      |> Enum.flat_map(&content_events(&1, actor, org, from, to))

    (content ++
       task_events(actor, org, from, to) ++
       release_events(actor, org, from, to))
    |> Enum.filter(&(kind_included?(&1, filters) and health_included?(&1, filters)))
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @doc """
  The window's events grouped by calendar day — the shape the month grid wants.

  Same events, same filters; `Enum.group_by/2` on the date, so a day with
  nothing in it is simply absent from the map.
  """
  @spec events_by_day(term(), struct(), DateTime.t(), DateTime.t(), filters()) ::
          %{Date.t() => [event()]}
  def events_by_day(actor, org, from, to, filters \\ %{}) do
    actor
    |> events(org, from, to, filters)
    |> Enum.group_by(&DateTime.to_date(&1.at))
  end

  # --- content ---------------------------------------------------------------

  # One query per type, covering all four content lanes, then fanned out in
  # Elixir. Four separate queries would each pay the same tenant + policy
  # filter for a slice of the same rows — and a record scheduled to publish on
  # Tuesday and expire on Friday is one row either way.
  defp content_events(ct, actor, org, from, to) do
    ct
    |> ContentTypes.list!(
      actor: actor,
      tenant: org,
      query: [
        filter:
          expr(
            (scheduled_at >= ^from and scheduled_at < ^to) or
              (unpublish_at >= ^from and unpublish_at < ^to) or
              (published_at >= ^from and published_at < ^to) or
              (due_at >= ^from and due_at < ^to)
          ),
        select: [
          :id,
          :title,
          :state,
          :scheduled_at,
          :unpublish_at,
          :published_at,
          :expiry_action
        ],
        # `due_at` and `health` are expression calculations, so both the filter
        # above and these run in Postgres. Loading them widens the select with
        # the columns they read (`last_reviewed_at`, `review_after_days`) —
        # `ensure_selected` runs after preparations, so the pinned list above is
        # a floor, not a ceiling.
        load: [:due_at, :health],
        limit: @per_type_limit
      ]
    )
    |> Enum.flat_map(&record_events(ct, &1, from, to))
  end

  # A record's events: each date field that falls in the window, while the
  # record is in a state where that date still means anything. A scheduled
  # publish on an already-published record is history, not a plan.
  defp record_events(ct, record, from, to) do
    for {kind, at, states} <- [
          {:publish, record.scheduled_at, [:draft, :in_review]},
          {expiry_kind(record.expiry_action), record.unpublish_at, [:published]},
          {:published, record.published_at, [:published]},
          {:review_due, record.due_at, [:published]}
        ],
        record.state in states,
        in_window?(at, from, to) do
      %{
        id: record.id,
        type: ct.type,
        label: ct.label,
        title: record.title,
        kind: kind,
        at: at,
        state: record.state,
        health: record.health
      }
    end
  end

  defp expiry_kind(:archive), do: :archive
  defp expiry_kind(:flag), do: :expire
  defp expiry_kind(_unpublish), do: :unpublish

  # --- tasks -----------------------------------------------------------------

  # Task due dates (#501). Every editor already has read access to every org
  # task (same policy as comments), so this isn't per-actor filtered beyond
  # that. Content titles are resolved live (see `TaskLive`'s moduledoc for why)
  # rather than denormalized onto the task.
  defp task_events(actor, org, from, to) do
    # `due_on` is a date and `open_due_between` takes an inclusive pair, while
    # this module's window is a half-open datetime interval — so the last day
    # asked for is the one containing the instant just before `to`.
    last_day = to |> DateTime.add(-1, :second) |> DateTime.to_date()

    CMS.list_tasks_open_due_between!(DateTime.to_date(from), last_day,
      actor: actor,
      tenant: org
    )
    |> Enum.map(fn task ->
      title =
        case ContentTypes.get_record(task.content_type, task.content_id,
               actor: actor,
               tenant: org,
               query: [select: [:id, :title]]
             ) do
          {:ok, record} -> record.title
          _ -> task.content_type
        end

      %{
        id: task.content_id,
        type: task.content_type,
        label: task.content_type,
        title: title,
        kind: :task_due,
        at: DateTime.new!(task.due_on, ~T[00:00:00], "Etc/UTC"),
        state: nil,
        health: nil
      }
    end)
  end

  # --- releases --------------------------------------------------------------

  # A bundle's go-live is the coordinated date an editorial team plans around,
  # so it belongs on the same grid as the per-item schedules it replaces. Both
  # axes are shown — the future go-live and the moment a release actually
  # shipped.
  defp release_events(actor, org, from, to) do
    CMS.list_releases_in_window!(from, to, actor: actor, tenant: org)
    |> Enum.flat_map(fn release ->
      for {kind, at} <- [
            {:release_scheduled, release_go_live(release)},
            {:release_failed, release_abort(release)},
            {:release_published, release.published_at}
          ],
          in_window?(at, from, to) do
        %{
          id: release.id,
          type: :release,
          # Untranslated on purpose, exactly like a content type's `ct.label`:
          # these are registry labels, and the view is what speaks the user's
          # language. A domain module reaching into `KilnCMSWeb.Gettext` would
          # be the layering violation, not the missing translation.
          label: "Release",
          title: release.name,
          kind: kind,
          at: at,
          state: release.state,
          health: nil
        }
      end
    end)
  end

  # Only a release still waiting to fire has a meaningful go-live chip; once it
  # has published, its `scheduled_at` is history that would double up with the
  # published chip on the same day.
  defp release_go_live(%{state: :scheduled, scheduled_at: at}), do: at
  defp release_go_live(_release), do: nil

  # A failed release keeps the `scheduled_at` it was supposed to fire at, so its
  # chip stays on the day the launch was planned for rather than on the day
  # somebody eventually noticed. Its own kind, not `:release_scheduled`: that
  # lane is draggable, and there is no `:schedule` transition out of `:failed`
  # to drag it with — reopening is the first step.
  defp release_abort(%{state: :failed, scheduled_at: at}), do: at
  defp release_abort(_release), do: nil

  # --- filters ---------------------------------------------------------------

  defp type_included?(_ct, %{types: nil}), do: true

  defp type_included?(ct, %{types: types}),
    do: to_string(ct.type) in Enum.map(types, &to_string/1)

  defp type_included?(_ct, _filters), do: true

  defp kind_included?(_event, %{kinds: nil}), do: true
  defp kind_included?(event, %{kinds: kinds}), do: event.kind in kinds
  defp kind_included?(_event, _filters), do: true

  # A health filter is a question about content, so it excludes the lanes that
  # have no health rather than passing them through — an editor filtering to
  # "overdue" is not asking to also see every release.
  defp health_included?(_event, %{health: nil}), do: true
  defp health_included?(event, %{health: health}), do: event.health in health
  defp health_included?(_event, _filters), do: true

  defp in_window?(nil, _from, _to), do: false

  defp in_window?(at, from, to),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt
end
