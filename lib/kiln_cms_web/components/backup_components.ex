defmodule KilnCMSWeb.BackupComponents do
  @moduledoc """
  What the Backups pages share (part of #2219): the tabs, and the words for a
  schedule's cadence, its next window, its last outcome and the alarm
  threshold it sets.

  `KilnCMSWeb.BackupLive` (the Backups tab, `/editor/backups`),
  `KilnCMSWeb.BackupScheduleLive` (the Schedule tab,
  `/editor/backups/schedules`) and the home strips in
  `KilnCMSWeb.OverviewLive` all say these things, so they say them from here.

  The tabs are links to separate pages, each its own LiveView at
  `/editor/backups/<tab>`, so the tabs #2231 adds later (Settings, Log) slot
  in as one more entry each, as Destinations (`KilnCMSWeb.BackupDestinationsLive`,
  #2220) did.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.Types.UnknownAtom

  @tabs [:history, :schedule] ++ [:destinations]

  @doc "The tab keys, in the order they are shown."
  @spec tab_keys() :: [atom()]
  def tab_keys, do: @tabs

  attr :active, :atom, required: true, values: @tabs

  @doc "The Backups pages' tabs, with `aria-current` on the one shown."
  def tabs(assigns) do
    assigns = assign(assigns, :tabs, Enum.map(@tabs, &tab/1))

    ~H"""
    <nav id="backup-tabs" class="tabs" aria-label={gettext("Backup pages")}>
      <.link
        :for={tab <- @tabs}
        id={"backup-tab-#{tab.key}"}
        navigate={tab.path}
        class={["tab", tab.key == @active && "tab-active"]}
        aria-current={tab.key == @active && "page"}
      >
        {tab.label}
      </.link>
    </nav>
    """
  end

  defp tab(:history), do: %{key: :history, path: ~p"/editor/backups", label: gettext("Backups")}

  defp tab(:schedule),
    do: %{key: :schedule, path: ~p"/editor/backups/schedules", label: gettext("Schedule")}

  defp tab(:destinations),
    do: %{
      key: :destinations,
      path: ~p"/editor/backups/destinations",
      label: gettext("Destinations")
    }

  @doc """
  The alarm line for a backup that reached only some of its off-site
  destinations (#2220): `Backups.status/0`'s `offsite` when its state is
  `:partial`, else nil. The Backups page and the home strip both say it.
  """
  @spec offsite_headline(map() | nil) :: String.t() | nil
  def offsite_headline(%{state: :partial, ok: ok, total: total, failed: failed}) do
    gettext(
      "The last backup reached %{ok} of %{total} off-site destinations — %{names} failed",
      ok: ok,
      total: total,
      names: Enum.map_join(failed, ", ", &run_destination_label(&1.key, &1.label))
    )
  end

  def offsite_headline(_offsite), do: nil

  @doc """
  The alarm lines for retention that was skipped or stopped part-way (#2487),
  one per place in `Backups.status/0`'s `retention`, as `%{id: id, text: text}`:
  `id` is `"local"` for the backup directory and `"dest-<id>"` for a
  destination. Each names the backup whose prune it was by its date. The
  reason stays English, as the run log says it. The Backups page and the home
  strip both say them.
  """
  @spec retention_lines(map()) :: [%{id: String.t(), text: String.t()}]
  def retention_lines(%{retention: notices}) when is_list(notices),
    do: Enum.map(notices, &retention_line/1)

  def retention_lines(_status), do: []

  defp retention_line(%{scope: :local} = n) do
    %{id: "local", text: retention_text(n, nil)}
  end

  defp retention_line(%{scope: {:destination, "dest:" <> id}} = n) do
    %{id: "dest-" <> id, text: retention_text(n, n.label)}
  end

  defp retention_line(%{scope: {:destination, key}} = n) do
    %{id: "dest-" <> key, text: retention_text(n, n.label)}
  end

  defp retention_text(%{outcome: :skipped} = n, nil),
    do:
      gettext(
        "Retention was skipped on the backup of %{date}: %{reason}. Nothing was deleted, so local backups will build up until this is fixed.",
        date: retention_date(n),
        reason: n.reason || "—"
      )

  defp retention_text(%{outcome: :stopped} = n, nil),
    do:
      gettext(
        "Retention stopped part-way on the backup of %{date}: %{reason}. What it hadn't reached stays until this is fixed.",
        date: retention_date(n),
        reason: n.reason || "—"
      )

  defp retention_text(%{outcome: :skipped} = n, name),
    do:
      gettext(
        "Retention on %{name} was skipped on the backup of %{date}: %{reason}. Nothing was deleted there, so backups will build up there until this is fixed.",
        name: name,
        date: retention_date(n),
        reason: n.reason || "—"
      )

  defp retention_text(%{outcome: :stopped} = n, name),
    do:
      gettext(
        "Retention on %{name} stopped part-way on the backup of %{date}: %{reason}. What it hadn't reached stays until this is fixed.",
        name: name,
        date: retention_date(n),
        reason: n.reason || "—"
      )

  # The backup's own time (its stamp), or when the notice was written.
  defp retention_date(%{stamp: stamp, at: at}) do
    when_at =
      case is_binary(stamp) && KilnCMS.Backups.Artifact.parse_stamp(stamp) do
        {:ok, %DateTime{} = started} -> started
        _none -> at
      end

    Calendar.strftime(when_at, "%Y-%m-%d %H:%M UTC")
  end

  @doc """
  The warning for backups a schedule keeps that were found deleted outside
  the app (#2931): one sentence per notice of `Backups.status/0`'s
  `held_deleted` (one per backup directory), what it usually means, and a
  link to the guide's "The hold markers". The Backups page and the Schedule
  tab both show it; `id` is the element's id. Each sentence is dated by the
  detection and names up to ten backups by component and date, with "and N
  more" past that.
  """
  attr :id, :string, required: true
  attr :notices, :list, required: true

  def held_deleted_warning(assigns) do
    ~H"""
    <div id={@id} class="space-y-1">
      <p :for={{notice, n} <- Enum.with_index(@notices)} id={"#{@id}-#{n}"} class="font-medium">
        {held_deleted_line(notice)}
      </p>
      <p>
        {gettext(
          "This usually means the host's scripts/backup.sh is older than this release and ignores .hold markers. Replace it with this release's copy."
        )}
        <a
          id={"#{@id}-docs"}
          href={docs_url("backups.md#the-hold-markers")}
          target="_blank"
          rel="noopener"
          class="link inline-flex items-center gap-1"
        >
          {gettext("About the hold markers")}
          <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </a>
      </p>
    </div>
    """
  end

  @doc """
  One held-deleted notice (`Backups.status/0`'s `held_deleted`) in words:
  when it was found, how many backups, and which (up to ten listed).
  """
  @spec held_deleted_line(map()) :: String.t()
  def held_deleted_line(%{units: units, at: at} = notice) do
    total = max(notice[:total] || 0, length(units))
    listed = Enum.map_join(units, ", ", &held_unit_label/1)

    named =
      case total - length(units) do
        more when more > 0 ->
          ngettext("%{units} and %{count} more", "%{units} and %{count} more", more,
            units: listed
          )

        _none ->
          listed
      end

    ngettext(
      "On %{date}, a backup a schedule keeps was deleted outside the app: %{units}.",
      "On %{date}, %{count} backups a schedule keeps were deleted outside the app: %{units}.",
      total,
      date: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC"),
      units: named
    )
  end

  # `"<kind>:<stamp>"`: the component and the backup's date; anything else
  # (a kind or stamp a newer release wrote) as stored.
  defp held_unit_label(unit) do
    with [kind, stamp] <- String.split(unit, ":", parts: 2),
         {:ok, component} <- held_component(kind),
         {:ok, at} <- KilnCMS.Backups.Artifact.parse_stamp(stamp) do
      gettext("%{component} backup of %{date}",
        component: component,
        date: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
      )
    else
      _unknown -> unit
    end
  end

  defp held_component("db"), do: {:ok, component_label(:db)}
  defp held_component("media"), do: {:ok, component_label(:media)}
  defp held_component(_other), do: :error

  @doc """
  What a run's off-site destination is called: the label the run recorded,
  or, for the entry a run records when the stored destinations couldn't be
  read (`KilnCMS.Backups.RunDestination.unreadable_key/0`), a sentence.
  """
  @spec run_destination_label(String.t(), String.t() | nil) :: String.t()
  def run_destination_label(key, label) do
    if key == KilnCMS.Backups.RunDestination.unreadable_key(),
      do: gettext("the stored destinations (couldn't be read)"),
      else: label || key
  end

  @doc "A component's name: Database, Media, or what a newer release stored."
  @spec component_label(atom() | UnknownAtom.t()) :: String.t()
  def component_label(:db), do: gettext("Database")
  def component_label(:media), do: gettext("Media")
  # A component a newer release wrote (#2219): shown as stored.
  def component_label(%UnknownAtom{value: value}), do: value

  @doc "A backup run's status (`KilnCMS.Backups.Run`)."
  @spec run_status_label(atom()) :: String.t()
  def run_status_label(:succeeded), do: gettext("Succeeded")
  def run_status_label(:failed), do: gettext("Failed")
  def run_status_label(:running), do: gettext("Running")
  def run_status_label(:skipped), do: gettext("Skipped")
  def run_status_label(:canceled), do: gettext("Canceled")

  @doc "Why a backup can't run here (`KilnCMS.Backups.availability/0`'s reason)."
  @spec unavailable_message(atom() | nil) :: String.t()
  def unavailable_message(:disabled),
    do: gettext("In-app backups are turned off (BACKUP_ENABLED).")

  def unavailable_message(:no_database_url),
    do: gettext("No database connection is configured for backups.")

  def unavailable_message(reason) when reason in [:no_pg_dump, :no_pg_restore],
    do:
      gettext(
        "PostgreSQL client tools aren't installed in this image, so a backup can't run here. Cron backups on the host are unaffected."
      )

  def unavailable_message(_reason), do: gettext("A backup can't run on this deployment.")

  @sub_daily_hours %{every_2h: 2, every_4h: 4, every_8h: 8, every_12h: 12}

  @doc "A weekday (1 = Monday) through gettext, never `Calendar.strftime/2` (not translated)."
  @spec weekday(1..7) :: String.t()
  def weekday(1), do: gettext("Monday")
  def weekday(2), do: gettext("Tuesday")
  def weekday(3), do: gettext("Wednesday")
  def weekday(4), do: gettext("Thursday")
  def weekday(5), do: gettext("Friday")
  def weekday(6), do: gettext("Saturday")
  def weekday(7), do: gettext("Sunday")

  @doc """
  A schedule's cadence in words: "Every week on Thursday at 02:30
  (Etc/UTC)". Takes anything with the four timing fields, so the Schedule
  form previews an unsaved one.
  """
  @spec cadence(map()) :: String.t()
  def cadence(%{interval: interval, time_of_day: time, time_zone: zone, starts_on: start}) do
    time = time |> Time.to_string() |> String.slice(0, 5)

    case interval do
      :daily ->
        gettext("Every day at %{time} (%{zone})", time: time, zone: zone)

      :weekly ->
        gettext("Every week on %{weekday} at %{time} (%{zone})",
          weekday: weekday(Date.day_of_week(start)),
          time: time,
          zone: zone
        )

      :fortnightly ->
        gettext("Every 2 weeks on %{weekday} at %{time} (%{zone}), from %{date}",
          weekday: weekday(Date.day_of_week(start)),
          time: time,
          zone: zone,
          date: Date.to_iso8601(start)
        )

      :monthly ->
        gettext("Every month on day %{day} at %{time} (%{zone})",
          day: start.day,
          time: time,
          zone: zone
        )

      every when is_map_key(@sub_daily_hours, every) ->
        gettext("Every %{hours} hours from %{time} (%{zone})",
          hours: Map.fetch!(@sub_daily_hours, every),
          time: time,
          zone: zone
        )

      %UnknownAtom{value: value} ->
        gettext("An interval this release doesn't know (%{value})", value: value)
    end
  end

  @doc """
  How long until `at`: "in 3 hours", or "due now" for a window in the past
  (one that is due and waiting, a queued resume ahead of it). Messages that
  use it take the whole phrase as `%{when}`.
  """
  @spec until(DateTime.t()) :: String.t()
  def until(%DateTime{} = at) do
    seconds = DateTime.diff(at, DateTime.utc_now(), :second)

    cond do
      seconds <= 0 ->
        gettext("due now")

      seconds < 3600 ->
        minutes = max(div(seconds, 60), 1)

        gettext("in %{duration}",
          duration: ngettext("%{count} minute", "%{count} minutes", minutes, count: minutes)
        )

      seconds < 86_400 ->
        hours = div(seconds, 3600)

        gettext("in %{duration}",
          duration: ngettext("%{count} hour", "%{count} hours", hours, count: hours)
        )

      true ->
        days = div(seconds, 86_400)

        gettext("in %{duration}",
          duration: ngettext("%{count} day", "%{count} days", days, count: days)
        )
    end
  end

  @doc "What a schedule's last window did, or nil before its first."
  @spec outcome_label(map()) :: String.t() | nil
  def outcome_label(%{last_outcome: :started}), do: gettext("Last window: started")

  def outcome_label(%{last_outcome: :queued}),
    do: gettext("Last window: queued behind another backup")

  def outcome_label(%{last_outcome: :folded}),
    do: gettext("Last window: joined a queued backup")

  # A deferred window waits either behind a queued backup of another kind
  # (#2540) or for a node that can run backups (the one that checked lacked
  # pg_dump, pg_restore or a database URL).
  def outcome_label(%{last_outcome: :deferred, last_error: "queue_busy" <> _}),
    do:
      gettext("Waiting: another kind of backup is queued; this one starts once the queue clears.")

  def outcome_label(%{last_outcome: :deferred, last_error: error})
      when error in ["no_pg_dump", "no_pg_restore", "no_database_url"],
      do:
        gettext(
          "Waiting: the server that checked can't run backups (%{reason}); another server can take it.",
          reason: error
        )

  def outcome_label(%{last_outcome: :deferred}),
    do: gettext("Waiting: this window is asked for again each minute.")

  def outcome_label(%{last_outcome: :refused, last_error: error}),
    do: gettext("Last window refused: %{reason}", reason: error || "—")

  def outcome_label(_other), do: nil

  @doc "A component's alarm threshold and where it comes from (`Backups.status/0`)."
  @spec threshold_label(map()) :: String.t()
  def threshold_label(%{stale_after_hours: hours, stale_source: {:schedule, _id}}) do
    ngettext(
      "Alarm after %{count} hour without a good backup (its schedule)",
      "Alarm after %{count} hours without a good backup (its schedule)",
      hours,
      count: hours
    )
  end

  def threshold_label(%{stale_after_hours: hours, stale_source: {:cron, var}}) do
    ngettext(
      "Alarm after %{count} hour without a good backup (%{var}; host cron backs it up too)",
      "Alarm after %{count} hours without a good backup (%{var}; host cron backs it up too)",
      hours,
      count: hours,
      var: var
    )
  end

  def threshold_label(%{stale_after_hours: hours, stale_source: {:env, var}}) do
    ngettext(
      "Alarm after %{count} hour without a good backup (%{var})",
      "Alarm after %{count} hours without a good backup (%{var})",
      hours,
      count: hours,
      var: var
    )
  end

  # Suggestions for the Schedule form's time zone box, which takes any zone
  # the database knows (`Schedule.Validations.KnownZone` decides).
  @common_zones ~w(
    Etc/UTC Europe/London Europe/Dublin Europe/Lisbon Europe/Paris Europe/Berlin
    Europe/Madrid Europe/Rome Europe/Amsterdam Europe/Stockholm Europe/Warsaw
    Europe/Athens Europe/Helsinki Europe/Istanbul Europe/Moscow Africa/Lagos
    Africa/Johannesburg Africa/Cairo Asia/Dubai Asia/Kolkata Asia/Bangkok
    Asia/Singapore Asia/Shanghai Asia/Tokyo Asia/Seoul Australia/Sydney
    Pacific/Auckland America/Sao_Paulo America/Mexico_City America/New_York
    America/Chicago America/Denver America/Los_Angeles America/Anchorage
    Pacific/Honolulu
  )

  @doc """
  The time zones the Schedule form suggests: about thirty common ones, plus
  the deployment's default and `current` (the schedule's own), de-duplicated.
  """
  @spec time_zone_suggestions(String.t() | nil) :: [String.t()]
  def time_zone_suggestions(current \\ nil) do
    [KilnCMS.Events.default_time_zone(), current | @common_zones]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end
end
