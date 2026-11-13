defmodule KilnCMSWeb.BackupScheduleLive do
  @moduledoc """
  The Schedule tab of the Backups pages (`/editor/backups/schedules`, part of
  #2219): the in-app backup schedules (`KilnCMS.Backups.Schedule`), and the
  forms to add, edit, pause, resume and delete them.

  ## Platform admins only

  A schedule backs up the whole instance, so, as on `KilnCMSWeb.BackupLive`,
  the route's per-org admin gate is not the question: `mount/3`,
  `handle_params/3`, every `handle_event/3` and the refresh ask
  `KilnCMSWeb.LiveUserAuth.platform_admin?/1` again, and every read and write
  goes through the `KilnCMS.Backups` code interfaces as the admin, so the
  schedule's policies decide as well.

  Every handler that names a schedule takes only its **id** from the client
  and reads the schedule again (`Backups.get_backup_schedule/2`): a schedule
  deleted in another tab, or an id that was never one, is a flash, not a
  crash.

  An edit is saved only while the schedule still holds what the form was
  opened on: the editable values are recorded when the form opens, and a save
  after someone else changed any of them (another admin paused it, say) is
  refused with a flash, so a form opened earlier never overwrites the change.
  Only one form is open at a time: while one is, Add and Edit are hidden.

  ## What the form can't offer, it doesn't edit

  The form offers daily, weekly, fortnightly and monthly (sub-daily intervals
  are refused until keep N retention exists), the database, and the media
  when this deployment archives any. A schedule whose stored values fall
  outside that (an interval or component a newer release wrote, which loads
  as `KilnCMS.Types.UnknownAtom`; a sub-daily interval written from a
  console; media on a deployment that no longer has a media directory) is
  shown read-only with a note: it can be paused, resumed or deleted, never
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

  # The intervals the form offers: daily or longer, until keep N (part 3).
  @offered_intervals [:daily, :weekly, :fortnightly, :monthly]

  # The least an enabled schedule may wait for the scheduler's first tick, and
  # how old the last tick may be, before the page says it hasn't run; a
  # coarser KILN_BACKUP_SCHEDULER_CRON stretches it (`stale_after_s/1`).
  @stale_tick_floor_s 300

  # Added to the cron's gap: a tick starts a little after its minute.
  @stale_tick_slack_s 60

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backup schedule"))
       |> assign(:form, nil)
       |> assign(:editing, nil)
       |> assign(:opened_values, nil)
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
      else: {:noreply, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}
  end

  @events ~w(new edit cancel validate save toggle delete)

  # Every event asks again, whatever it is: see the moduledoc. An event this
  # page doesn't have falls to the catch-all every Kiln LiveView gets
  # (`KilnCMSWeb.MalformedEvent`).
  @impl true
  def handle_event(event, params, socket) when event in @events do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: event(event, params, socket),
      else: {:noreply, socket}
  end

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
      {:noreply, socket |> assign(:form, to_form(form)) |> assign(:preview, preview(form))}
    end)
  end

  defp event("save", %{"schedule" => params}, socket) when is_map(params) do
    with_open_form(socket, :save, fn socket, form ->
      case AshPhoenix.Form.submit(form, params: normalize(params)) do
        {:ok, _schedule} ->
          {:noreply,
           socket
           |> close_form()
           |> put_flash(:info, gettext("Schedule saved."))
           |> load()}

        {:error, form} ->
          {:noreply, socket |> assign(:form, to_form(form)) |> assign(:preview, preview(form))}
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
      else: {:noreply, socket}
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
  # the moduledoc). `step` is `:validate` or `:save`.
  defp with_open_form(%{assigns: %{form: nil}} = socket, _step, _fun), do: {:noreply, socket}

  defp with_open_form(%{assigns: %{editing: :new, form: form}} = socket, _step, fun),
    do: fun.(socket, form.source)

  defp with_open_form(%{assigns: %{editing: id}} = socket, step, fun) do
    with_schedule(socket, id, fn schedule ->
      cond do
        not editable?(schedule) ->
          {:noreply, socket |> close_form() |> put_flash(:error, locked_flash())}

        step == :save and editable_values(schedule) != socket.assigns.opened_values ->
          {:noreply, socket |> close_form() |> put_flash(:error, changed_flash()) |> load()}

        true ->
          # Built on the row as stored now (`Rebaseline` compares with it).
          form =
            edit_form(schedule, socket.assigns.current_user, socket.assigns[:security_context])

          fun.(socket, form.source)
      end
    end)
  end

  # What the form edits, as stored: compared on save with what it held when
  # the form opened.
  defp editable_values(%Schedule{} = schedule),
    do:
      Map.take(schedule, [:components, :interval, :time_of_day, :starts_on, :time_zone, :enabled])

  defp open_form(socket, editing, form) do
    socket
    |> assign(:editing, editing)
    |> assign(:form, form)
    |> assign(:preview, preview(form.source))
  end

  defp close_form(socket) do
    socket
    |> assign(:editing, nil)
    |> assign(:form, nil)
    |> assign(:opened_values, nil)
    |> assign(:preview, nil)
  end

  defp close_form_of(%{assigns: %{editing: id}} = socket, id), do: close_form(socket)
  defp close_form_of(socket, _id), do: socket

  defp gone_flash, do: gettext("That schedule no longer exists.")

  defp changed_flash,
    do: gettext("This schedule changed since you opened it. Reopen it to see the current values.")

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
  # every box sends `[]`, which the resource refuses (`min_length`).
  defp normalize(params) do
    case Map.fetch(params, "components") do
      {:ok, list} ->
        Map.put(params, "components", list |> List.wrap() |> Enum.reject(&(&1 == "")))

      :error ->
        params
    end
  end

  @doc false
  # Whether the form can offer every value `schedule` stores (see the
  # moduledoc). Public for the tests.
  @spec editable?(Schedule.t()) :: boolean()
  def editable?(%Schedule{interval: interval, components: components}) do
    interval in @offered_intervals and is_list(components) and
      Enum.all?(components, &(&1 in [:db, :media])) and
      (:media not in components or Backups.media_dir() != nil)
  end

  defp locked_reason(%Schedule{interval: %UnknownAtom{}}), do: :unknown

  defp locked_reason(%Schedule{interval: interval}) when interval not in @offered_intervals,
    do: :sub_daily

  defp locked_reason(%Schedule{components: components}) do
    if Enum.any?(components, &match?(%UnknownAtom{}, &1)), do: :unknown, else: :media
  end

  defp locked_note(:unknown),
    do:
      gettext(
        "A newer release saved this schedule with a value this release doesn't know, so it can't be edited here. You can pause, resume or delete it."
      )

  defp locked_note(:sub_daily),
    do:
      gettext(
        "Schedules more often than daily arrive with keep-N retention, so this one can't be edited here. You can pause, resume or delete it."
      )

  defp locked_note(:media),
    do:
      gettext(
        "This schedule backs up media, which isn't archived on this deployment, so it can't be edited here. You can pause, resume or delete it."
      )

  # The cadence and first window of what the form holds now, and whether it
  # is enabled, or nil while it holds something that has none (an invalid
  # zone, a missing date). Whether it would run here at all is the
  # template's question (`@status`).
  defp preview(%AshPhoenix.Form{source: %Ash.Changeset{} = changeset}) do
    timing =
      Map.new([:interval, :time_of_day, :starts_on, :time_zone], fn field ->
        {field, Ash.Changeset.get_attribute(changeset, field)}
      end)

    now = DateTime.utc_now()

    with %Time{} <- timing.time_of_day,
         %Date{} <- timing.starts_on,
         true <- timing.interval in @offered_intervals,
         true <- KilnCMS.Events.known_time_zone?(timing.time_zone),
         {:ok, %DateTime{} = first} <- Window.next(Map.put(timing, :baseline_at, now), now) do
      %{
        cadence: cadence(timing),
        first: first,
        zone: timing.time_zone,
        enabled?: Ash.Changeset.get_attribute(changeset, :enabled) != false
      }
    else
      _ -> nil
    end
  end

  defp preview(_form), do: nil

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
    |> assign(:stale_tick, stale_tick(status, entries))
  end

  # `{:stale, last_tick_at | nil}` when the scheduler should have ticked and
  # hasn't: it is on, an enabled schedule has existed (since its baseline)
  # for longer than `stale_after_s/1`, and no tick started within it.
  # `:unknown` when that couldn't be read. The `oban_jobs` read
  # (`Scheduler.last_tick_at/0`) is made only when a tick is expected.
  defp stale_tick(%{scheduler_enabled?: true}, entries) do
    now = DateTime.utc_now()
    expected_since = DateTime.add(now, -stale_after_s(now), :second)

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

  defp stale_tick(_status, _entries), do: nil

  # The cron's longest gap between ticks plus a minute's slack, never under
  # five minutes: at `*/10` a seven-minute-old tick is on time.
  defp stale_after_s(now) do
    case Scheduler.tick_gap_s(now) do
      gap when is_integer(gap) -> max(@stale_tick_floor_s, gap + @stale_tick_slack_s)
      nil -> @stale_tick_floor_s
    end
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

  defp interval_options do
    [
      {gettext("Every day"), "daily"},
      {gettext("Every week"), "weekly"},
      {gettext("Every 2 weeks"), "fortnightly"},
      {gettext("Every month"), "monthly"}
    ]
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

  defp delete_confirm do
    days = Backups.keep_days()

    ngettext(
      "Delete this schedule? Backups it already took stay, and age out after %{count} day (BACKUP_KEEP_DAYS).",
      "Delete this schedule? Backups it already took stay, and age out after %{count} days (BACKUP_KEEP_DAYS).",
      days,
      count: days
    )
  end

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
              "Retention is BACKUP_KEEP_DAYS (%{count} day) for every backup.",
              "Retention is BACKUP_KEEP_DAYS (%{count} days) for every backup.",
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
          @media_without_dir?
      }
      class="space-y-2 rounded-lg border border-warning/30 bg-warning/5 p-4 text-sm text-warning-ink"
    >
      <p :if={not @status.scheduler_enabled?} id="schedule-scheduler-off">
        {gettext(
          "The scheduler is turned off on this deployment (KILN_BACKUP_SCHEDULER_CRON), so these schedules don't run."
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
            <.link navigate={~p"/editor/backups"} class="underline hover:no-underline">
              {gettext("Last scheduled run: %{status} (%{stamp})",
                status: run_status_label(@run.status),
                stamp: stamp(@run.started_at)
              )}
            </.link>
          </p>
          <p :if={is_nil(@run)} data-role="last-run">{gettext("No scheduled run yet")}</p>
        </div>
      </div>

      <p
        :if={not editable?(@schedule)}
        data-role="locked"
        class="text-xs text-base-content/70"
      >
        {locked_note(locked_reason(@schedule))}
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
          data-confirm={delete_confirm()}
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
  attr :media_dir?, :boolean, required: true
  attr :runs_here?, :boolean, required: true

  defp schedule_form(assigns) do
    field = assigns.form[:components]

    assigns =
      assigns
      |> assign(:checked, checked_components(assigns.form))
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
