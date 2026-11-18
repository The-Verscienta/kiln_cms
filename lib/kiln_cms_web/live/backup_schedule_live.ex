defmodule KilnCMSWeb.BackupScheduleLive do
  @moduledoc """
  The Schedule tab of the Backups pages (`/editor/backups/schedules`, part of
  #2219): the in-app backup schedules (`KilnCMS.Backups.Schedule`), and the
  forms to add, edit, pause, resume and delete them.

  ## Platform admins only

  A schedule backs up the whole instance, so, as on `KilnCMSWeb.BackupLive`,
  the route's per-org admin gate is not the question: `mount/3`,
  `handle_params/3`, every `handle_event/3` and the refresh ask
  `KilnCMSWeb.LiveUserAuth.platform_admin?/1` again (a user demoted, or whose
  grant expired, since the mount is sent to the access-denied page, #2875),
  and every read and write
  goes through the `KilnCMS.Backups` code interfaces as the admin, so the
  schedule's policies decide as well.

  Every handler that names a schedule takes only its **id** from the client
  and reads the schedule again (`Backups.get_backup_schedule/2`): a schedule
  deleted in another tab, or an id that was never one, is a flash, not a
  crash.

  An edit is saved only while the schedule still holds what the form was
  opened on: the editable values (keep fields included) are recorded when the
  form opens, and a save after someone else changed any of them (another
  admin paused it, say) is refused, so a form opened earlier never overwrites
  the change. The refused form stays open on the values as stored now, with
  what the admin entered shown read-only beside them
  (`#schedule-refused-values`, #2875), so nothing typed is lost and saving
  again is a deliberate choice; Cancel or a successful save clears it. A
  schedule deleted meanwhile, or one the form can no longer offer, still
  closes the form. Only one form is open at a time: while one is, Add and
  Edit are hidden.

  ## Keep fields

  A schedule may keep the newest N backups of each component it backs up
  (`keep_count`) and keep its own backups for a number of days (`keep_days`,
  `BACKUP_KEEP_DAYS` when not set); both are optional
  (`KilnCMS.Backups.Retention` has the rules). The preview estimates how many
  backups of each component that keeps at a time, counting the one being
  made while the prune runs, so N + 1. It says so when `keep_days` is shorter
  than `BACKUP_KEEP_DAYS` (only this schedule's own backups age out sooner),
  and, when the schedule would keep backups past `BACKUP_KEEP_DAYS` while
  host cron backs a component up here too (`Backups.cron_backs_up?/1`), that
  the host's `scripts/backup.sh` must be this release's, since an older copy
  deletes what the schedule holds. Whatever the preview says, the fieldset
  always says that a host whose cron prunes this directory needs this
  release's `scripts/backup.sh` (`#schedule-keep-host-hint`, #2931), and the
  warnings above the list say when a backup a schedule keeps was found
  deleted outside the app (`Backups.status/0`'s `held_deleted`). Deleting a
  schedule says that its backups then age out under `BACKUP_KEEP_DAYS`,
  never sooner.

  A schedule that runs more often than daily must set `keep_days`
  (`Schedule.Validations.SubDailyKeepsDays`): the form marks the field
  required and shows the resource's error under it. A sub-daily schedule
  stored without one (written from a console) stays editable: its card says
  it needs Keep for (days) (`data-role="needs-keep-days"`), it can be paused,
  resumed or deleted as it is, and the form opens with the field empty, so
  saving it means setting one.

  ## What the form can't offer, it doesn't edit

  The form offers every interval (`Schedule.intervals/0`), the database, and
  the media when this deployment archives any. A schedule whose stored values
  fall outside that (an interval or component a newer release wrote, which
  loads as `KilnCMS.Types.UnknownAtom`; media on a deployment that no longer
  has a media directory) is shown read-only with a note: it can be paused, resumed or deleted, never
  re-submitted through a form that would have to change what it can't show.

  ## What the list shows

  The list and the warnings come from `Backups.status/0`, the source the
  alarm thresholds and the home strips use, so "next run" is shown only when
  the schedule can fire here. Each schedule also shows what its newest run
  actually did (`Backups.last_scheduled_runs/2`), since a window's claim says
  only that a backup was asked for.

  While connected, the page re-reads all of that every minute. An open form
  is left as it is.
  """
  use KilnCMSWeb, :live_view

  import KilnCMSWeb.BackupComponents

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Schedule
  alias KilnCMS.Backups.Schedule.Window
  alias KilnCMS.Backups.Scheduler
  alias KilnCMS.Types.UnknownAtom

  @refresh_ms 60_000

  # The least an enabled schedule may wait for the scheduler's first tick, and
  # how old the last tick may be, before the page says it hasn't run; a
  # KILN_BACKUP_SCHEDULER_CRON slot further back stretches it
  # (`tick_expected_since/1`).
  @stale_tick_floor_s 300

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backup schedule"))
       |> assign(:form, nil)
       |> assign(:editing, nil)
       |> assign(:opened_values, nil)
       |> assign(:refused_values, nil)
       |> assign(:cron_components, [])
       |> assign(:preview, nil)
       |> load()
       |> schedule_refresh()}
    else
      # As `BackupLive`: the route's gate is any site admin, a schedule is
      # instance-wide.
      {:ok, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: {:noreply, socket},
      else: deny(socket)
  end

  @events ~w(new edit cancel validate save toggle delete)

  # Every event asks again, whatever it is: see the moduledoc. An event this
  # page doesn't have falls to the catch-all every Kiln LiveView gets
  # (`KilnCMSWeb.MalformedEvent`).
  @impl true
  def handle_event(event, params, socket) when event in @events do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: event(event, params, socket),
      else: deny(socket)
  end

  # A user who stopped being a platform admin mid-session (demoted, or their
  # grant expired) is sent where the mount would have sent them, rather than
  # left clicking buttons that silently do nothing (#2875). Nothing is read or
  # written first.
  defp deny(socket),
    do: {:noreply, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}

  # Add and Edit are hidden while a form is open; a click that was already on
  # its way doesn't discard the open one.
  defp event(event, _params, %{assigns: %{form: %Phoenix.HTML.Form{}}} = socket)
       when event in ["new", "edit"],
       do: {:noreply, socket}

  defp event("new", _params, socket) do
    form = create_form(socket.assigns.current_user, socket.assigns[:security_context])
    {:noreply, open_form(socket, :new, form)}
  end

  defp event("edit", %{"id" => id}, socket) when is_binary(id) do
    with_schedule(socket, id, fn schedule ->
      if editable?(schedule) do
        form = edit_form(schedule, socket.assigns.current_user, socket.assigns[:security_context])

        {:noreply,
         socket
         |> open_form(schedule.id, form)
         |> assign(:opened_values, editable_values(schedule))}
      else
        {:noreply, put_flash(socket, :error, locked_flash())}
      end
    end)
  end

  defp event("cancel", _params, socket), do: {:noreply, close_form(socket)}

  defp event("validate", %{"schedule" => params}, socket) when is_map(params) do
    with_open_form(socket, :validate, fn socket, form ->
      form = AshPhoenix.Form.validate(form, normalize(params))
      {:noreply, socket |> assign(:form, to_form(form)) |> assign_preview(form)}
    end)
  end

  defp event("save", %{"schedule" => params}, socket) when is_map(params) do
    with_open_form(socket, {:save, params}, fn socket, form ->
      case AshPhoenix.Form.submit(form, params: normalize(params)) do
        {:ok, _schedule} ->
          {:noreply,
           socket
           |> close_form()
           |> put_flash(:info, gettext("Schedule saved."))
           |> load()}

        {:error, form} ->
          {:noreply, socket |> assign(:form, to_form(form)) |> assign_preview(form)}
      end
    end)
  end

  defp event("toggle", %{"id" => id}, socket) when is_binary(id) do
    with_schedule(socket, id, fn schedule ->
      case Backups.update_backup_schedule(schedule, %{enabled: not schedule.enabled},
             actor: socket.assigns.current_user,
             context: socket.assigns[:security_context] || %{}
           ) do
        {:ok, %{enabled: true}} ->
          {:noreply, socket |> put_flash(:info, gettext("Schedule resumed.")) |> load()}

        {:ok, %{enabled: false}} ->
          {:noreply, socket |> put_flash(:info, gettext("Schedule paused.")) |> load()}

        {:error, error} ->
          {:noreply, socket |> put_flash(:error, write_error(error)) |> load()}
      end
    end)
  end

  defp event("delete", %{"id" => id}, socket) when is_binary(id) do
    with_schedule(socket, id, fn schedule ->
      case Backups.destroy_backup_schedule(schedule,
             actor: socket.assigns.current_user,
             context: socket.assigns[:security_context] || %{}
           ) do
        :ok ->
          {:noreply,
           socket
           |> close_form_of(schedule.id)
           |> put_flash(:info, gettext("Schedule deleted."))
           |> load()}

        {:error, error} ->
          {:noreply, socket |> put_flash(:error, write_error(error)) |> load()}
      end
    end)
  end

  # A mangled payload is a no-op (#764).
  defp event(_event, _params, socket), do: {:noreply, socket}

  # Re-reads the list, the runs and the scheduler's last tick. Never the open
  # form: the admin may be halfway through it.
  @impl true
  def handle_info(:refresh, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: {:noreply, socket |> load() |> schedule_refresh()},
      else: deny(socket)
  end

  defp schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    socket
  end

  # The schedule `id` as it is stored now, read as this admin: `fun` gets it,
  # and a schedule that is gone (deleted meanwhile, or never was) is a flash.
  # The id is compared with the open form's in its stored (lowercase) form, so
  # `"ABC…"` and `"abc…"` are the same schedule.
  defp with_schedule(socket, id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> with_stored_schedule(socket, id, fun)
      # An id that isn't a UUID was never a schedule.
      :error -> {:noreply, put_flash(socket, :error, gone_flash())}
    end
  end

  defp with_stored_schedule(socket, id, fun) do
    case Backups.get_backup_schedule(id,
           actor: socket.assigns.current_user,
           not_found_error?: false
         ) do
      {:ok, %Schedule{} = schedule} ->
        fun.(schedule)

      {:ok, nil} ->
        {:noreply, socket |> close_form_of(id) |> put_flash(:error, gone_flash()) |> load()}

      {:error, %Ash.Error.Invalid{}} ->
        {:noreply, socket |> close_form_of(id) |> put_flash(:error, gone_flash())}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, write_error(error))}
    end
  end

  # The open form, after reading its schedule again when it edits one: a form
  # whose schedule was deleted, or became one the form can't offer, closes,
  # and a save whose schedule changed since the form opened is refused (see
  # the moduledoc). `step` is `:validate` or `{:save, params}`.
  defp with_open_form(%{assigns: %{form: nil}} = socket, _step, _fun), do: {:noreply, socket}

  defp with_open_form(%{assigns: %{editing: :new, form: form}} = socket, _step, fun),
    do: fun.(socket, form.source)

  defp with_open_form(%{assigns: %{editing: id}} = socket, step, fun) do
    with_schedule(socket, id, fn schedule ->
      cond do
        not editable?(schedule) ->
          {:noreply, socket |> close_form() |> put_flash(:error, locked_flash())}

        changed_since_opened?(step, schedule, socket) ->
          {:save, params} = step
          {:noreply, socket |> refuse_changed(schedule, params) |> load()}

        true ->
          # Built on the row as stored now (`Rebaseline` compares with it).
          form =
            edit_form(schedule, socket.assigns.current_user, socket.assigns[:security_context])

          fun.(socket, form.source)
      end
    end)
  end

  defp changed_since_opened?({:save, _params}, schedule, socket),
    do: editable_values(schedule) != socket.assigns.opened_values

  defp changed_since_opened?(_step, _schedule, _socket), do: false

  # What the form edits, as stored: compared on save with what it held when
  # the form opened.
  @compared [
    :components,
    :interval,
    :time_of_day,
    :starts_on,
    :time_zone,
    :enabled,
    :keep_count,
    :keep_days
  ]

  defp editable_values(%Schedule{} = schedule), do: Map.take(schedule, @compared)

  # The form stays open, rebuilt on the row as stored now, which is also what
  # the next save is compared with; what the admin entered is shown beside it
  # (`refused_rows/2`) until Cancel or a save that goes through.
  defp refuse_changed(socket, schedule, params) do
    form = edit_form(schedule, socket.assigns.current_user, socket.assigns[:security_context])

    socket
    |> assign(:form, form)
    |> assign(:opened_values, editable_values(schedule))
    |> assign(:refused_values, refused_rows(normalize(params), schedule))
    |> assign_preview(form.source)
    |> put_flash(:error, changed_flash())
  end

  defp open_form(socket, editing, form) do
    socket
    |> assign(:editing, editing)
    |> assign(:form, form)
    # Asked once per form, not on every keystroke: whether host cron backs up
    # here as well, for the preview's notice about the host's backup.sh.
    |> assign(
      :cron_components,
      Enum.filter(Backups.expected_components(), &Backups.cron_backs_up?/1)
    )
    |> assign_preview(form.source)
  end

  defp close_form(socket) do
    socket
    |> assign(:editing, nil)
    |> assign(:form, nil)
    |> assign(:opened_values, nil)
    |> assign(:refused_values, nil)
    |> assign(:cron_components, [])
    |> assign(:preview, nil)
  end

  defp assign_preview(socket, form),
    do: assign(socket, :preview, preview(form, socket.assigns.cron_components))

  defp close_form_of(%{assigns: %{editing: id}} = socket, id), do: close_form(socket)
  defp close_form_of(socket, _id), do: socket

  defp gone_flash, do: gettext("That schedule no longer exists.")

  defp changed_flash,
    do:
      gettext(
        "This schedule changed since you opened it, so it wasn't saved. The form now holds the stored values, with what you entered beside them: re-enter the changes you still want and save."
      )

  defp locked_flash,
    do: gettext("This schedule can't be edited here: it can only be paused, resumed or deleted.")

  defp write_error(%Ash.Error.Forbidden{}),
    do: gettext("Only a platform admin can change backup schedules.")

  defp write_error(_error), do: gettext("Couldn't change the backup schedule.")

  defp create_form(actor, context) do
    zone = KilnCMS.Events.default_time_zone()

    Schedule
    |> AshPhoenix.Form.for_create(:create,
      actor: actor,
      context: context || %{},
      as: "schedule",
      params: %{
        "components" => Enum.map(Backups.expected_components(), &Atom.to_string/1),
        "interval" => "daily",
        "time_of_day" => "03:00",
        "starts_on" => Date.to_iso8601(today_in(zone)),
        "time_zone" => zone,
        "enabled" => "true"
      }
    )
    |> to_form()
  end

  defp edit_form(schedule, actor, context) do
    schedule
    |> AshPhoenix.Form.for_update(:update,
      actor: actor,
      context: context || %{},
      as: "schedule"
    )
    |> to_form()
  end

  defp today_in(zone) do
    case DateTime.now(zone) do
      {:ok, now} -> DateTime.to_date(now)
      {:error, _} -> Date.utc_today()
    end
  end

  # Checkboxes submit only the checked boxes, so the group carries a hidden
  # "" to send the key at all; it never reaches the attribute. Unchecking
  # every box sends `[]`, which the resource refuses (`min_length`). An empty
  # keep field is "not set" (nil), which clears it on an edit.
  defp normalize(params) do
    params =
      case Map.fetch(params, "components") do
        {:ok, list} ->
          Map.put(params, "components", list |> List.wrap() |> Enum.reject(&(&1 == "")))

        :error ->
          params
      end

    Enum.reduce(["keep_count", "keep_days"], params, &blank_to_nil/2)
  end

  defp blank_to_nil(key, params) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: Map.put(params, key, nil), else: params

      _absent_or_not_text ->
        params
    end
  end

  @doc false
  # Whether the form can offer every value `schedule` stores (see the
  # moduledoc). Public for the tests.
  @spec editable?(Schedule.t()) :: boolean()
  def editable?(%Schedule{interval: interval, components: components}) do
    interval in Schedule.intervals() and is_list(components) and
      Enum.all?(components, &(&1 in [:db, :media])) and
      (:media not in components or Backups.media_dir() != nil)
  end

  defp locked_reason(%Schedule{interval: %UnknownAtom{}}), do: :unknown

  defp locked_reason(%Schedule{components: components}) do
    if Enum.any?(components, &match?(%UnknownAtom{}, &1)), do: :unknown, else: :media
  end

  defp locked_note(:unknown),
    do:
      gettext(
        "A newer release saved this schedule with a value this release doesn't know, so it can't be edited here. You can pause, resume or delete it."
      )

  defp locked_note(:media),
    do:
      gettext(
        "This schedule backs up media, which isn't archived on this deployment, so it can't be edited here. You can pause, resume or delete it."
      )

  # The cadence and first window of what the form holds now, and whether it
  # is enabled, or nil while it holds something that has none (an invalid
  # zone, a missing date). Whether it would run here at all is the
  # template's question (`@status`). `cron` is the components host cron backs
  # up here as well (`Backups.cron_backs_up?/1`).
  defp preview(%AshPhoenix.Form{source: %Ash.Changeset{} = changeset}, cron) do
    timing =
      Map.new([:interval, :time_of_day, :starts_on, :time_zone], fn field ->
        {field, Ash.Changeset.get_attribute(changeset, field)}
      end)

    now = DateTime.utc_now()

    with %Time{} <- timing.time_of_day,
         %Date{} <- timing.starts_on,
         true <- timing.interval in Schedule.intervals(),
         true <- KilnCMS.Events.known_time_zone?(timing.time_zone),
         {:ok, %DateTime{} = first} <- Window.next(Map.put(timing, :baseline_at, now), now) do
      %{
        cadence: cadence(timing),
        first: first,
        zone: timing.time_zone,
        enabled?: Ash.Changeset.get_attribute(changeset, :enabled) != false
      }
      |> Map.merge(keep_preview(changeset, timing.interval, cron))
    else
      _ -> nil
    end
  end

  defp preview(_form, _cron), do: nil

  # What the keep fields the form holds would keep: `estimate` backups of each
  # component at a time, `shorter_days` when its own backups age out before
  # BACKUP_KEEP_DAYS, and `cron` (the components host cron also backs up)
  # when it keeps some past BACKUP_KEEP_DAYS, which an older host backup.sh
  # would delete.
  defp keep_preview(changeset, interval, cron) do
    count = positive(Ash.Changeset.get_attribute(changeset, :keep_count))
    days = positive(Ash.Changeset.get_attribute(changeset, :keep_days))
    components = Ash.Changeset.get_attribute(changeset, :components)
    components = if is_list(components), do: components, else: []
    default = Backups.keep_days()

    %{
      components: components,
      estimate: estimate(interval, count, days || default),
      shorter_days: if(days && days < default, do: days),
      cron:
        if(beyond_default?(interval, count, days, default),
          do: Enum.filter(components, &(&1 in cron)),
          else: []
        )
    }
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_other), do: nil

  @doc false
  # About how many backups of each component a schedule keeps at a time: the
  # ones younger than `days` (one every interval, counted in hours, so a
  # two-hourly schedule keeping 7 days keeps about 85) or its newest `count`,
  # whichever is more, plus the one being made, since the prune runs while
  # it is still in flight (so N + 1); never under two, as the newest finished
  # backup is always kept beside it. An interval this release doesn't know
  # counts as daily. Public for the tests.
  @spec estimate(term(), pos_integer() | nil, pos_integer()) :: pos_integer()
  def estimate(interval, count, days) do
    hours = Window.interval_hours(interval) || 24
    Enum.max([div(days * 24, hours) + 1, (count || 0) + 1, 2])
  end

  @doc false
  # Whether some of what the schedule keeps is older than BACKUP_KEEP_DAYS
  # (`default`): a longer `keep_days`, or a newest N reaching further back
  # (N intervals, in hours). Public for the tests.
  @spec beyond_default?(term(), pos_integer() | nil, pos_integer() | nil, pos_integer()) ::
          boolean()
  def beyond_default?(interval, count, days, default) do
    hours = Window.interval_hours(interval) || 24
    (days != nil and days > default) or (count != nil and count * hours > default * 24)
  end

  # Everything shown but the form: the schedules with their next window (one
  # source with the thresholds, `Backups.status/0`), what each one's newest
  # run did, and the scheduler's last tick when it matters.
  defp load(socket) do
    status = Backups.status()
    entries = if is_list(status.schedules), do: status.schedules, else: []
    ids = Enum.map(entries, & &1.schedule.id)

    runs = last_runs(ids, socket.assigns.current_user)

    socket
    |> assign(:status, status)
    |> assign(:entries, entries)
    |> assign(:runs, runs)
    |> assign(:media_dir?, Backups.media_dir() != nil)
    |> assign(:stale_tick, stale_tick(status, entries, DateTime.utc_now()))
  end

  @doc false
  # `{:stale, last_tick_at | nil}` when the scheduler should have ticked and
  # hasn't: it is on, an enabled schedule has existed (since its baseline)
  # since before `tick_expected_since/1`, and no tick started after it.
  # `:unknown` when that couldn't be read. The `oban_jobs` read
  # (`Scheduler.last_tick_at/0`) is made only when a tick is expected.
  # Public, with `now`, for the tests: a weekday-only cron is checked on a
  # Saturday (#2875).
  @spec stale_tick(map(), [map()], DateTime.t()) :: {:stale, DateTime.t() | nil} | :unknown | nil
  def stale_tick(%{scheduler_enabled?: true}, entries, %DateTime{} = now) do
    expected_since = tick_expected_since(now)

    waiting? =
      Enum.any?(entries, fn %{schedule: s} ->
        s.enabled and DateTime.compare(s.baseline_at, expected_since) == :lt
      end)

    with true <- waiting?,
         {:ok, last} <- Scheduler.last_tick_at(),
         true <- is_nil(last) or DateTime.compare(last, expected_since) == :lt do
      {:stale, last}
    else
      :error -> :unknown
      _ -> nil
    end
  end

  def stale_tick(_status, _entries, _now), do: nil

  # The time a healthy scheduler has ticked since: the cron's newest slot at
  # least five minutes ago, so every slot gets the same five minutes before
  # it is late. At `* * * * 1-5` on a Saturday, and on Monday until 00:05,
  # that is Friday 23:59, so a weekend is not "hasn't run". When the cron has
  # no slot (`@reboot`), five minutes ago.
  defp tick_expected_since(now) do
    Scheduler.expected_tick_at(now, @stale_tick_floor_s) ||
      DateTime.add(now, -@stale_tick_floor_s, :second)
  end

  @doc false
  # Each schedule's newest run, or `:unreadable` when they couldn't be read:
  # the page says so once, instead of every card claiming there was no run.
  # Public for the tests.
  @spec last_runs([String.t()], term()) :: %{optional(String.t()) => term()} | :unreadable
  def last_runs(ids, actor) do
    case Backups.last_scheduled_runs(ids, actor) do
      {:ok, runs} -> runs
      {:error, _error} -> :unreadable
    end
  end

  # Shortest first, as `Schedule.intervals/0`.
  defp interval_options do
    [
      {gettext("Every 2 hours"), "every_2h"},
      {gettext("Every 4 hours"), "every_4h"},
      {gettext("Every 8 hours"), "every_8h"},
      {gettext("Every 12 hours"), "every_12h"},
      {gettext("Every day"), "daily"},
      {gettext("Every week"), "weekly"},
      {gettext("Every 2 weeks"), "fortnightly"},
      {gettext("Every month"), "monthly"}
    ]
  end

  # A sub-daily schedule must set `keep_days` (`Schedule.Validations.SubDailyKeepsDays`).
  defp needs_keep_days?(%Schedule{interval: interval, keep_days: days}),
    do: interval in Schedule.sub_daily_intervals() and is_nil(days)

  # The hours between a sub-daily interval's slots, or nil for daily and
  # longer. The form's value is the stored atom or the submitted string.
  defp sub_daily_hours(value) do
    interval =
      Enum.find(Schedule.sub_daily_intervals(), &(&1 == value or Atom.to_string(&1) == value))

    interval && Window.interval_hours(interval)
  end

  # `type="time"` takes HH:MM; the field holds a `Time` or what was typed.
  defp hhmm(%Time{} = time), do: time |> Time.to_string() |> String.slice(0, 5)
  defp hhmm(other), do: other

  defp checked_components(form) do
    case form[:components].value do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp local_stamp(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M")
      {:error, _} -> stamp(at)
    end
  end

  defp components_label(components) when is_list(components),
    do: Enum.map_join(components, " + ", &component_label/1)

  # Deleting a schedule never ages its backups out sooner than
  # BACKUP_KEEP_DAYS (another schedule backing the same component up may keep
  # them longer); its own keep fields stop applying.
  defp delete_confirm(%Schedule{} = schedule) do
    days = Backups.keep_days()

    if keep_set?(schedule) do
      ngettext(
        "Delete this schedule? Its keep settings stop applying. Backups it already took stay, and age out after %{count} day (BACKUP_KEEP_DAYS), never sooner.",
        "Delete this schedule? Its keep settings stop applying. Backups it already took stay, and age out after %{count} days (BACKUP_KEEP_DAYS), never sooner.",
        days,
        count: days
      )
    else
      ngettext(
        "Delete this schedule? Backups it already took stay, and age out after %{count} day (BACKUP_KEEP_DAYS), never sooner.",
        "Delete this schedule? Backups it already took stay, and age out after %{count} days (BACKUP_KEEP_DAYS), never sooner.",
        days,
        count: days
      )
    end
  end

  defp keep_set?(schedule), do: schedule.keep_count != nil or schedule.keep_days != nil

  # The card's keep line.
  defp keep_line(%Schedule{keep_count: count} = schedule) do
    days = keep_days_text(schedule.keep_days)

    if is_integer(count),
      do:
        ngettext(
          "Keeps its newest backup, and every one from the last %{days}",
          "Keeps its newest %{count} backups, and every one from the last %{days}",
          count,
          days: days
        ),
      else: gettext("Keeps its backups for %{days}", days: days)
  end

  defp keep_days_text(days) when is_integer(days),
    do: ngettext("%{count} day", "%{count} days", days)

  defp keep_days_text(_unset) do
    days = Backups.keep_days()
    ngettext("%{count} day (BACKUP_KEEP_DAYS)", "%{count} days (BACKUP_KEEP_DAYS)", days)
  end

  # What a refused save held, beside what is stored now, as display text: one
  # row per editable field, `differs?` where they disagree. The submitted
  # values are the client's, so they are only ever shown (escaped by HEEx)
  # and capped in length.
  defp refused_rows(params, %Schedule{} = schedule) do
    for field <- @compared do
      yours = submitted_text(field, Map.get(params, Atom.to_string(field)))
      stored = stored_text(field, Map.get(schedule, field))

      %{
        field: field,
        label: field_label(field),
        yours: yours,
        stored: stored,
        differs?: yours != stored
      }
    end
  end

  @shown_max 100

  defp submitted_text(:components, list) when is_list(list) do
    known = %{"db" => :db, "media" => :media}

    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Map.get(known, &1, &1))
    |> Enum.sort_by(&component_order/1)
    |> Enum.uniq()
    |> components_text()
  end

  defp submitted_text(:interval, value) when is_binary(value) do
    case List.keyfind(interval_options(), value, 1) do
      {label, _} -> label
      nil -> cap(value)
    end
  end

  defp submitted_text(:time_of_day, value) when is_binary(value), do: String.slice(value, 0, 5)
  defp submitted_text(:enabled, value), do: enabled_text(value in ["true", true])
  defp submitted_text(_field, value) when is_binary(value), do: cap(value)
  defp submitted_text(_field, _absent), do: not_set()

  defp stored_text(:components, list) when is_list(list),
    do: list |> Enum.sort_by(&component_order/1) |> components_text()

  defp stored_text(:interval, interval) do
    case List.keyfind(interval_options(), to_string_atom(interval), 1) do
      {label, _} -> label
      nil -> to_string_atom(interval)
    end
  end

  defp stored_text(:time_of_day, %Time{} = time), do: hhmm(time)
  defp stored_text(:starts_on, %Date{} = date), do: Date.to_iso8601(date)
  defp stored_text(:enabled, enabled), do: enabled_text(enabled == true)
  defp stored_text(_field, nil), do: not_set()
  defp stored_text(_field, value), do: cap(to_string(value))

  defp to_string_atom(%UnknownAtom{value: value}), do: value
  defp to_string_atom(atom), do: to_string(atom)

  defp component_order(:db), do: 0
  defp component_order(:media), do: 1
  defp component_order(_other), do: 2

  defp components_text([]), do: not_set()

  defp components_text(list),
    do: Enum.map_join(list, " + ", &if(is_binary(&1), do: cap(&1), else: component_label(&1)))

  defp enabled_text(true), do: gettext("Enabled")
  defp enabled_text(false), do: gettext("Paused")

  defp not_set, do: gettext("Not set")

  defp cap(text), do: String.slice(text, 0, @shown_max)

  defp field_label(:components), do: gettext("What to back up")
  defp field_label(:interval), do: gettext("How often")
  defp field_label(:time_of_day), do: gettext("At")
  defp field_label(:starts_on), do: gettext("Starting on")
  defp field_label(:time_zone), do: gettext("Time zone")
  defp field_label(:enabled), do: gettext("Enabled")
  defp field_label(:keep_count), do: gettext("Keep the newest")
  defp field_label(:keep_days), do: gettext("Keep for (days)")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:backups}
    >
      <div class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6">
        <.tabs active={:schedule} />

        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold">{gettext("Backup schedule")}</h1>
            <p class="mt-1 text-sm text-base-content/70">
              {gettext(
                "When this deployment backs itself up. Schedules run in the app; a cron job on the host can back up as well."
              )}
            </p>
          </div>
          <button
            :if={is_nil(@form)}
            id="schedule-new"
            type="button"
            phx-click="new"
            class="btn btn-primary"
          >
            <.icon name="hero-plus" class="mr-1 size-4" />
            {gettext("Add a schedule")}
          </button>
        </div>

        <.warnings
          status={@status}
          entries={@entries}
          stale_tick={@stale_tick}
          media_dir?={@media_dir?}
        />

        <.schedule_form
          :if={@form}
          form={@form}
          editing={@editing}
          preview={@preview}
          refused_values={@refused_values}
          media_dir?={@media_dir?}
          runs_here?={@status.scheduler_enabled? and @status.available?}
        />

        <section id="backup-schedules" class="rounded-lg border border-base-content/10 p-4 text-sm">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
            {gettext("Schedules")}
          </h2>

          <p :if={@status.schedules == :none} class="mt-2 text-base-content/70">
            {gettext(
              "No schedules yet. Backups run when you click Back up now, or from the host's cron job."
            )}
          </p>
          <p :if={@status.schedules == :unreadable} class="mt-2 text-warning-ink">
            {gettext("Couldn't load the backup schedules.")}
          </p>

          <p
            :if={@entries != [] and @runs == :unreadable}
            id="backup-schedule-runs-unreadable"
            class="mt-2 text-warning-ink"
          >
            {gettext("Couldn't load the last runs.")}
          </p>

          <ul :if={@entries != []} class="mt-3 divide-y divide-base-content/10">
            <.schedule_card
              :for={entry <- @entries}
              entry={entry}
              run={if @runs == :unreadable, do: :unreadable, else: @runs[entry.schedule.id]}
              editing?={@editing == entry.schedule.id}
              form_open?={@form != nil}
            />
          </ul>

          <p id="backup-schedule-retention" class="mt-3 text-xs text-base-content/70">
            {ngettext(
              "Backups are kept for BACKUP_KEEP_DAYS (%{count} day) unless a schedule keeps its own longer or shorter; the newest finished backup of each component is always kept.",
              "Backups are kept for BACKUP_KEEP_DAYS (%{count} days) unless a schedule keeps its own longer or shorter; the newest finished backup of each component is always kept.",
              Backups.keep_days(),
              count: Backups.keep_days()
            )}
          </p>
        </section>
      </div>
    </Layouts.console>
    """
  end

  attr :status, :map, required: true
  attr :entries, :list, required: true
  attr :stale_tick, :any, required: true
  attr :media_dir?, :boolean, required: true

  defp warnings(assigns) do
    assigns =
      assign(
        assigns,
        :media_without_dir?,
        not assigns.media_dir? and
          Enum.any?(assigns.entries, &(:media in List.wrap(&1.schedule.components)))
      )

    ~H"""
    <div
      :if={
        not @status.scheduler_enabled? or not @status.available? or @stale_tick != nil or
          @media_without_dir? or @status.held_deleted != []
      }
      class="space-y-2 rounded-lg border border-warning/30 bg-warning/5 p-4 text-sm text-warning-ink"
    >
      <p :if={@status.scheduler_cron == :off} id="schedule-scheduler-off">
        {gettext(
          "The scheduler is turned off on this deployment (KILN_BACKUP_SCHEDULER_CRON), so these schedules don't run."
        )}
      </p>
      <p :if={@status.scheduler_cron == :invalid} id="schedule-scheduler-invalid">
        {gettext(
          "KILN_BACKUP_SCHEDULER_CRON isn't a valid cron expression, so the scheduler is off and these schedules don't run."
        )}
      </p>
      <%!-- #2935: an expression such as 0 0 31 2 * (31 February) on an Oban
           that parses it. --%>
      <p :if={@status.scheduler_cron == :never_matches} id="schedule-scheduler-never">
        {gettext(
          "KILN_BACKUP_SCHEDULER_CRON only matches a date that doesn't exist, such as 31 February, so these schedules never run."
        )}
      </p>
      <p :if={@status.scheduler_enabled? and not @status.available?} id="schedule-unavailable">
        {gettext("In-app backups can't run here, so schedules are skipped: %{reason}",
          reason: unavailable_message(@status.reason)
        )}
      </p>
      <p :if={match?({:stale, %DateTime{}}, @stale_tick)} id="schedule-stale-tick">
        {gettext("The scheduler hasn't run since %{when}. Check that background jobs are running.",
          when: stamp(elem(@stale_tick, 1))
        )}
      </p>
      <p :if={@stale_tick == {:stale, nil}} id="schedule-stale-tick">
        {gettext("The scheduler hasn't run yet. Check that background jobs are running.")}
      </p>
      <p :if={@stale_tick == :unknown} id="schedule-tick-unknown">
        {gettext("Couldn't check when the scheduler last ran.")}
      </p>
      <p :if={@media_without_dir?} id="schedule-media-missing">
        {gettext("Media isn't archived on this deployment, so a schedule can't include it.")}
      </p>
      <.held_deleted_warning
        :if={@status.held_deleted != []}
        id="schedule-held-deleted"
        notices={@status.held_deleted}
      />
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :run, :any, required: true, doc: "the newest run, nil, or :unreadable"
  attr :editing?, :boolean, required: true
  attr :form_open?, :boolean, required: true

  defp schedule_card(assigns) do
    assigns = assign(assigns, :schedule, assigns.entry.schedule)

    ~H"""
    <li
      id={"backup-schedule-#{@schedule.id}"}
      class={["space-y-1.5 py-3", @editing? && "bg-base-200/40"]}
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <div class="min-w-0">
          <p class="font-medium" data-role="cadence">{cadence(@schedule)}</p>
          <p class="text-xs text-base-content/70" data-role="components">
            {components_label(@schedule.components)}
          </p>
        </div>
        <div class="text-xs text-base-content/70 sm:text-right">
          <p :if={not @schedule.enabled} data-role="paused">{gettext("Paused")}</p>
          <p :if={@entry.next_at} data-role="next">
            {gettext("Next run: %{when}", when: until(@entry.next_at))}
          </p>
          <p :if={@schedule.last_outcome} data-role="last-outcome">
            {outcome_label(@schedule)}
          </p>
          <p :if={is_struct(@run)} data-role="last-run">
            <%!-- The run's own row in the History, on whichever page holds
                  it (`?run=`, #2875). --%>
            <.link
              navigate={~p"/editor/backups?#{%{run: @run.id}}"}
              class="underline hover:no-underline"
            >
              {gettext("Last scheduled run: %{status} (%{stamp})",
                status: run_status_label(@run.status),
                stamp: stamp(@run.started_at)
              )}
            </.link>
          </p>
          <p :if={is_nil(@run)} data-role="last-run">{gettext("No scheduled run yet")}</p>
        </div>
      </div>

      <p data-role="keep" class="text-xs text-base-content/70">{keep_line(@schedule)}</p>

      <p
        :if={not editable?(@schedule)}
        data-role="locked"
        class="text-xs text-base-content/70"
      >
        {locked_note(locked_reason(@schedule))}
      </p>

      <p
        :if={editable?(@schedule) and needs_keep_days?(@schedule)}
        data-role="needs-keep-days"
        class="text-xs text-warning-ink"
      >
        {gettext(
          "This schedule runs more often than daily without Keep for (days), so its backups are kept for BACKUP_KEEP_DAYS. Set Keep for (days) to edit it; you can still pause, resume or delete it."
        )}
      </p>

      <div class="flex flex-wrap gap-2">
        <button
          :if={editable?(@schedule) and not @form_open?}
          type="button"
          phx-click="edit"
          phx-value-id={@schedule.id}
          data-role="edit"
          class="btn btn-sm btn-ghost"
        >
          <.icon name="hero-pencil-square" class="mr-1 size-4" />
          {gettext("Edit")}
        </button>
        <button
          type="button"
          phx-click="toggle"
          phx-value-id={@schedule.id}
          data-role="toggle"
          class="btn btn-sm btn-ghost"
        >
          {if @schedule.enabled, do: gettext("Pause"), else: gettext("Resume")}
        </button>
        <button
          type="button"
          phx-click="delete"
          phx-value-id={@schedule.id}
          data-role="delete"
          data-confirm={delete_confirm(@schedule)}
          class="btn btn-sm btn-danger"
        >
          {gettext("Delete")}
        </button>
      </div>
    </li>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :editing, :any, required: true
  attr :preview, :any, required: true
  attr :refused_values, :any, required: true, doc: "`refused_rows/2`, or nil"
  attr :media_dir?, :boolean, required: true
  attr :runs_here?, :boolean, required: true

  defp schedule_form(assigns) do
    field = assigns.form[:components]

    assigns =
      assigns
      |> assign(:checked, checked_components(assigns.form))
      |> assign(:sub_daily_hours, sub_daily_hours(assigns.form[:interval].value))
      |> assign(
        :component_errors,
        if(Phoenix.Component.used_input?(field),
          do: Enum.map(field.errors, &translate_error/1),
          else: []
        )
      )

    ~H"""
    <section id="schedule-form-panel" class="rounded-lg border border-base-content/10 p-4 text-sm">
      <h2 class="text-base font-semibold">
        {if @editing == :new, do: gettext("Add a schedule"), else: gettext("Edit schedule")}
      </h2>

      <section
        :if={@refused_values}
        id="schedule-refused-values"
        aria-labelledby="schedule-refused-values-title"
        class="mt-3 rounded border border-warning/30 bg-warning/5 p-3 text-xs"
      >
        <h3 id="schedule-refused-values-title" class="font-medium text-warning-ink">
          {gettext("Not saved: another admin changed this schedule")}
        </h3>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "The form now holds the stored values. What you entered is below; changed fields are marked."
          )}
        </p>
        <table class="mt-2 w-full text-left">
          <thead>
            <tr class="text-base-content/70">
              <th scope="col" class="py-1 pr-3 font-medium">{gettext("Field")}</th>
              <th scope="col" class="py-1 pr-3 font-medium">{gettext("You entered")}</th>
              <th scope="col" class="py-1 font-medium">{gettext("Stored now")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @refused_values}
              data-field={row.field}
              data-differs={row.differs? && "true"}
              class={["border-t border-base-content/10", row.differs? && "font-medium"]}
            >
              <th scope="row" class="py-1 pr-3 font-normal">
                {row.label}
                <span :if={row.differs?} class="ml-1 text-warning-ink" data-role="differs">
                  {gettext("(differs)")}
                </span>
              </th>
              <td class="break-all py-1 pr-3" data-role="yours">{row.yours}</td>
              <td class="break-all py-1" data-role="stored">{row.stored}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <.form
        for={@form}
        id="schedule-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-3 space-y-3"
      >
        <fieldset aria-describedby={@component_errors != [] && "schedule-components-error"}>
          <legend class="mb-1 text-sm font-medium">{gettext("What to back up")}</legend>
          <input type="hidden" name="schedule[components][]" value="" />
          <label class="flex items-center gap-2">
            <input
              type="checkbox"
              id="schedule-components-db"
              name="schedule[components][]"
              value="db"
              checked={"db" in @checked}
              class="size-4 rounded border border-base-content/30 accent-primary"
            />
            {gettext("Database")}
          </label>
          <label class="flex items-center gap-2">
            <input
              type="checkbox"
              id="schedule-components-media"
              name="schedule[components][]"
              value="media"
              checked={@media_dir? and "media" in @checked}
              disabled={not @media_dir?}
              aria-describedby={not @media_dir? && "schedule-media-hint"}
              class="size-4 rounded border border-base-content/30 accent-primary"
            />
            {gettext("Media")}
          </label>
          <p :if={not @media_dir?} id="schedule-media-hint" class="text-xs text-base-content/70">
            {gettext("Media isn't archived on this deployment, so a schedule can't include it.")}
          </p>
          <div :if={@component_errors != []} id="schedule-components-error">
            <p
              :for={message <- @component_errors}
              class="mt-1.5 flex items-center gap-2 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-5" />
              {message}
            </p>
          </div>
        </fieldset>

        <.input
          field={@form[:interval]}
          type="select"
          label={gettext("How often")}
          options={interval_options()}
        />
        <.input
          field={@form[:time_of_day]}
          type="time"
          label={gettext("At")}
          value={hhmm(@form[:time_of_day].value)}
          hint={
            @sub_daily_hours &&
              gettext(
                "One backup at this time, and the others every %{hours} hours around the clock.",
                hours: @sub_daily_hours
              )
          }
        />
        <.input field={@form[:starts_on]} type="date" label={gettext("Starting on")} />
        <.input
          field={@form[:time_zone]}
          type="text"
          label={gettext("Time zone")}
          list="schedule-time-zones"
          autocomplete="off"
        />
        <datalist id="schedule-time-zones">
          <option
            :for={zone <- time_zone_suggestions(to_string(@form[:time_zone].value))}
            value={zone}
          />
        </datalist>
        <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />

        <fieldset id="schedule-keep" class="space-y-2">
          <legend class="mb-1 text-sm font-medium">{gettext("How long to keep its backups")}</legend>
          <p class="text-xs text-base-content/70">
            {gettext(
              "Both are optional. The newest backups are kept however old; the days apply to this schedule's own backups. Whichever keeps more wins."
            )}
          </p>
          <.input
            field={@form[:keep_count]}
            type="number"
            min="1"
            max="1000"
            step="1"
            label={gettext("Keep the newest")}
            hint={gettext("A number of backups of each component, or empty for none.")}
          />
          <.input
            field={@form[:keep_days]}
            type="number"
            min="1"
            max="3650"
            step="1"
            label={gettext("Keep for (days)")}
            required={@sub_daily_hours != nil}
            hint={
              if @sub_daily_hours,
                do: gettext("Required for a schedule that runs more often than daily."),
                else:
                  ngettext(
                    "Empty keeps them for BACKUP_KEEP_DAYS, %{count} day on this deployment.",
                    "Empty keeps them for BACKUP_KEEP_DAYS, %{count} days on this deployment.",
                    Backups.keep_days()
                  )
            }
          />
          <%!-- Always shown (#2931): the keep rules reach host cron only
                through the hold markers, which an older script ignores. --%>
          <p id="schedule-keep-host-hint" class="text-xs text-base-content/70">
            {gettext(
              "If host cron prunes this backup directory, its scripts/backup.sh must be from this release: an older copy deletes the backups these settings keep."
            )}
            <a
              href={docs_url("backups.md#the-hold-markers")}
              target="_blank"
              rel="noopener"
              class="link inline-flex items-center gap-1 text-primary-ink"
            >
              {gettext("About the hold markers")}
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            </a>
          </p>
        </fieldset>

        <div
          :if={@preview}
          id="schedule-preview"
          class="rounded border border-base-content/10 bg-base-200/40 p-3 text-xs"
        >
          <p class="font-medium" data-role="cadence">{@preview.cadence}</p>
          <p
            :if={@preview.enabled? and @runs_here?}
            class="text-base-content/70"
            data-role="first"
          >
            {gettext("Next backup: %{when} (%{at})",
              when: until(@preview.first),
              at: local_stamp(@preview.first, @preview.zone)
            )}
          </p>
          <p :if={not @preview.enabled?} class="text-base-content/70" data-role="wont-run">
            {gettext("It won't run while it's paused.")}
          </p>
          <p
            :if={@preview.enabled? and not @runs_here?}
            class="text-base-content/70"
            data-role="wont-run"
          >
            {gettext("It won't run on this deployment until the warning above is resolved.")}
          </p>
          <p :if={@preview.components != []} class="text-base-content/70" data-role="estimate">
            {ngettext(
              "Keeps about %{count} backup at a time of each of: %{components}.",
              "Keeps about %{count} backups at a time of each of: %{components}.",
              @preview.estimate,
              components: components_label(@preview.components)
            )}
          </p>
          <p :if={@preview.shorter_days} class="text-warning-ink" data-role="keep-shorter">
            {ngettext(
              "This schedule's own backups age out after %{count} day, sooner than BACKUP_KEEP_DAYS (%{default}). Backups made by hand or by the host's cron still keep BACKUP_KEEP_DAYS.",
              "This schedule's own backups age out after %{count} days, sooner than BACKUP_KEEP_DAYS (%{default}). Backups made by hand or by the host's cron still keep BACKUP_KEEP_DAYS.",
              @preview.shorter_days,
              default: Backups.keep_days()
            )}
          </p>
          <p :if={@preview.cron != []} class="text-warning-ink" data-role="keep-cron">
            {gettext(
              "Host cron also backs up %{components} here, and this schedule keeps backups past BACKUP_KEEP_DAYS. Replace the host's scripts/backup.sh with this release's copy first: an older copy deletes them after BACKUP_KEEP_DAYS.",
              components: components_label(@preview.cron)
            )}
          </p>
        </div>

        <div class="flex flex-wrap gap-2">
          <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving…")}>
            {gettext("Save schedule")}
          </button>
          <button type="button" phx-click="cancel" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
        </div>
      </.form>
    </section>
    """
  end
end
