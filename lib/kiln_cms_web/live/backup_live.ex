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

  `handle_event/3` asks again rather than trusting the mount. Two reasons, both
  of which the sibling console already documents: `Backups.enqueue/1` takes no
  actor and authorizes nothing, so a mount-guard mistake has no policy behind it
  to catch it; and a mount guard is evaluated once, so an admin whose role is
  revoked mid-session would otherwise keep triggering full-instance backups for
  as long as the socket lived.

  The artifact list names the database dump; an editor has no reason to see it
  and no action to take on it.

  ## It reports on backups it did not run

  The status comes from `<BACKUP_DIR>/manifest.json`, which cron's
  `scripts/backup.sh` writes too. That is the whole point: the canonical
  backup path is still cron, and a panel that only knew about app-triggered
  runs would show "never" on precisely the deployments that are backing up
  correctly — the most dangerous wrong answer this screen could give.

  ## History

  Below the panels, `Backups.Run` rows (#2217) list every attempt: the app's own
  and, via `Backups.Importer`, cron's. The importer (and the stale-run sweep it
  starts with) runs once per CONNECTED mount, for a platform admin only, in
  `start_async` - never on the disconnected render, where it would run twice and
  for whoever the request was. The page param is parsed as `AccountsLive` does;
  the rows themselves page with the `:history` read's own offset pagination.
  Whether each run's files are still on disk is computed for the visible page
  only (`Backups.Presence`).

  ## Resume (#2218)

  A failed or interrupted in-app run whose `.work/<stamp>/state.json` still
  exists gets a **Resume** button (platform admin only, computed for the visible
  page and bounded by its 25 rows). The `resume_run` handler re-checks
  `platform_admin?`, takes only the run's **id** from the client, looks the run
  up itself and passes ITS stamp to `Backups.enqueue(resume: stamp)`, which
  refuses anything that is not resumable (a succeeded or still-running run, a
  forged id, a run whose files are gone). The page never sends or trusts a stamp.

  ## Restore is not here

  Deliberately, and the page says so rather than leaving an admin hunting for
  a button that doesn't exist. See `KilnCMS.Backups` and docs/backups.md.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Importer, Manifest, Presence}
  alias KilnCMSWeb.Params

  # A backup takes minutes; 200 polls at 3s is ten of them, comfortably past
  # any real run and finite when a run never reports back at all.
  @poll_interval_ms 3_000
  @max_polls 200
  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backups"))
       |> assign(:running?, false)
       |> assign(:polls_left, @max_polls)
       |> assign(:page, 1)
       |> assign(:runs, [])
       |> assign(:run_count, 0)
       |> load_status()
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

  defp start_backup(socket) do
    case Backups.enqueue(trigger: :manual) do
      {:ok, _job} ->
        {:noreply, watch(socket, gettext("Backup started — this page updates when it finishes."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, unavailable_message(reason))}
    end
  end

  defp resume_backup(socket, id) do
    with {:ok, %{stamp: stamp}} <- Backups.get_run(id, actor: socket.assigns.current_user),
         {:ok, _job} <- Backups.enqueue(trigger: :manual, resume: stamp) do
      {:noreply, watch(socket, gettext("Backup resumed — this page updates when it finishes."))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, resume_message(reason))}
    end
  end

  # `running?` is optimistic and local to this session: the job is on a queue
  # with a concurrency of one, and the manifest is the source of truth once it
  # lands. A spinner that lies for a few seconds is better than a button that
  # looks like it did nothing for a minute.
  defp watch(socket, message) do
    socket
    |> assign(:running?, true)
    # Captured HERE, not at mount: on a page left open for an hour, a cron
    # backup that landed in the meantime would otherwise satisfy
    # `finished_since?/2` on the first tick and be reported as the result of
    # this click.
    |> assign(:since, DateTime.utc_now())
    |> assign(:polls_left, @max_polls)
    |> put_flash(:info, message)
    |> schedule_refresh()
  end

  defp resume_message({:not_resumable, _status}),
    do: gettext("That backup can't be resumed: only a failed or interrupted backup can.")

  defp resume_message(reason) when reason in [:no_state, :no_such_run],
    do: gettext("That backup can't be resumed: the files it had written are gone.")

  defp resume_message(reason)
       when reason in [:disabled, :no_database_url, :no_pg_dump, :no_pg_restore],
       do: unavailable_message(reason)

  defp resume_message(_reason), do: gettext("That backup can't be resumed.")

  @impl true
  def handle_info(:refresh, socket) do
    status = Backups.status()
    polls_left = socket.assigns.polls_left - 1

    # Give up after `@max_polls`, not only when the manifest updates. A job
    # that never writes one — killed by Oban's timeout, lost to a node
    # restart, or unable to write the file — would otherwise leave the tab
    # polling every few seconds for as long as it stayed open.
    running? =
      socket.assigns.running? and polls_left > 0 and
        not finished_since?(status, socket.assigns.since)

    socket =
      socket
      |> assign(:status, status)
      |> assign(:running?, running?)
      |> assign(:polls_left, polls_left)

    # The history follows the poll: the new run appears as `running`, then
    # settles, without a reload.
    socket = load_history(socket)

    {:noreply, if(running?, do: schedule_refresh(socket), else: socket)}
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
        |> assign(:runs, with_presence(result.results))
        |> assign(:run_count, result.count || 0)

      {:error, _error} ->
        socket
        |> assign(:runs, [])
        |> assign(:run_count, 0)
        |> put_flash(:error, gettext("Couldn't load the backup history."))
    end
  end

  # Stat'ed for the visible page only (<= @per_page rows).
  defp with_presence(runs) do
    {dir, now} = {backup_dir(), DateTime.utc_now()}
    for run <- runs, do: {run, Presence.for(run, dir, keep_days(), now), resumable?(run, now)}
  end

  # A cheap status check first, so the one `stat` per row is only paid by the
  # (few) failed or running rows of the page.
  defp resumable?(run, now),
    do: Backups.run_resumable?(run, now) and Backups.work_state?(run.stamp)

  defp last_page(count), do: max(div(count + @per_page - 1, @per_page), 1)

  defp history_path(1), do: ~p"/editor/backups"
  defp history_path(page), do: ~p"/editor/backups?#{%{page: page}}"

  defp load_status(socket) do
    socket
    |> assign(:status, Backups.status())
    |> assign(:since, DateTime.utc_now())
  end

  # Polling rather than PubSub: a backup runs every few hours at most and
  # finishes in minutes, so one timer on an open admin page is cheaper than a
  # topic, a broadcast and a subscription that exist for this one screen.
  defp schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_interval_ms)
    socket
  end

  defp finished_since?(%{manifest: %Manifest{finished_at: %DateTime{} = at}}, since),
    do: DateTime.compare(at, since) != :lt

  defp finished_since?(_status, _since), do: false

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

          <button
            type="button"
            phx-click="backup_now"
            disabled={not @status.available? or @running?}
            title={not @status.available? && unavailable_message(@status.reason)}
            class="btn btn-primary"
          >
            <.icon
              :if={@running?}
              name="hero-arrow-path"
              class="mr-1 size-4 motion-safe:animate-spin"
            />
            {if @running?, do: gettext("Backing up…"), else: gettext("Back up now")}
          </button>
        </div>

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
              <p class="font-medium">{headline(@status)}</p>
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
          </dl>

          <p class="mt-4 text-xs text-base-content/60">
            {gettext(
              "Restoring is a documented operations procedure, not a button here — see docs/backups.md. Secrets (SECRET_KEY_BASE above all) are not in these files and must be kept separately."
            )}
          </p>
        </section>

        <.history runs={@runs} page={@page} run_count={@run_count} running?={@running?} />
      </div>
    </Layouts.console>
    """
  end

  attr :runs, :list, required: true
  attr :page, :integer, required: true
  attr :run_count, :integer, required: true
  attr :running?, :boolean, default: false

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
          :for={{run, presence, resumable?} <- @runs}
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
              :if={resumable?}
              type="button"
              phx-click="resume_run"
              phx-value-id={run.id}
              disabled={@running?}
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

  defp status_label(:succeeded), do: gettext("Succeeded")
  defp status_label(:failed), do: gettext("Failed")
  defp status_label(:running), do: gettext("Running")
  defp status_label(:skipped), do: gettext("Skipped")

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
  defp presence_label(:expired), do: gettext("expired")
  defp presence_label(:off_site_only), do: gettext("off-site only")

  # NOT just `stale?`. A backup that failed a minute ago is not stale — it is
  # recent and it is worthless — and tone driven by age alone rendered "The
  # last backup failed" with a green tick and a success border.
  defp alarming?(%{stale?: true}), do: true
  defp alarming?(%{manifest: %Manifest{ok: false}}), do: true
  defp alarming?(_status), do: false

  defp headline(%{manifest: nil}), do: gettext("No backup has ever been recorded")

  defp headline(%{manifest: %Manifest{ok: false}}), do: gettext("The last backup failed")

  defp headline(%{stale?: true, manifest: %Manifest{finished_at: at}}),
    do: gettext("Last backup was %{ago} ago", ago: ago(at))

  defp headline(%{manifest: %Manifest{finished_at: at}}),
    do: gettext("Backed up %{ago} ago", ago: ago(at))

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
end
