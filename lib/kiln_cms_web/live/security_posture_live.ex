defmodule KilnCMSWeb.SecurityPostureLive do
  @moduledoc """
  The Security posture page (#2252): which security settings are on for this
  site, and for a platform administrator the installation, with what to fix
  first.

  Org-scoped and admin-only, gated the same two ways as
  `KilnCMSWeb.SecurityLogLive`: the `:admin_routes` live session's tier gate
  and the `KilnCMS.Security.PostureReport` policy. "Run checks again"
  re-checks the tier as well, because the socket outlives the mount-time
  check.

  The report runs in `start_async/3`, so the page draws at once and fills in
  when the slowest check finishes or reaches its deadline. "Run checks again"
  is refused while a run is in flight and within a few seconds of the last
  one, and the report action itself caps how many of one site's reports run
  at once (`KilnCMS.Security.Posture.with_slot/2`), so neither one page nor
  many can fill the checks' task supervisor.

  Everything a check reports is escaped by HEEx: a plugin's summary and
  details are shown as text, its fix link only when it is a console path, and
  its "Learn more" link only when it is `https://`
  (`Kiln.Security.Check.Result.sanitize/1`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Security
  alias KilnCMS.Security.Posture
  alias Phoenix.LiveView.AsyncResult

  # The least time between two "Run checks again" on one page. Each run is a
  # task per check, so a held-down button must not become a flood (#2252).
  @rerun_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Security posture"))
      |> assign(:locale, Gettext.get_locale(KilnCMSWeb.Gettext))
      |> assign(:report, AsyncResult.loading())
      |> assign(:running?, false)
      |> assign(:last_rerun_at, nil)

    {:ok, if(connected?(socket), do: start_report(socket), else: socket)}
  end

  @impl true
  def handle_event("rerun", _params, socket) do
    cond do
      not admin?(socket) ->
        {:noreply, put_flash(socket, :error, forbidden_message())}

      socket.assigns.running? ->
        {:noreply, put_flash(socket, :info, gettext("The checks are already running."))}

      too_soon?(socket.assigns.last_rerun_at) ->
        {:noreply,
         put_flash(socket, :info, gettext("The checks just ran. Try again in a few seconds."))}

      true ->
        {:noreply,
         socket
         |> cancel_async(:report)
         |> assign(:report, AsyncResult.loading(socket.assigns.report))
         |> assign(:last_rerun_at, System.monotonic_time(:millisecond))
         |> start_report()}
    end
  end

  @impl true
  def handle_async(:report, result, socket) do
    {:noreply, socket |> assign(:running?, false) |> report_result(result)}
  end

  defp report_result(socket, {:ok, {:ok, report}}),
    do: assign(socket, :report, AsyncResult.ok(socket.assigns.report, report))

  defp report_result(socket, {:ok, {:error, %Ash.Error.Forbidden{}}}) do
    socket
    |> assign(:report, AsyncResult.failed(socket.assigns.report, :forbidden))
    |> put_flash(:error, forbidden_message())
  end

  defp report_result(socket, {:ok, {:error, error}}) do
    if KilnCMS.Security.Errors.PostureBusy.in?(error) do
      socket
      |> assign(:report, AsyncResult.failed(socket.assigns.report, :busy))
      |> put_flash(
        :error,
        gettext("The checks are already running for this site. Try again in a moment.")
      )
    else
      assign(socket, :report, AsyncResult.failed(socket.assigns.report, :error))
    end
  end

  defp report_result(socket, {:exit, reason}),
    do: assign(socket, :report, AsyncResult.failed(socket.assigns.report, {:exit, reason}))

  defp too_soon?(nil), do: false

  defp too_soon?(at),
    do: System.monotonic_time(:millisecond) - at < @rerun_interval_ms

  defp start_report(socket) do
    %{current_user: user, current_org: org, locale: locale} = socket.assigns

    socket
    |> assign(:running?, true)
    |> start_async(:report, fn ->
      Security.run_posture(%{locale: locale}, actor: user, tenant: org)
    end)
  end

  defp admin?(socket), do: KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin

  defp forbidden_message,
    do: gettext("You don't have permission to see this site's security posture.")

  defp section(entries, scope) do
    entries |> Enum.filter(&(&1.scope == scope)) |> Posture.sorted()
  end

  defp dom_id(id), do: "posture-" <> String.replace(id, ~r/[^a-z0-9_]/, "-")

  defp badge_for(:fail), do: {"error", gettext("Fix now")}
  defp badge_for(:warn), do: {"warning", gettext("Review")}
  defp badge_for(:error), do: {"warning", gettext("Could not run")}
  defp badge_for(:unknown), do: {"warning", gettext("Unknown")}
  defp badge_for(:pass), do: {"success", gettext("OK")}
  defp badge_for(:n_a), do: {"outline", gettext("Not applicable")}

  defp overall_text(:fail), do: gettext("Something needs fixing.")
  defp overall_text(:warn), do: gettext("Some settings are worth a look.")
  defp overall_text(:pass), do: gettext("Every check passed.")

  defp error_text(:timeout), do: gettext("This check could not run: it took too long.")
  defp error_text(:crashed), do: gettext("This check could not run: it failed.")

  defp error_text(:invalid_result),
    do: gettext("This check could not run: it gave an answer the page can't show.")

  defp error_text(:busy), do: gettext("This check could not run: the server was busy.")

  defp source_text({:plugin, name}), do: gettext("From the %{plugin} plugin", plugin: name)
  defp source_text(_core), do: nil

  defp count_line(counts) do
    [
      {:fail, &ngettext("%{count} to fix", "%{count} to fix", &1)},
      {:warn, &ngettext("%{count} to review", "%{count} to review", &1)},
      {:unknown, &ngettext("%{count} unknown", "%{count} unknown", &1)},
      {:error, &ngettext("%{count} could not run", "%{count} could not run", &1)},
      {:pass, &ngettext("%{count} OK", "%{count} OK", &1)},
      {:n_a, &ngettext("%{count} not applicable", "%{count} not applicable", &1)}
    ]
    |> Enum.flat_map(fn {status, text} ->
      case Map.get(counts, status, 0) do
        0 -> []
        n -> [text.(n)]
      end
    end)
    |> Enum.join(" · ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:security_posture}
    >
      <.header>
        {gettext("Security posture")}
        <:subtitle>
          {gettext(
            "Which security settings are on, and what to fix first. Nothing here changes a setting; each line links to where you can."
          )}
        </:subtitle>
        <:actions>
          <.button
            id="security-posture-rerun"
            type="button"
            variant="ghost"
            size="sm"
            phx-click="rerun"
            phx-disable-with={gettext("Running…")}
          >
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("Run checks again")}
          </.button>
        </:actions>
      </.header>

      <.async_result :let={report} assign={@report}>
        <:loading>
          <p id="security-posture-loading" class="mt-6 text-sm text-base-content/70" role="status">
            {gettext("Running the checks…")}
          </p>
        </:loading>
        <:failed :let={_reason}>
          <p id="security-posture-failed" class="mt-6 text-sm text-error-ink" role="alert">
            {gettext("The checks could not be run. Try again in a moment.")}
          </p>
        </:failed>

        <div
          id="security-posture-summary"
          class="mt-6 flex flex-wrap items-center gap-3 rounded-lg border border-base-300 p-4"
        >
          <.status_badge status={report.overall} />
          <p class="text-sm font-medium">{overall_text(report.overall)}</p>
          <p id="security-posture-counts" class="text-sm text-base-content/70">
            {count_line(report.counts)}
          </p>
        </div>

        <section id="security-posture-site" class="mt-8">
          <h2 class="text-sm font-semibold">{gettext("This site")}</h2>
          <.posture_list entries={section(report.entries, :site)} />
        </section>

        <section :if={:deployment in report.scopes} id="security-posture-deployment" class="mt-10">
          <h2 class="text-sm font-semibold">{gettext("This installation")}</h2>
          <p class="mt-1 text-sm text-base-content/70">
            {gettext(
              "Settings of the whole installation, shown to platform administrators only. Most are changed in the environment, not here."
            )}
          </p>
          <.posture_list entries={section(report.entries, :deployment)} />
        </section>
      </.async_result>
    </Layouts.console>
    """
  end

  attr :status, :atom, required: true
  attr :class, :any, default: nil

  defp status_badge(assigns) do
    {variant, label} = badge_for(assigns.status)
    assigns = assign(assigns, variant: variant, label: label)

    ~H"""
    <.badge variant={@variant} class={@class}>{@label}</.badge>
    """
  end

  attr :entries, :list, required: true

  defp posture_list(assigns) do
    ~H"""
    <ul class="mt-3 space-y-2">
      <li :for={entry <- @entries} id={dom_id(entry.id)} class="card p-4">
        <div class="flex flex-wrap items-start gap-3">
          <.status_badge status={entry.status} class="shrink-0" />
          <div class="min-w-0 flex-1">
            <p class="text-sm font-medium">{entry.title}</p>
            <p :if={entry.result} class="mt-0.5 text-sm text-base-content/70">
              {entry.result.summary}
            </p>
            <p :if={entry.error} class="mt-0.5 text-sm text-base-content/70">
              {error_text(entry.error)}
            </p>
            <p :if={source_text(entry.source)} class="mt-0.5 text-xs text-base-content/70">
              {source_text(entry.source)}
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-3 text-sm">
            <.link
              :if={entry.result && entry.result.fix_path}
              navigate={entry.result.fix_path}
              class="font-medium text-primary-ink hover:underline"
            >
              {gettext("Fix")}
            </.link>
            <a
              :if={entry.result && entry.result.docs_url}
              href={entry.result.docs_url}
              target="_blank"
              rel="noopener noreferrer"
              class="text-base-content/70 hover:underline"
            >
              {gettext("Learn more")}
            </a>
          </div>
        </div>
        <details
          :if={entry.description || (entry.result && entry.result.details != [])}
          class="mt-2 text-sm"
        >
          <summary class="cursor-pointer text-base-content/70">{gettext("Details")}</summary>
          <p :if={entry.description} class="mt-2">{entry.description}</p>
          <ul
            :if={entry.result && entry.result.details != []}
            class="mt-2 list-disc space-y-0.5 pl-5 text-base-content/70"
          >
            <li :for={detail <- entry.result.details} class="break-all">{detail}</li>
          </ul>
        </details>
      </li>
    </ul>
    """
  end
end
