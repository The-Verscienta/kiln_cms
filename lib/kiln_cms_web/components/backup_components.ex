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
  `/editor/backups/<tab>`, so the tabs #2231 adds later (Destinations,
  Settings, Log) slot in as one more entry each.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.Types.UnknownAtom

  @tabs [:history, :schedule]

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
