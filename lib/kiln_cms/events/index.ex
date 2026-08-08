defmodule KilnCMS.Events.Index do
  @moduledoc """
  The occurrence-sorted delivery index — "what's on, soonest first" (#766).

  #480 shipped the schedule and recurrence field types, the `.ics` routes and
  the `schema.org/Event` node, and deferred this: a paginated index ordered by
  each document's *next* occurrence. That order is a function of `now()`, so it
  is not something `sort:` can reach — which is the whole problem this module
  exists to solve.

  ## The architecture call: a materialized column

  `next_occurrence_at` is a stored `:utc_datetime_usec` on every content
  resource, written by `KilnCMS.CMS.Changes.SetNextOccurrence` on save and kept
  fresh by `KilnCMS.Events.SweepWorker`. Sorting and pagination then happen in
  SQL, over an index, on a route anonymous clients hit.

  The two alternatives #766 lists were both rejected, and it is worth recording
  why:

    * **An occurrence table** — one row per expanded occurrence inside a rolling
      horizon — gives exact ordering and cheap *range* queries, at the cost of
      storage and a second thing to keep in sync. It is the right answer the day
      a single occurrence becomes addressable in its own right ("the 14 March
      instance of a weekly gig" with its own URL and its own cancellation). It
      is not needed to sort documents, which is what this is.
    * **SQL-side expansion** via a generated series has no staleness at all, and
      would mean a second RRULE implementation in SQL kept in step with
      `KilnCMS.Events.Recurrence` by hand. A recurrence engine that disagrees
      with itself between the listing and the `.ics` is worse than a staleness
      window measured in an hour.

  ## Why a stored value is not stale by construction

  "The next occurrence at or after T" only ever changes when T passes it. A row
  whose `next_occurrence_at` is still in the future is therefore *correct*, no
  matter how long ago it was written, and the sweep only has to visit rows whose
  value has already gone by — a small, self-limiting set, not the archive.

  That argument holds only if `nil` means "never again" rather than "not soon",
  which is why the materialization horizon is a **decade** rather than the 400
  days `KilnCMS.Events.Occurrences.next/3` defaults to. A `nil` that meant
  "nothing within 400 days" would need re-checking as the horizon rolled
  forward — over every past event a site has ever published, on every sweep. A
  decade costs nothing to look ahead for (expansion short-circuits on the first
  hit, and a rule with an `UNTIL`/`COUNT` stops at its own end), and it makes
  `nil` a terminal state.

  ## The day anchor

  Everything counts from the **start of the current day** in the deployment's
  event timezone, not from `DateTime.utc_now/0`. `next_occurrence_at` stores an
  occurrence's *start*, so anchoring at `now()` would drop this morning's gig
  off "what's on today" the minute its doors opened. One anchor, used by the
  write-time change, the sweep's staleness test, the sweep's recomputation and
  the delivery routes' default window — four callers that must agree, so there
  is one definition of it.

  ## What this index cannot answer

  Only the *next* occurrence is stored, so a window that starts in the future
  selects documents whose next occurrence falls inside it — **not** every
  recurrence instance inside it. A weekly gig whose next date is tomorrow does
  not appear in `?from=` next month, even though it recurs into that month.
  That is the honest limit of materializing one value per document, and it is
  the line past which the occurrence table above becomes the right answer.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Events
  alias KilnCMS.Events.Occurrences

  # See the moduledoc: a decade, so `nil` means "never again" and the sweep never
  # has to revisit a row that has one.
  @horizon_days 3660

  # The delivery routes' page size, and the ceiling on an explicit `?limit=`.
  # `read :read`'s own `max_page_size` is 100; this is the narrower public bound.
  @page_size 20

  @doc "How far ahead a materialized `next_occurrence_at` looks."
  @spec horizon_days() :: pos_integer()
  def horizon_days, do: @horizon_days

  @doc "Documents per page on the delivery index."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc """
  The instant the index counts from: the start of the current day, in the
  deployment's event timezone (`KilnCMS.Events.default_time_zone/0`), as UTC.

  Takes `now` so a test can pin it. See the moduledoc for why this is a day
  boundary rather than the current instant.
  """
  @spec anchor(DateTime.t()) :: DateTime.t()
  def anchor(now \\ DateTime.utc_now()) do
    zone = Events.default_time_zone()

    with {:ok, local} <- DateTime.shift_zone(now, zone),
         midnight = local |> DateTime.to_date() |> NaiveDateTime.new!(~T[00:00:00]),
         {:ok, utc} <- Events.to_utc(midnight, zone) do
      utc
    else
      # A zone whose day begins in a DST gap resolves through `Events.to_utc/2`
      # like every other wall time does, so this is only reachable if the zone
      # database itself refuses the name — and an index that anchors at `now`
      # is a worse answer than one that raises on a public route.
      _other -> now
    end
  end

  @doc """
  The value to store on `record`: the start of its next occurrence at or after
  `from`, or `nil`.

  `nil` for a document with no schedule field at all, which is how every
  non-event record answers — so this is safe to run on every content write
  rather than only on event-shaped types.
  """
  @spec next_occurrence_at(struct(), Ash.UUID.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def next_occurrence_at(record, org_id, from \\ anchor()) do
    case Occurrences.next(record, from, org_id: org_id, horizon_days: @horizon_days) do
      %{starts_at: starts_at} -> starts_at
      nil -> nil
    end
  end

  @doc """
  Recompute `record`'s sort key and store it, unless it is already right.

  The one write path, shared by `KilnCMS.Events.Sweep` (rows whose occurrence
  has gone by) and `KilnCMS.Events.Backfill` (every row, once). Returns
  `:written`, `:unchanged`, or `{:error, reason}`.

  ## Why "unless it is already right" is not an optimization

  A backfill visits the whole archive. Writing every row would bump `updated_at`
  on all of them — reordering the `updated_at`-sorted feeds and sitemap for no
  reason — and fire `Changes.BustContentCache` once per row, each drop taking
  the site's sitemap, `llms.txt` and feed caches with it. Skipping the no-ops is
  what makes the pass safe to run, and re-run, on a live site.

  The comparison is `DateTime.compare/2`, not `==`. A value read back from
  Postgres as `:utc_datetime_usec` carries `{0, 6}` microsecond precision while
  a freshly computed one carries `{0, 0}`, so struct equality calls every
  unchanged row changed — which would have quietly turned the skip into a
  no-op and rewritten the archive anyway.

  An unloaded `next_occurrence_at` matches no clause of `changed?/2` and raises,
  deliberately: a caller whose `select:` dropped it would otherwise compare
  against `%Ash.NotLoaded{}` and rewrite every row it touched.
  """
  @spec refresh(struct(), Ash.UUID.t(), DateTime.t()) :: :written | :unchanged | {:error, term()}
  def refresh(record, org_id, from) do
    next = next_occurrence_at(record, org_id, from)

    if changed?(record.next_occurrence_at, next) do
      write(record, org_id, next)
    else
      :unchanged
    end
  end

  defp changed?(%DateTime{} = stored, %DateTime{} = next),
    do: DateTime.compare(stored, next) != :eq

  defp changed?(nil, nil), do: false
  defp changed?(nil, %DateTime{}), do: true
  defp changed?(%DateTime{}, nil), do: true

  # `:set_next_occurrence`, never `:update` — see that action's comment in
  # `KilnCMS.CMS.Content`. `authorize?: false`: both callers are system passes
  # that must maintain the value for drafts and gated events too, because a
  # value that is only correct for public rows is wrong the moment one is
  # published.
  defp write(record, org_id, next) do
    record
    |> Ash.Changeset.for_update(:set_next_occurrence, %{next_occurrence_at: next},
      authorize?: false,
      tenant: org_id
    )
    |> Ash.update()
    |> case do
      {:ok, _record} -> :written
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every attribute the refresh path reads, and nothing else.

  Without a `select:` each row drags its whole `blocks` union tree and its
  embedding vector into memory — the spike this whole feature exists to keep off
  the request path, not to relocate into a background pass.

  The list is not arbitrary: `custom_fields` (+ `type_definition_id` on the
  dynamic tier) is the schedule; `next_occurrence_at` is what `refresh/3`
  compares against; `slug`, `locale`, `state` and `org_id` are what
  `Changes.BustContentCache` reads in its `after_action`. An attribute left out
  of a `select:` arrives as `%Ash.NotLoaded{}`, which is truthy and
  pattern-matches `%{state: state}` perfectly happily — so omitting `state`
  would not raise, it would silently stop busting.
  """
  @spec refresh_fields(map()) :: [atom()]
  def refresh_fields(descriptor) do
    [:id, :org_id, :slug, :locale, :state, :custom_fields, :next_occurrence_at] ++
      if(descriptor.source == :dynamic, do: [:type_definition_id], else: [])
  end

  @doc """
  Published, public, event-shaped documents of `descriptor`, soonest first.

  Returns an `Ash.Page.Offset`. Ordering and paging happen in Postgres over the
  `next_occurrence_at` index; nothing is expanded per request.

  Options:

    * `:from` / `:until` — the occurrence window. `:from` defaults to
      `anchor/1`; `:until` defaults to no upper bound.
    * `:locale` — defaults to `KilnCMS.I18n.default_locale/0`.
    * `:page` — zero-based page index.
    * `:limit` — page size, capped at `page_size/0`.

  ## The filter is identical to `KilnCMSWeb.CalendarController`'s, deliberately

  Published **and** `audience: :public`, one locale, read actorless under
  `authorize?: true` so the passphrase-lock policy (#496) excludes locked
  documents too. A delivery route that widens any of that is an audience leak,
  and #766 says in as many words not to re-derive it — so this is the one place
  the listing's filter is written, shared by the HTML index and the JSON one.
  """
  @spec upcoming(map(), Ash.UUID.t(), keyword()) :: Ash.Page.Offset.t()
  def upcoming(descriptor, org_id, opts \\ []) do
    from = Keyword.get(opts, :from) || anchor()
    until = Keyword.get(opts, :until)
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    limit = opts |> Keyword.get(:limit, @page_size) |> min(@page_size) |> max(1)
    page = opts |> Keyword.get(:page, 0) |> max(0)

    ContentTypes.list!(descriptor,
      authorize?: true,
      tenant: org_id,
      query: [
        filter: filter(from, until, locale),
        # Ascending, which is also a btree's own order — so `(org_id,
        # next_occurrence_at)` serves this by seeking rather than sorting. The
        # `DESC NULLS LAST` trap in the repo's Postgres notes does not bite
        # here, and not by luck: "soonest first" IS ascending, and the window's
        # lower bound excludes the NULL rows outright, so there is no
        # nulls-ordering for an index to fail to express.
        #
        # `:id` breaks ties. Two events starting at the same instant are common
        # (a festival's parallel stages), and an unstable order across pages
        # drops and repeats rows for a reader paging through.
        sort: [next_occurrence_at: :asc, id: :asc],
        select: select_fields(descriptor)
      ],
      # No `count: true`: only `more?` is read, and a count adds a COUNT(*) over
      # the whole published set to every request on an anonymous route.
      page: [limit: limit, offset: page * limit]
    )
  end

  @doc false
  # Public only so a test can assert on it directly, for the reason
  # `FeedController.filter/1` is: this filter is the difference between an index
  # and a leak, and the read policy also filters published-and-public — so
  # deleting `audience: :public` from here leaves a suite that asserts on
  # responses entirely green.
  def filter(from, until, locale) do
    [
      audience: :public,
      locale: locale,
      # BOTH bounds under ONE key. A keyword list is not a map, so
      # `[next_occurrence_at: [gte: …]] ++ [next_occurrence_at: [lte: …]]` is a
      # list with the key twice — which a builder is free to read as either one,
      # silently, and an unbounded window looks exactly like a working one.
      #
      # `>=` on the lower bound and `<=` on the upper: an event starting exactly
      # at the window's edge is in the window. The lower bound is also what
      # excludes every row with no upcoming occurrence — a NULL satisfies no
      # comparison — so "has nothing coming up" needs no clause of its own.
      next_occurrence_at: [greater_than_or_equal: from] ++ upper_bound(until)
    ]
  end

  defp upper_bound(nil), do: []
  defp upper_bound(until), do: [less_than_or_equal: until]

  # `type_definition_id` exists only on the dynamic tier — the `Content` macro
  # emits the `belongs_to` under `if dynamic?` — so naming it unconditionally
  # makes `Ash.Query.select/2` raise `NoSuchAttribute` the moment an operator
  # attaches a `datetime_range` field to a *compiled* type, which is exactly
  # what the docs invite. It is also not optional on the dynamic tier: it is how
  # a record resolves to the field definitions holding its schedule, and a
  # select that omits it hands `Events.scope_for/1` an `%Ash.NotLoaded{}`.
  #
  # `CalendarController.select_fields/1` branches for the same class of reason.
  @base_fields [
    :id,
    :title,
    :slug,
    :path_alias,
    :locale,
    :audience,
    :seo_description,
    :custom_fields,
    :next_occurrence_at,
    :published_at,
    :inserted_at,
    :updated_at
  ]

  defp select_fields(descriptor) do
    @base_fields ++
      if(descriptor.excerpt?, do: [:excerpt], else: []) ++
      if(descriptor.source == :dynamic, do: [:type_definition_id], else: [])
  end
end
