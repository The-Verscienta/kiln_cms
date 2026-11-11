defmodule KilnCMSWeb.BackupLive do
  @moduledoc """
  The backup panel (`/editor/backups`, #484): when the last backup ran, what
  it produced, whether it verified — and a button to take one now.

  **Platform**-admin only, and the distinction is the point (#1160). The route
  carries `:live_admin_required`, which is an *effective per-org* admin tier
  (#419) — but a backup is a `pg_dump` of the whole instance plus a media
  archive, covering every tenant. A per-org admin is the wrong question to ask
  about an instance-wide action, so `mount/3` asks the global one instead, the
  same gate `KilnCMSWeb.SystemLive` uses for a cache flush and for the same
  stated reason.

  `handle_event/3` asks again rather than trusting the mount: a mount guard is
  evaluated once, so an admin whose role is revoked mid-session would otherwise
  keep triggering full-instance backups for as long as the socket lived. Since
  #2218 the requests also carry the admin as the actor (`Backups.request/2`,
  `Backups.cancel_run/2`), so the policies decide as well.

  The artifact list names the database dump; an editor has no reason to see it
  and no action to take on it.

  ## It reports on backups it did not run

  The status comes from `<BACKUP_DIR>/manifest.json`, which cron's
  `scripts/backup.sh` writes too. That is the whole point: the canonical
  backup path is still cron, and a panel that only knew about app-triggered
  runs would show "never" on precisely the deployments that are backing up
  correctly — the most dangerous wrong answer this screen could give.

  ## One line per component (#2219)

  A backup may cover only the database or only the media, so the headline has
  a line for each component this deployment backs up (`Backups.status/0`'s
  `components`), and the tone is alarming when any of them failed or went
  stale. The artifacts and the "Last run failed" box below still show the
  manifest: the last backup, whatever it covered.

  ## History

  Below the panels, `Backups.Run` rows (#2217) list every attempt: the app's own
  and, via `Backups.Importer`, cron's. The importer (and the stale-run sweep it
  starts with) runs once per CONNECTED mount, for a platform admin only, in
  `start_async` - never on the disconnected render, where it would run twice and
  for whoever the request was. The page param is parsed as `AccountsLive` does;
  the rows themselves page with the `:history` read's own offset pagination.
  Whether each run's files are still on disk is computed for the visible page
  only (`Backups.Presence`).

  ## In flight, Cancel and Resume (#2218)

  A backup is a chain of step jobs behind a cluster-wide lock. While one holds
  it, a strip says which step it is on (and which media part of how many), and
  whether another backup is queued behind it; the page polls while that is so.
  "Back up now" stays enabled: a request while one runs queues, and later ones
  fold into the queued one when it is of the same kind (a fresh backup into a
  fresh one, a resume into a resume of the same stamp); a request of another
  kind is refused with a flash to try again once the queue clears (#2540).

  A running in-app backup has a **Cancel** button (on its row and on the strip)
  for a platform admin: `Backups.cancel_run/2`, as that admin, whose policy and
  guard decide (a backup that is finishing can't be canceled). Its files stay.

  A failed, interrupted or canceled in-app run whose `.work/<stamp>/state.json`
  still exists gets a **Resume** button (platform admin only, computed for the
  visible page and bounded by its 25 rows).

  Both handlers re-check `platform_admin?`, take only the run's **id** from the
  client and look the run up themselves; Resume passes THAT run's stamp to
  `Backups.request(resume: stamp)`, which refuses anything that is not
  resumable (a succeeded or still-running run, a forged id, a run whose files
  are gone). The page never sends or trusts a stamp.

  ## Restore is not here

  Deliberately, and the page says so rather than leaving an admin hunting for
  a button that doesn't exist. See `KilnCMS.Backups` and docs/backups.md.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Importer, Manifest, Presence}
  alias KilnCMSWeb.Params

  # The page polls while the backup lock is held (`Backups.in_flight/0`). A
  # multi-GB backup takes a while: 1 200 polls at 3 s is an hour, and the tab
  # stops polling then rather than for as long as it stays open.
  @poll_interval_ms 3_000
  @max_polls 1_200
  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backups"))
       |> assign(:poll_timer, nil)
       |> assign(:polls_left, @max_polls)
       |> assign(:page, 1)
       |> assign(:runs, [])
       |> assign(:run_count, 0)
       |> load_status()
       |> load_in_flight()
       |> poll()
       |> start_import()}
    else
      # Platform-only, which the `:live_admin_required` hook (any site admin)
      # does not enforce. `push_navigate` to the access-denied page (#2143): it
      # ends the LiveView rather than rendering a refusal panel, so nothing below is reachable
      # from this socket. The handler re-checks anyway — see the moduledoc for
      # why that is not redundant.
      {:ok,
       socket
       |> push_navigate(to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  # The route's `?page=`. Re-checked here because `handle_params/3` runs on
  # every patch, long after the mount guard was evaluated.
  @impl true
  def handle_params(params, _uri, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      page = Params.integer(params, "page", 1, 1..100_000)
      socket = socket |> assign(:page, page) |> load_history()

      # Past the last page: land on the last one rather than an empty table.
      case last_page(socket.assigns.run_count) do
        last when page > last ->
          {:noreply, push_patch(socket, to: history_path(last))}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  @impl true
  def handle_event("backup_now", _params, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      start_backup(socket)
    else
      {:noreply, socket}
    end
  end

  # A pushed payload is client-chosen: a non-admin gets nothing, and a mangled
  # one is a no-op (#764).
  def handle_event("page", %{"to" => to}, socket) when is_binary(to) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      page = Params.integer(%{"page" => to}, "page", 1, 1..100_000)
      {:noreply, push_patch(socket, to: history_path(page))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("page", _params, socket), do: {:noreply, socket}

  # Resume: the client names a run by id; the stamp is read from the server's
  # own record of that run, and `Backups.enqueue/1` decides whether it may be
  # resumed. A non-admin, a mangled payload or an unknown id gets nothing.
  def handle_event("resume_run", %{"id" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      resume_backup(socket, id)
    else
      {:noreply, socket}
    end
  end

  def handle_event("resume_run", _params, socket), do: {:noreply, socket}

  # Cancel: as with Resume, the client names a run by id and the server reads
  # the run itself; `Backups.cancel_run/2`'s policy and guard decide.
  def handle_event("cancel_run", %{"id" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      cancel_backup(socket, id)
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_run", _params, socket), do: {:noreply, socket}

  # Through the lock (#2218), as the admin, so the policy decides too: a
  # backup while one runs queues behind it, or folds into a queued fresh one;
  # a queued resume refuses it (#2540).
  defp start_backup(socket) do
    case Backups.request([trigger: "manual"], socket.assigns.current_user) do
      {:ok, %{status: :started}} ->
        {:noreply, watch(socket, gettext("Backup started — this page updates when it finishes."))}

      {:ok, %{status: status}} ->
        {:noreply, watch(socket, queued_message(status, :backup))}

      {:error, {:queue_busy, queued}} ->
        {:noreply, socket |> put_flash(:error, queue_busy_message(:backup, queued)) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, unavailable_message(reason))}
    end
  end

  defp cancel_backup(socket, id) do
    user = socket.assigns.current_user

    with {:ok, run} <- Backups.get_run(id, actor: user),
         {:ok, _canceled} <-
           Backups.cancel_run(run,
             actor: user,
             # The client the `backup_canceled` event is logged with (#2241).
             context: socket.assigns[:security_context] || %{}
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Backup canceled. Its files are kept, so it can be resumed."))
       |> refresh()}
    else
      {:error, error} ->
        {:noreply, socket |> put_flash(:error, cancel_message(error)) |> refresh()}
    end
  end

  defp cancel_message(%Ash.Error.Forbidden{}),
    do: gettext("Only a platform admin can cancel a backup.")

  defp cancel_message(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        gettext("That backup already finished.")

      Enum.any?(errors, &(Exception.message(&1) =~ "too late to cancel")) ->
        gettext("Too late to cancel: the backup is finishing.")

      true ->
        gettext("That backup can't be canceled.")
    end
  end

  defp cancel_message(_error), do: gettext("That backup can't be canceled.")

  defp resume_backup(socket, id) do
    with {:ok, %{stamp: stamp}} <- Backups.get_run(id, actor: socket.assigns.current_user),
         {:ok, outcome} <-
           Backups.request([trigger: "manual", resume: stamp], socket.assigns.current_user) do
      case outcome do
        %{status: :started} ->
          {:noreply,
           watch(socket, gettext("Backup resumed — this page updates when it finishes."))}

        %{status: status} ->
          {:noreply, watch(socket, queued_message(status, :resume))}
      end
    else
      {:error, {:queue_busy, queued}} ->
        {:noreply, socket |> put_flash(:error, queue_busy_message(:resume, queued)) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, resume_message(reason))}
    end
  end

  # The lock is the source of truth for "is a backup running": the strip and
  # the poll follow it, on every node.
  defp watch(socket, message) do
    socket
    |> put_flash(:info, message)
    |> refresh()
  end

  # Re-read what the page shows and (re)start the poll with a fresh budget.
  defp refresh(socket) do
    socket
    |> assign(:polls_left, @max_polls)
    |> load_in_flight()
    |> load_history()
    |> poll()
  end

  defp queued_message(:queued, _asked),
    do: gettext("A backup is running; this one starts when it finishes.")

  # A request folds only into a queued one of its own kind (#2540).
  defp queued_message(:folded, :backup),
    do:
      gettext(
        "A backup is running and another is already queued; that queued backup covers this request."
      )

  defp queued_message(:folded, :resume),
    do:
      gettext(
        "A backup is running and a resume of this backup is already queued; that queued resume covers this request."
      )

  # A request of another kind than the queued one is refused, not folded: the
  # queued one would not do its work (#2540). Nothing was queued.
  defp queue_busy_message(:backup, {:resume, stamp}),
    do:
      gettext(
        "A backup is running and a resume of %{stamp} is queued after it, so this backup was not queued. Try again once the queue clears.",
        stamp: stamp
      )

  defp queue_busy_message(:resume, {:resume, stamp}),
    do:
      gettext(
        "A backup is running and a resume of %{stamp} is queued after it, so this resume was not queued. Try again once the queue clears.",
        stamp: stamp
      )

  defp queue_busy_message(:resume, :backup),
    do:
      gettext(
        "A backup is running and a new backup is queued after it, so this resume was not queued. Try again once the queue clears."
      )

  defp resume_message(:in_flight),
    do: gettext("That backup is running right now.")

  defp resume_message({:not_resumable, _status}),
    do:
      gettext("That backup can't be resumed: only a failed, interrupted or canceled backup can.")

  defp resume_message(reason) when reason in [:no_state, :no_such_run],
    do: gettext("That backup can't be resumed: the files it had written are gone.")

  defp resume_message(reason)
       when reason in [:disabled, :no_database_url, :no_pg_dump, :no_pg_restore],
       do: unavailable_message(reason)

  defp resume_message(_reason), do: gettext("That backup can't be resumed.")

  # One tick: the panel, the strip and the history follow the backup (the new
  # run appears as `running`, then settles, without a reload). Polling stops
  # when the lock is free, or after `@max_polls`.
  @impl true
  def handle_info(:refresh, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      socket =
        socket
        |> assign(:poll_timer, nil)
        |> assign(:polls_left, socket.assigns.polls_left - 1)
        |> assign(:status, Backups.status())
        |> load_in_flight()
        |> load_history()
        |> poll()

      {:noreply, socket}
    else
      {:noreply, assign(socket, :poll_timer, nil)}
    end
  end

  # The import (and the stale sweep inside it) finished: show what it found.
  @impl true
  def handle_async(:import, {:ok, _result}, socket), do: {:noreply, load_history(socket)}

  def handle_async(:import, {:exit, _reason}, socket), do: {:noreply, socket}

  # CONNECTED mounts only: the disconnected render is a throwaway GET that
  # would run the scan a second time. `Importer.run/0` reconciles stale runs
  # itself, never raises, and writes as `Backups.system/0`.
  defp start_import(socket) do
    if connected?(socket),
      do: start_async(socket, :import, fn -> Importer.run() end),
      else: socket
  end

  # The lock as the strip shows it, and the run to cancel from it: the one the
  # lock is writing, when it is running (a starting chain has none yet).
  defp load_in_flight(socket) do
    in_flight = Backups.in_flight()

    run =
      with %{stamp: stamp} when is_binary(stamp) <- in_flight,
           {:ok, %{status: :running, origin: :app} = run} <-
             Backups.get_run_by_stamp(stamp, actor: socket.assigns.current_user) do
        run
      else
        _ -> nil
      end

    socket
    |> assign(:in_flight, in_flight)
    |> assign(:in_flight_run_id, run && run.id)
  end

  defp load_history(socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket),
      do: read_history(socket),
      else: socket
  end

  defp read_history(socket) do
    %{page: page, current_user: user} = socket.assigns

    case Backups.run_history(
           actor: user,
           page: [limit: @per_page, offset: (page - 1) * @per_page, count: true]
         ) do
      {:ok, result} ->
        socket
        |> assign(:runs, with_presence(result.results, user))
        |> assign(:run_count, result.count || 0)

      {:error, _error} ->
        socket
        |> assign(:runs, [])
        |> assign(:run_count, 0)
        |> put_flash(:error, gettext("Couldn't load the backup history."))
    end
  end

  # Stat'ed for the visible page only (<= @per_page rows).
  defp with_presence(runs, user) do
    {dir, now} = {backup_dir(), DateTime.utc_now()}

    for run <- runs do
      {run, Presence.for(run, dir, keep_days(), now), resumable?(run, now),
       cancelable?(run, user)}
    end
  end

  # A running in-app run, and the policy agrees. Whether it is past the point
  # of no return is the action's to say when clicked.
  defp cancelable?(%{status: :running, origin: :app} = run, user),
    do: Backups.can_cancel_run?(user, run)

  defp cancelable?(_run, _user), do: false

  # A cheap status check first, so the one `stat` per row is only paid by the
  # (few) failed or running rows of the page.
  defp resumable?(run, now),
    do: Backups.run_resumable?(run, now) and Backups.work_state?(run.stamp)

  defp last_page(count), do: max(div(count + @per_page - 1, @per_page), 1)

  defp history_path(1), do: ~p"/editor/backups"
  defp history_path(page), do: ~p"/editor/backups?#{%{page: page}}"

  defp load_status(socket), do: assign(socket, :status, Backups.status())

  # Polling rather than PubSub: a backup runs every few hours at most, so one
  # timer on an open admin page is cheaper than a topic, a broadcast and a
  # subscription that exist for this one screen. One timer at a time, and only
  # while the lock is held.
  defp poll(%{assigns: %{poll_timer: ref}} = socket) when is_reference(ref), do: socket

  defp poll(socket) do
    if connected?(socket) and socket.assigns.in_flight != nil and
         socket.assigns.polls_left > 0 do
      assign(socket, :poll_timer, Process.send_after(self(), :refresh, @poll_interval_ms))
    else
      socket
    end
  end

  defp unavailable_message(:disabled),
    do: gettext("In-app backups are turned off (BACKUP_ENABLED).")

  defp unavailable_message(:no_database_url),
    do: gettext("No database connection is configured for backups.")

  defp unavailable_message(reason) when reason in [:no_pg_dump, :no_pg_restore],
    do:
      gettext(
        "PostgreSQL client tools aren't installed in this image, so a backup can't run here. Cron backups on the host are unaffected."
      )

  defp unavailable_message(_reason), do: gettext("A backup can't run on this deployment.")

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `current_org` was the one console call site not passing it (#1320):
          the top bar's bell scopes its rows by tenant, so a page that omitted
          it would read this admin's notifications across every site. --%>
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:backups}
    >
      <div class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold">{gettext("Backups")}</h1>
            <p class="mt-1 text-sm text-base-content/70">
              {gettext("The database and, on local storage, your uploaded media.")}
            </p>
          </div>

          <%!-- Enabled while a backup runs: a request then queues behind it.
                `phx-disable-with` stops a double click asking twice. --%>
          <button
            type="button"
            phx-click="backup_now"
            phx-disable-with={gettext("Requesting…")}
            disabled={not @status.available?}
            title={not @status.available? && unavailable_message(@status.reason)}
            class="btn btn-primary"
          >
            {gettext("Back up now")}
          </button>
        </div>

        <.in_flight :if={@in_flight} in_flight={@in_flight} run_id={@in_flight_run_id} />

        <%!-- The headline. Stale (or never) is an error tone on purpose: a
              deployment that has not been backed up is the state this whole
              page exists to make impossible to miss. --%>
        <section class={[
          "rounded-lg border p-4",
          if(alarming?(@status),
            do: "border-error/30 bg-error/5",
            else: "border-success/30 bg-success/5"
          )
        ]}>
          <div class="flex items-start gap-3">
            <.icon
              name={if alarming?(@status), do: "hero-exclamation-triangle", else: "hero-check-circle"}
              class={[
                "mt-0.5 size-5 shrink-0",
                if(alarming?(@status), do: "text-error", else: "text-success")
              ]}
            />
            <div class="min-w-0 flex-1">
              <p
                :for={component <- @status.expected}
                id={"backup-headline-#{component}"}
                class="font-medium"
              >
                <span class="text-base-content/70">{component_label(component)}:</span>
                {headline(@status.components[component])}
              </p>
              <p
                :if={@status.manifest && @status.manifest.artifacts != []}
                class="mt-1 text-sm text-base-content/70"
              >
                {summary(@status.manifest)}
              </p>
              <p :if={is_nil(@status.manifest)} class="mt-1 text-sm text-base-content/70">
                {gettext(
                  "Nothing has written %{path} yet. Either no backup has run, or it writes somewhere else.",
                  path: Manifest.path(backup_dir())
                )}
              </p>
            </div>
          </div>
        </section>

        <%!-- A failed run keeps its own error visible. Showing the previous
              SUCCESSFUL backup instead would be true and would answer a
              question nobody asked. --%>
        <section
          :if={@status.manifest && @status.manifest.error}
          class="rounded-lg border border-error/30 bg-error/5 p-4"
        >
          <p class="text-sm font-medium text-error">{gettext("Last run failed")}</p>
          <pre class="mt-2 overflow-x-auto whitespace-pre-wrap break-words text-xs text-base-content/80">{@status.manifest.error}</pre>
        </section>

        <section
          :if={@status.manifest && @status.manifest.artifacts != []}
          class="rounded-lg border border-base-content/10 p-4"
        >
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {gettext("Artifacts")}
          </h2>
          <ul class="mt-3 space-y-2">
            <li
              :for={artifact <- @status.manifest.artifacts}
              class="flex items-center gap-3 text-sm"
            >
              <.icon
                name={if artifact.kind == "db", do: "hero-circle-stack", else: "hero-photo"}
                class="size-4 shrink-0 text-base-content/60"
              />
              <span class="min-w-0 flex-1 truncate font-mono text-xs">{artifact.path}</span>
              <span class="shrink-0 tabular-nums text-base-content/70">
                {humanize_bytes(artifact.bytes)}
              </span>
              <span
                :if={artifact.verified}
                class="shrink-0 rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-success-ink"
                title={gettext("Listed with pg_restore after writing, so it is a real backup")}
              >
                {gettext("Verified")}
              </span>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-base-content/10 p-4 text-sm">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {gettext("Where backups go")}
          </h2>
          <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
            <dt class="text-base-content/60">{gettext("Directory")}</dt>
            <dd class="font-mono text-xs">{backup_dir()}</dd>
            <dt class="text-base-content/60">{gettext("Media")}</dt>
            <dd class="font-mono text-xs">
              {media_dir() || gettext("not archived — object storage is backed up by the provider")}
            </dd>
            <dt class="text-base-content/60">{gettext("Retention")}</dt>
            <dd>{ngettext("%{count} day", "%{count} days", keep_days(), count: keep_days())}</dd>
            <dt :if={@status.manifest && @status.manifest.offsite} class="text-base-content/60">
              {gettext("Off-site")}
            </dt>
            <dd :if={@status.manifest && @status.manifest.offsite} class="font-mono text-xs">
              {KilnCMS.Backups.Redact.text(@status.manifest.offsite)}
            </dd>
            <dt
              :if={@status.rclone_missing? && !(@status.manifest && @status.manifest.offsite)}
              class="text-base-content/70"
            >
              {gettext("Off-site")}
            </dt>
            <dd
              :if={@status.rclone_missing?}
              id="backup-rclone-missing"
              class={[
                "text-xs text-warning-ink",
                @status.manifest && @status.manifest.offsite && "col-start-2"
              ]}
            >
              <span class="font-mono">{KilnCMS.Backups.Redact.text(rclone_remote())}</span>
              — {gettext(
                "rclone is not installed in this image, so backups taken from this page are not copied off-site."
              )}
            </dd>
          </dl>

          <p class="mt-4 text-xs text-base-content/60">
            {gettext(
              "Restoring is a documented operations procedure, not a button here — see docs/backups.md. Secrets (SECRET_KEY_BASE above all) are not in these files and must be kept separately."
            )}
          </p>
        </section>

        <.history runs={@runs} page={@page} run_count={@run_count} in_flight={@in_flight} />
      </div>
    </Layouts.console>
    """
  end

  attr :in_flight, :map, required: true
  attr :run_id, :string, default: nil

  # The running backup: its step, the part of how many, the queued request.
  defp in_flight(assigns) do
    ~H"""
    <section
      id="backup-in-flight"
      class="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-lg border border-info/30 bg-info/5 p-4 text-sm"
    >
      <.icon name="hero-arrow-path" class="size-5 shrink-0 text-info motion-safe:animate-spin" />
      <div class="min-w-0 flex-1 space-y-0.5">
        <p class="font-medium" data-role="step">{step_label(@in_flight)}</p>
        <p :if={@in_flight.stamp} class="font-mono text-xs text-base-content/70">
          {@in_flight.stamp}
        </p>
        <p :if={@in_flight.waiting} data-role="queued" class="text-xs text-base-content/70">
          {queued_label(@in_flight.waiting)}
          <span :if={is_nil(@in_flight.waiting.resume)} data-role="queued-components">
            · {components_label(@in_flight.waiting.components)}
          </span>
        </p>
      </div>
      <button
        :if={@run_id && @in_flight.phase != :finishing}
        type="button"
        phx-click="cancel_run"
        phx-value-id={@run_id}
        phx-disable-with={gettext("Canceling…")}
        data-role="cancel"
        data-confirm={cancel_confirm(@in_flight)}
        class="btn btn-sm btn-danger"
      >
        <.icon name="hero-stop-circle" class="mr-1 size-4" />
        {gettext("Cancel")}
      </button>
    </section>
    """
  end

  defp step_label(%{step: :archive, part: part, parts_total: total})
       when is_integer(part) and is_integer(total),
       do: gettext("Archiving media: part %{part} of %{total}", part: part, total: total)

  defp step_label(%{step: :archive, part: part}) when is_integer(part),
    do: gettext("Archiving media: part %{part}", part: part)

  defp step_label(%{step: step}) do
    case step do
      :dump -> gettext("Dumping the database")
      :plan -> gettext("Planning the media archive")
      :archive -> gettext("Archiving media")
      :checksum -> gettext("Checking the media parts")
      :prune -> gettext("Applying retention")
      :offsite -> gettext("Copying off-site")
      :finish -> gettext("Finishing")
      _start -> gettext("Starting a backup")
    end
  end

  defp queued_label(%{requested_at: at, folds: folds}) do
    queued =
      gettext("1 queued (requested %{at})", at: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC"))

    case folds do
      n when is_integer(n) and n > 0 ->
        queued <>
          " · " <>
          ngettext(
            "%{count} later request folded into it",
            "%{count} later requests folded into it",
            n
          )

      _ ->
        queued
    end
  end

  # A queued fresh backup's components (#2219); nil is everything this
  # deployment backs up.
  defp components_label(components) do
    Enum.map_join(components || Backups.expected_components(), " + ", &component_label/1)
  end

  defp cancel_confirm(%{waiting: nil}),
    do: gettext("Cancel this backup? Its files are kept, so it can be resumed later.")

  defp cancel_confirm(_in_flight),
    do:
      gettext(
        "Cancel this backup? Its files are kept, so it can be resumed later. A queued backup will start next."
      )

  attr :runs, :list, required: true
  attr :page, :integer, required: true
  attr :run_count, :integer, required: true
  attr :in_flight, :map, default: nil

  defp history(assigns) do
    assigns = assign(assigns, :last_page, last_page(assigns.run_count))

    ~H"""
    <section id="backup-history" class="rounded-lg border border-base-content/10 p-4">
      <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
        {gettext("History")}
      </h2>

      <p :if={@runs == []} id="backup-history-empty" class="mt-3 text-sm text-base-content/70">
        {gettext("No backups have been recorded yet.")}
      </p>

      <ul :if={@runs != []} class="mt-3 divide-y divide-base-content/10">
        <li
          :for={{run, presence, resumable?, cancelable?} <- @runs}
          id={"backup-run-#{run.id}"}
          class="space-y-1.5 py-3 text-sm"
        >
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span class="font-medium tabular-nums">
              {Calendar.strftime(run.started_at, "%Y-%m-%d %H:%M UTC")}
            </span>
            <span class="text-xs text-base-content/70">{run.trigger}</span>
            <span
              data-role="status"
              class={[
                "rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase",
                status_class(run.status)
              ]}
            >
              {status_label(run.status)}
            </span>
            <span
              :for={component <- run.components}
              data-role="component"
              class="rounded bg-base-content/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-base-content/70"
            >
              {component_label(component)}
            </span>
            <span class="ml-auto tabular-nums text-base-content/70">
              {humanize_bytes(total_bytes(run))}
            </span>
          </div>

          <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
            <span data-role="verified">{verified_label(run)}</span>
            <span :for={count <- part_counts(run)} data-role="parts">
              {ngettext("%{count} part", "%{count} parts", count)}
            </span>
            <span
              :for={{label, status} <- destination_chips(run)}
              data-role="destination"
              class="rounded border border-base-content/20 px-1.5 py-0.5 font-mono"
            >
              {label} · {destination_status_label(status)}
            </span>
            <span :if={presence != :none} data-role="presence" data-presence={presence}>
              {presence_label(presence)}
            </span>
            <button
              :if={cancelable?}
              type="button"
              phx-click="cancel_run"
              phx-value-id={run.id}
              phx-disable-with={gettext("Canceling…")}
              data-role="cancel"
              data-confirm={cancel_confirm(@in_flight || %{waiting: nil})}
              class="btn btn-sm btn-danger ml-auto"
            >
              <.icon name="hero-stop-circle" class="mr-1 size-4" />
              {gettext("Cancel")}
            </button>
            <button
              :if={resumable?}
              type="button"
              phx-click="resume_run"
              phx-value-id={run.id}
              phx-disable-with={gettext("Requesting…")}
              data-role="resume"
              title={gettext("Continue this backup from the files it already wrote")}
              class="btn btn-sm btn-default ml-auto"
            >
              <.icon name="hero-arrow-path" class="mr-1 size-4" />
              {gettext("Resume")}
            </button>
          </div>

          <pre
            :if={run.error}
            class="overflow-x-auto whitespace-pre-wrap break-words text-xs text-base-content/80"
          >{run.error}</pre>
        </li>
      </ul>

      <div :if={@page > 1 || @page < @last_page} class="mt-4 flex items-center justify-between">
        <button
          type="button"
          phx-click="page"
          phx-value-to={@page - 1}
          disabled={@page == 1}
          class="btn btn-sm btn-default disabled:opacity-40"
        >
          {gettext("Previous")}
        </button>
        <span class="text-sm text-base-content/70">
          {gettext("Page %{page} of %{last}", page: @page, last: @last_page)}
        </span>
        <button
          type="button"
          phx-click="page"
          phx-value-to={@page + 1}
          disabled={@page >= @last_page}
          class="btn btn-sm btn-default disabled:opacity-40"
        >
          {gettext("Next")}
        </button>
      </div>
    </section>
    """
  end

  # The artifact's bytes are already the sum of its parts (#2218).
  defp total_bytes(run), do: Enum.reduce(run.artifacts, 0, &(&1.bytes + &2))

  # One entry per media set written in several parts.
  defp part_counts(run) do
    for %{parts: [_, _ | _] = parts} <- run.artifacts, do: length(parts)
  end

  defp status_class(:succeeded), do: "bg-success/15 text-success-ink"
  defp status_class(:failed), do: "bg-error/15 text-error-ink"
  defp status_class(:running), do: "bg-info/15 text-info-ink"
  defp status_class(:skipped), do: "bg-warning/15 text-warning-ink"
  defp status_class(:canceled), do: "bg-base-content/10 text-base-content/70"

  defp status_label(:succeeded), do: gettext("Succeeded")
  defp status_label(:failed), do: gettext("Failed")
  defp status_label(:running), do: gettext("Running")
  defp status_label(:skipped), do: gettext("Skipped")
  defp status_label(:canceled), do: gettext("Canceled")

  defp component_label(:db), do: gettext("Database")
  defp component_label(:media), do: gettext("Media")

  defp verified_label(%{artifacts: []}), do: "—"

  defp verified_label(%{artifacts: artifacts, origin: origin}) do
    cond do
      Enum.all?(artifacts, & &1.verified) -> gettext("Verified")
      origin == :imported -> gettext("unverified (imported)")
      true -> gettext("Not verified")
    end
  end

  # One chip per destination across the run's artifacts, worst status wins, so
  # a single failed copy is not hidden behind the others' success.
  defp destination_chips(run) do
    run.artifacts
    |> Enum.flat_map(&Enum.map(&1.destinations, fn {key, value} -> {key, value["status"]} end))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {key, _} -> {key != "local", key} end)
    |> Enum.map(fn {key, statuses} -> {destination_label(key), worst(statuses)} end)
  end

  defp destination_label("local"), do: gettext("Local")
  defp destination_label("rclone:" <> remote), do: remote
  defp destination_label(other), do: other

  defp worst(statuses) do
    Enum.find(["failed", "pending", "pruned"], &(&1 in statuses)) || "ok"
  end

  defp destination_status_label("ok"), do: gettext("ok")
  defp destination_status_label("failed"), do: gettext("failed")
  defp destination_status_label("pending"), do: gettext("pending")
  defp destination_status_label("pruned"), do: gettext("pruned")
  defp destination_status_label(_other), do: "—"

  defp presence_label(:present), do: gettext("on disk")
  defp presence_label(:missing), do: gettext("missing")
  defp presence_label(:pruned), do: gettext("pruned (retention)")
  defp presence_label(:partly_pruned), do: gettext("partly pruned (retention)")
  defp presence_label(:expired), do: gettext("expired")
  defp presence_label(:off_site_only), do: gettext("off-site only")

  # NOT just `stale?`. A backup that failed a minute ago is not stale — it is
  # recent and it is worthless — and tone driven by age alone rendered "The
  # last backup failed" with a green tick and a success border. Any component
  # (#2219): a fresh database backup doesn't make stale media fine.
  defp alarming?(status), do: status.stale? or status.failed?

  # One component's line (#2219).
  defp headline(%{failed?: true}), do: gettext("The last backup failed")

  defp headline(%{last_good: %{at: at}, stale?: true}),
    do: gettext("Last backup was %{ago} ago", ago: ago(at))

  defp headline(%{last_good: %{at: at}}), do: gettext("Backed up %{ago} ago", ago: ago(at))

  defp headline(_never), do: gettext("No backup has ever been recorded")

  defp summary(%Manifest{} = manifest) do
    gettext("%{size} · %{count} file(s) · %{trigger}",
      size: humanize_bytes(Manifest.total_bytes(manifest)),
      count: length(manifest.artifacts),
      trigger: manifest.trigger
    )
  end

  # Coarse on purpose: "3 days" is the fact an admin acts on, and a precise
  # duration invites reading it as a schedule.

  defp humanize_bytes(b) when not is_integer(b) or b < 0, do: "—"
  defp humanize_bytes(b) when b < 1_024, do: "#{b} B"
  defp humanize_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1_024, 1)} KB"
  defp humanize_bytes(b) when b < 1_073_741_824, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp humanize_bytes(b), do: "#{Float.round(b / 1_073_741_824, 2)} GB"

  defp backup_dir, do: Backups.dir()
  defp media_dir, do: Backups.media_dir()
  defp keep_days, do: Backups.keep_days()
  defp rclone_remote, do: Backups.rclone_remote()
end
