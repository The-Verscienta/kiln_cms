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

  ## Restore is not here

  Deliberately, and the page says so rather than leaving an admin hunting for
  a button that doesn't exist. See `KilnCMS.Backups` and docs/backups.md.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Manifest

  # A backup takes minutes; 200 polls at 3s is ten of them, comfortably past
  # any real run and finite when a run never reports back at all.
  @poll_interval_ms 3_000
  @max_polls 200

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backups"))
       |> assign(:running?, false)
       |> assign(:polls_left, @max_polls)
       |> load_status()}
    else
      # `push_navigate`, matching the admin siblings: it ends the LiveView
      # rather than rendering a refusal panel, so nothing below is reachable
      # from this socket. The handler re-checks anyway — see the moduledoc for
      # why that is not redundant.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
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

  defp start_backup(socket) do
    case Backups.enqueue(trigger: :manual) do
      {:ok, _job} ->
        # `running?` is optimistic and local to this session: the job is on a
        # queue with a concurrency of one, and the manifest is the source of
        # truth once it lands. A spinner that lies for a few seconds is
        # better than a button that looks like it did nothing for a minute.
        {:noreply,
         socket
         |> assign(:running?, true)
         # Captured HERE, not at mount: on a page left open for an hour, a
         # cron backup that landed in the meantime would otherwise satisfy
         # `finished_since?/2` on the first tick and be reported as the result
         # of this click.
         |> assign(:since, DateTime.utc_now())
         |> assign(:polls_left, @max_polls)
         |> put_flash(:info, gettext("Backup started — this page updates when it finishes."))
         |> schedule_refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, unavailable_message(reason))}
    end
  end

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

    {:noreply, if(running?, do: schedule_refresh(socket), else: socket)}
  end

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
    <Layouts.console flash={@flash} current_user={@current_user} active={:backups}>
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
              {@status.manifest.offsite}
            </dd>
          </dl>

          <p class="mt-4 text-xs text-base-content/60">
            {gettext(
              "Restoring is a documented operations procedure, not a button here — see docs/backups.md. Secrets (SECRET_KEY_BASE above all) are not in these files and must be kept separately."
            )}
          </p>
        </section>
      </div>
    </Layouts.console>
    """
  end

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
