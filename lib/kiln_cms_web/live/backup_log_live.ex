defmodule KilnCMSWeb.BackupLogLive do
  @moduledoc """
  The Log tab of the Backups pages (`/editor/backups/log`, part of #2230 and
  #2231): what each step of one backup run recorded, filtered by level, with
  the log as a text download (`KilnCMSWeb.BackupLogController`).

  ## Who

  A backup covers the whole instance, so, as on `KilnCMSWeb.BackupLive`,
  `mount/3`, `handle_params/3`, the one `handle_event/3` and the poll ask
  `KilnCMSWeb.LiveUserAuth.platform_admin?/1` again: a user demoted, or whose
  grant expired, since the mount is sent to the access-denied page. Every
  read goes through the `KilnCMS.Backups` code interfaces as the admin, so
  the Run policy decides as well.

  ## Not while the console shares an origin

  A run's log names destinations, hosts, paths and timings across every
  organization's backups. While the console shares its address with several
  organizations' sites (`Backups.download_refusal/0`, which fails closed),
  the page reads no run at all and shows a note instead; it asks again on
  every patch and every poll, so a verdict that changes mid-session hides
  the log at the next one. The History page's "View log" links still lead
  here, to the note.

  ## Which run

  `?run=<id>` names it; the id is only looked up, as the admin, and one that
  isn't a UUID, isn't a run or can't be read is a flash, then the default:
  the run the backup lock holds (`KilnCMS.Backups.Chain.fetch_held_stamp/0`),
  else the newest. The picker offers the newest 25 runs, plus the one shown
  when it is older. `?level=` is `all` (the default), `warn` or `error`.

  ## What it shows

  `KilnCMS.Backups.LogText` decides: each message is redacted again with
  the secrets known now and stripped of the characters a terminal would act
  on, and the `truncated` marker is shown at every level. Lines appear at
  step boundaries, when the step writes the run. While the run is running
  (or the lock holds its stamp) the page re-reads it every 3 s, one timer at
  a time, and stops once it has finished; the picker is read again with it,
  so a run that finished meanwhile isn't still labelled Running. After 1 200
  polls (an hour) it stops and says so, and a reload starts it again. A run's
  trigger is operator text, so it is redacted again and sanitized wherever
  it is shown (`LogText.trigger/2`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, Log, LogText, Run}
  alias KilnCMSWeb.Params

  import KilnCMSWeb.BackupComponents,
    only: [tabs: 1, component_label: 1, run_status_label: 1]

  @poll_interval_ms 3_000
  @max_polls 1_200
  @picker_size 25
  @levels %{"all" => :all, "warn" => :warn, "error" => :error}

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Backup log"))
       |> assign(:refusal, nil)
       |> assign(:run, nil)
       |> assign(:options, [])
       |> assign(:level, :all)
       |> assign(:entries, [])
       |> assign(:counts, %{all: 0, warn: 0, error: 0})
       |> assign(:error, nil)
       |> assign(:live?, false)
       |> assign(:stopped?, false)
       |> assign(:trigger, nil)
       |> assign(:poll_ref, nil)
       |> assign(:polls_left, @max_polls)}
    else
      {:ok, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  # Re-checked here because `handle_params/3` runs on every patch, long after
  # the mount guard was evaluated.
  @impl true
  def handle_params(params, _uri, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      level = Map.get(@levels, Params.string(params, "level"), :all)
      socket = socket |> assign(:level, level) |> assign(:polls_left, @max_polls)

      case Backups.download_refusal() do
        nil -> {:noreply, socket |> load(Params.string(params, "run")) |> poll()}
        refusal -> {:noreply, refuse(socket, refusal)}
      end
    else
      deny(socket)
    end
  end

  # A user who stopped being a platform admin mid-session is sent where the
  # mount would have sent them. Nothing is read first.
  defp deny(socket),
    do: {:noreply, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}

  # The picker: only the run's id comes from the client, and it goes back
  # through `handle_params/3`, which looks it up as the admin.
  @impl true
  def handle_event("pick_run", %{"run" => id}, socket) when is_binary(id) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:noreply, push_patch(socket, to: log_path(id, socket.assigns.level))}
    else
      deny(socket)
    end
  end

  def handle_event("pick_run", _params, socket), do: {:noreply, socket}

  # One poll tick: the shown run read again, as the admin, while it runs.
  # A tick of a timer that was replaced is ignored.
  @impl true
  def handle_info({:log_poll, ref}, %{assigns: %{poll_ref: ref}} = socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      socket = socket |> assign(:poll_ref, nil) |> update(:polls_left, &(&1 - 1))

      case Backups.download_refusal() do
        nil -> {:noreply, socket |> reread() |> poll()}
        refusal -> {:noreply, refuse(socket, refusal)}
      end
    else
      socket |> assign(:poll_ref, nil) |> deny()
    end
  end

  def handle_info({:log_poll, _stale}, socket), do: {:noreply, socket}

  # Refused: nothing about any run stays on the page, and the poll stops.
  defp refuse(socket, refusal) do
    socket
    |> assign(:refusal, refusal)
    |> assign(:run, nil)
    |> assign(:options, [])
    |> assign(:entries, [])
    |> assign(:counts, %{all: 0, warn: 0, error: 0})
    |> assign(:error, nil)
    |> assign(:live?, false)
    |> assign(:stopped?, false)
    |> assign(:trigger, nil)
    |> assign(:poll_ref, nil)
  end

  defp load(socket, requested) do
    user = socket.assigns.current_user
    held = held_stamp()
    {run, socket} = pick(socket, requested, held, user)

    socket
    |> assign(:refusal, nil)
    |> assign(:options, options(user, run))
    |> show(run, held)
  end

  # `?run=`, else the run the lock holds, else the newest.
  defp pick(socket, id, held, user) when is_binary(id) do
    case read_run(id, user) do
      {:ok, run} ->
        {run, socket}

      :error ->
        {default_run(held, user),
         put_flash(socket, :error, gettext("That backup isn't in the history."))}
    end
  end

  defp pick(socket, nil, held, user), do: {default_run(held, user), socket}

  defp default_run(held, user) do
    with stamp when is_binary(stamp) <- held,
         {:ok, %Run{} = run} <- Backups.get_run_by_stamp(stamp, actor: user) do
      run
    else
      _ -> newest_run(user)
    end
  end

  defp newest_run(user) do
    with {:ok, %{results: [%Run{id: id} | _]}} <-
           Backups.run_history(page: [limit: 1], actor: user, authorize_with: :error),
         {:ok, run} <- read_run(id, user) do
      run
    else
      _ -> nil
    end
  end

  defp read_run(id, user) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, run} <- Backups.get_run(id, actor: user, authorize_with: :error) do
      {:ok, run}
    else
      _ -> :error
    end
  end

  # The newest runs as `%{id, label}`, read with only what a label says, and
  # the shown run added when it is older than they are.
  defp options(user, run) do
    env = LogText.read_env()
    query = Ash.Query.select(Run, [:id, :stamp, :trigger, :status, :started_at])

    newest =
      case Backups.run_history(
             query: query,
             page: [limit: @picker_size],
             actor: user,
             authorize_with: :error
           ) do
        {:ok, %{results: runs}} -> runs
        {:error, _error} -> []
      end

    runs =
      if is_nil(run) or Enum.any?(newest, &(&1.id == run.id)),
        do: newest,
        else: newest ++ [run]

    Enum.map(runs, &%{id: &1.id, label: option_label(&1, env)})
  end

  defp reread(%{assigns: %{run: %Run{id: id}}} = socket) do
    case read_run(id, socket.assigns.current_user) do
      {:ok, run} ->
        socket
        |> assign(:options, options(socket.assigns.current_user, run))
        |> show(run, held_stamp())

      :error ->
        socket
        |> assign(:live?, false)
        |> put_flash(
          :error,
          gettext("Couldn't read this backup's log again. The page shows what it read last.")
        )
    end
  end

  defp reread(socket), do: socket

  defp show(socket, nil, _held) do
    socket
    |> assign(:run, nil)
    |> assign(:entries, [])
    |> assign(:counts, %{all: 0, warn: 0, error: 0})
    |> assign(:error, nil)
    |> assign(:trigger, nil)
    |> assign(:live?, false)
    |> assign(:stopped?, false)
  end

  defp show(socket, %Run{} = run, held) do
    env = LogText.read_env()

    socket
    |> assign(:run, run)
    |> assign(:entries, LogText.entries(run, socket.assigns.level, env))
    |> assign(:counts, LogText.counts(run))
    |> assign(:error, LogText.error(run, env))
    |> assign(:trigger, trigger_label(run.trigger, env))
    |> assign(:live?, run.status == :running or (is_binary(held) and held == run.stamp))
    |> assign(:stopped?, false)
  end

  defp held_stamp do
    case Chain.fetch_held_stamp() do
      {:ok, stamp} -> stamp
      {:error, _reason} -> nil
    end
  end

  # One timer at a time: a patch replaces the pending one (its tick is then
  # ignored), and none is set once the run has finished or the polls ran out.
  defp poll(%{assigns: %{live?: true, polls_left: left}} = socket) when left > 0 do
    if connected?(socket) do
      ref = make_ref()
      Process.send_after(self(), {:log_poll, ref}, @poll_interval_ms)
      assign(socket, :poll_ref, ref)
    else
      socket
    end
  end

  # Out of polls while the run still runs: the page no longer follows it,
  # and says so rather than calling itself live.
  defp poll(%{assigns: %{live?: true}} = socket) do
    socket
    |> assign(:live?, false)
    |> assign(:stopped?, true)
    |> assign(:poll_ref, nil)
  end

  defp poll(socket), do: assign(socket, :poll_ref, nil)

  defp log_path(run_id, level) do
    query = if level == :all, do: %{run: run_id}, else: %{run: run_id, level: level}
    ~p"/editor/backups/log?#{query}"
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
      <div id="backup-log-page" class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6">
        <.tabs active={:log} />

        <div>
          <h1 class="text-2xl font-semibold">{gettext("Backup log")}</h1>
          <p class="mt-1 text-sm text-base-content/70">
            {gettext(
              "What each step of a backup recorded. Secrets are removed when a line is stored, and again when it is shown."
            )}
          </p>
        </div>

        <p
          :if={@refusal == :console_shares_origin}
          id="backup-log-refused"
          role="status"
          class="rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-warning-ink"
        >
          {gettext(
            "Backup logs are hidden: the console shares its address with your organizations' sites (KILN_CONSOLE_HOST is unset and there is more than one organization), so a site's injected code could read them. Set KILN_CONSOLE_HOST to see them here."
          )}
          <a
            href={docs_url("code-injection.md")}
            target="_blank"
            rel="noopener"
            class="link ml-1 inline-flex items-center gap-1"
          >
            {gettext("Learn more")}
            <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            <span class="sr-only">{gettext("(opens in a new tab)")}</span>
          </a>
        </p>

        <.empty_state
          :if={is_nil(@refusal) and is_nil(@run)}
          id="backup-log-empty"
          icon="hero-document-text"
          title={gettext("No backups yet")}
        >
          {gettext("A backup's log appears here once one has run.")}
        </.empty_state>

        <.run_log
          :if={is_nil(@refusal) and @run}
          run={@run}
          options={@options}
          level={@level}
          entries={@entries}
          counts={@counts}
          error={@error}
          trigger={@trigger}
          live?={@live?}
          stopped?={@stopped?}
        />
      </div>
    </Layouts.console>
    """
  end

  attr :run, Run, required: true
  attr :options, :list, required: true
  attr :level, :atom, required: true
  attr :entries, :list, required: true
  attr :counts, :map, required: true
  attr :error, :string, default: nil
  attr :trigger, :string, required: true, doc: "the run's trigger as shown (`trigger_label/2`)"
  attr :live?, :boolean, required: true
  attr :stopped?, :boolean, required: true, doc: "the poll ran out while the run still ran"

  defp run_log(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-3">
      <form id="backup-log-picker" phx-change="pick_run" class="min-w-0 flex-1 sm:max-w-sm">
        <.input
          type="select"
          id="backup-log-run"
          name="run"
          label={gettext("Backup")}
          value={@run.id}
          options={Enum.map(@options, &{&1.label, &1.id})}
        />
      </form>
      <.link
        id="backup-log-download"
        href={~p"/editor/backups/runs/#{@run.id}/log.txt"}
        class="btn btn-sm btn-default"
      >
        <.icon name="hero-arrow-down-tray" class="mr-1 size-4" />
        {gettext("Download log")}
      </.link>
    </div>

    <section id="backup-log-summary" class="card card-pad space-y-2 text-sm">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span class="font-mono font-medium">{@run.stamp}</span>
        <span
          data-role="status"
          class={[
            "rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase",
            status_class(@run.status)
          ]}
        >
          {run_status_label(@run.status)}
        </span>
        <span data-role="trigger" class="text-xs text-base-content/70">
          {@trigger}
        </span>
        <span
          :for={component <- @run.components}
          data-role="component"
          class="rounded bg-base-content/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-base-content/70"
        >
          {component_label(component)}
        </span>
      </div>
      <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-xs">
        <dt class="text-base-content/70">{gettext("Started")}</dt>
        <dd>
          <time datetime={DateTime.to_iso8601(@run.started_at)}>
            {Calendar.strftime(@run.started_at, "%Y-%m-%d %H:%M:%S UTC")}
          </time>
        </dd>
        <dt class="text-base-content/70">{gettext("Finished")}</dt>
        <dd>
          <time :if={@run.finished_at} datetime={DateTime.to_iso8601(@run.finished_at)}>
            {Calendar.strftime(@run.finished_at, "%Y-%m-%d %H:%M:%S UTC")}
          </time>
          <span :if={is_nil(@run.finished_at)}>—</span>
        </dd>
      </dl>
      <p
        :if={@error}
        id="backup-log-error"
        class="whitespace-pre-wrap break-words font-mono text-xs text-error-ink"
      >
        {@error}
      </p>
      <p :if={@run.origin == :imported} id="backup-log-imported" class="text-xs text-base-content/70">
        {gettext("A backup made by scripts/backup.sh. Its full output is in the host's cron log.")}
      </p>
      <p
        :if={@live?}
        id="backup-log-live"
        role="status"
        class="inline-flex items-center gap-1.5 text-xs text-info-ink"
      >
        <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
        {gettext("Live: new lines appear as each step finishes.")}
      </p>
      <p
        :if={@stopped?}
        id="backup-log-stopped"
        role="status"
        class="inline-flex items-center gap-1.5 text-xs text-warning-ink"
      >
        <.icon name="hero-pause-circle" class="size-4" />
        {gettext("This page stopped checking for new lines. Reload it to follow the backup again.")}
      </p>
    </section>

    <nav id="backup-log-levels" class="flex flex-wrap gap-2" aria-label={gettext("Log level")}>
      <.link
        :for={level <- LogText.filters()}
        id={"backup-log-level-#{level}"}
        patch={log_path(@run.id, level)}
        class="pill"
        aria-current={level == @level && "page"}
      >
        {level_filter_label(level)}
        <span class="tabular-nums">{@counts[level]}</span>
      </.link>
    </nav>

    <p
      :if={@run.log == []}
      id="backup-log-no-lines"
      class="text-sm text-base-content/70"
    >
      {gettext("This backup recorded no log lines.")}
    </p>
    <p
      :if={@run.log != [] and @entries == []}
      id="backup-log-none-at-level"
      class="text-sm text-base-content/70"
    >
      {gettext("No lines at this level.")}
    </p>

    <%!-- Newest at the bottom, with no auto-scroll: a long log has a link
          down to it instead. --%>
    <a
      :if={length(@entries) > 10}
      href="#backup-log-latest"
      class="link inline-flex items-center gap-1 text-sm text-primary-ink"
    >
      <.icon name="hero-arrow-down" class="size-4" />
      {gettext("Jump to latest")}
    </a>
    <ol
      :if={@entries != []}
      id="backup-log-entries"
      class="card divide-y divide-base-content/10"
    >
      <li
        :for={entry <- @entries}
        data-role="entry"
        data-level={entry.level}
        class={[
          "space-y-1 px-4 py-2.5 text-sm",
          LogText.truncated?(entry) && "bg-warning/10"
        ]}
      >
        <%= if LogText.truncated?(entry) do %>
          <p data-role="truncated" class="flex items-center gap-1.5 text-warning-ink">
            <.icon name="hero-scissors" class="size-4 shrink-0" />
            {dropped_label(entry)}
          </p>
        <% else %>
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
            <time datetime={DateTime.to_iso8601(entry.at)} class="tabular-nums text-base-content/70">
              {Calendar.strftime(entry.at, "%H:%M:%S")}
            </time>
            <span
              data-role="level"
              class={["inline-flex items-center gap-1 font-semibold", level_class(entry.level)]}
            >
              <.icon name={level_icon(entry.level)} class="size-4" />
              {level_label(entry.level)}
            </span>
            <span
              data-role="step"
              class="rounded bg-base-content/10 px-1.5 py-0.5 font-mono text-base-content/70"
            >
              {entry.step}
            </span>
          </div>
          <p data-role="message" class="whitespace-pre-wrap break-words font-mono text-xs">
            {entry.message}
          </p>
        <% end %>
      </li>
    </ol>
    <span id="backup-log-latest"></span>
    """
  end

  defp option_label(run, env) do
    Enum.join(
      [
        Calendar.strftime(run.started_at, "%Y-%m-%d %H:%M UTC"),
        trigger_label(run.trigger, env),
        run_status_label(run.status)
      ],
      " · "
    )
  end

  defp level_filter_label(:all), do: gettext("All")
  defp level_filter_label(:warn), do: gettext("Warnings and errors")
  defp level_filter_label(:error), do: gettext("Errors")

  defp level_label(:info), do: gettext("Info")
  defp level_label(:warn), do: gettext("Warning")
  defp level_label(:error), do: gettext("Error")
  defp level_label(other), do: to_string(other)

  # The count the download shows too, read from the cap's own marker.
  defp dropped_label(entry) do
    case Log.marker_count(entry) do
      nil ->
        gettext("Some lines were dropped to keep the log small")

      count ->
        ngettext(
          "One line was dropped to keep the log small",
          "%{count} lines were dropped to keep the log small",
          count
        )
    end
  end

  defp level_icon(:warn), do: "hero-exclamation-triangle"
  defp level_icon(:error), do: "hero-x-circle"
  defp level_icon(_info), do: "hero-information-circle"

  defp level_class(:warn), do: "text-warning-ink"
  defp level_class(:error), do: "text-error-ink"
  defp level_class(_info), do: "text-base-content/70"

  # As on the Backups tab: who asked, and the status badge's tone.
  defp trigger_label("manual", _env), do: gettext("Manual")
  defp trigger_label("cron", _env), do: gettext("Cron")
  defp trigger_label("console", _env), do: gettext("Console")
  defp trigger_label("schedule", _env), do: gettext("Scheduled")
  # Anything else is operator text, shown only redacted and sanitized.
  defp trigger_label(other, env), do: LogText.trigger(other, env)

  defp status_class(:succeeded), do: "bg-success/15 text-success-ink"
  defp status_class(:failed), do: "bg-error/15 text-error-ink"
  defp status_class(:running), do: "bg-info/15 text-info-ink"
  defp status_class(:skipped), do: "bg-warning/15 text-warning-ink"
  defp status_class(_canceled), do: "bg-base-content/10 text-base-content/70"
end
