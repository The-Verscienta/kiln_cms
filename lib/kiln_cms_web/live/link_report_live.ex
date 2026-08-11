defmodule KilnCMSWeb.LinkReportLive do
  @moduledoc """
  The site-wide broken-link report (`/editor/links`, #474).

  The external half of the link checker is a scheduled sweep over everything, so
  unlike the internal half it has no document open to report into — this page is
  its surface. Editorial work, so it sits in the editor nav rather than under
  administration; the *switch* is admin-only, because turning it on is what makes
  this deployment issue outbound requests.

  ## Off is a state worth rendering

  A site that has not opted in gets an explanation, not an empty table. "No
  broken links" and "nothing has ever been checked" are the same picture and
  opposite facts, and a report that cannot tell them apart is one that quietly
  reassures.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Links.CheckWorker
  alias KilnCMS.Links.Report
  alias KilnCMS.Links.Settings
  alias KilnCMS.Links.SweepWorker

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Links"))
     |> assign(:admin?, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     |> load_report()}
  end

  @impl true
  def handle_event("toggle", params, socket) do
    enabled? = params["external_enabled"] == "true"

    # Authorized rather than gated on the assign: `@admin?` decides what renders,
    # and the resource policy decides what happens.
    case Settings.save(org_id(socket), enabled?, actor: socket.assigns.current_user) do
      {:ok, _settings} ->
        {:noreply, socket |> load_report() |> put_flash(:info, saved_message(enabled?))}

      {:error, _error} ->
        {:noreply,
         put_flash(socket, :error, gettext("You need admin access to change that setting."))}
    end
  end

  # `effective_tier(socket)` rather than `socket.assigns.admin?` (#1166). The
  # assign is computed once, at mount, and this page is on `:editor_routes` —
  # so mount never refuses at all, and that one stale boolean was the whole
  # distance between an editor and the enqueue. `SweepWorker.enqueue/1` takes no
  # actor and authorizes nothing, so unlike `toggle` above there is no resource
  # policy to delegate to; the sibling's comment says exactly that, and this is
  # the handler that could not follow its advice.
  #
  # `@admin?` still decides what renders. It just no longer decides what runs.
  def handle_event("check_now", _params, socket) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok, _job} = SweepWorker.enqueue(org_id(socket))

      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("Check queued — results appear here as each link is answered.")
       )}
    else
      {:noreply, put_flash(socket, :error, gettext("You need admin access to run a check."))}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_report(socket)}

  defp load_report(socket), do: assign(socket, :report, Report.for_org(org_id(socket)))

  defp org_id(socket) do
    case socket.assigns[:current_org] do
      nil -> KilnCMS.Accounts.default_org_id()
      org -> org.id
    end
  end

  defp saved_message(true),
    do: gettext("Outbound link checking is on. The first sweep runs tonight, or check now.")

  defp saved_message(false), do: gettext("Outbound link checking is off.")

  defp when_str(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  # `/editor/content/:type/:id` works for every type, compiled or dynamic.
  defp editor_path(document), do: ~p"/editor/content/#{document.type}/#{document.id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:links}
    >
      <.header>
        {gettext("Broken links")}
        <:subtitle>
          {gettext(
            "Outbound links in published content that no longer answer. Links inside the site are checked as you edit, in the editor's advisory panel."
          )}
        </:subtitle>
        <:actions>
          <.button :if={@report.enabled? and @admin?} size="sm" phx-click="check_now">
            {gettext("Check now")}
          </.button>
          <.button size="sm" variant="ghost" phx-click="refresh">
            {gettext("Refresh")}
          </.button>
        </:actions>
      </.header>

      <section :if={not @report.enabled?} class="card card-pad mt-6">
        <h2 class="text-sm font-medium">{gettext("Outbound checking is off")}</h2>
        <p class="mt-2 text-sm text-base-content/70">
          {gettext(
            "Turning this on makes the server request every third-party URL your published content links to, on a schedule. Requests are paced per domain and identify themselves as Kiln. Nothing here has been checked until you switch it on."
          )}
        </p>
        <p :if={not @admin?} class="mt-3 text-sm text-base-content/60">
          {gettext("An administrator can switch it on.")}
        </p>
        <.button
          :if={@admin?}
          class="mt-4 self-start"
          variant="primary"
          size="sm"
          phx-click="toggle"
          phx-value-external_enabled="true"
        >
          {gettext("Turn on outbound checking")}
        </.button>
      </section>

      <div :if={@report.enabled?} class="mt-6 space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-3 text-sm text-base-content/70">
          <p>
            <%= if @report.last_swept_at do %>
              {gettext("Last swept %{at}.", at: when_str(@report.last_swept_at))}
            <% else %>
              {gettext("No sweep has finished yet — the first one runs tonight.")}
            <% end %>
            {gettext("%{checked} links checked, %{waiting} still to check.",
              checked: @report.counts.ok + @report.counts.broken + @report.counts.undetermined,
              waiting: @report.counts.pending + @report.counts.transient
            )}
          </p>
          <.button
            :if={@admin?}
            size="sm"
            variant="ghost"
            phx-click="toggle"
            phx-value-external_enabled="false"
            data-confirm={gettext("Stop checking outbound links for this site?")}
          >
            {gettext("Turn off")}
          </.button>
        </div>

        <.empty_state
          :if={@report.broken == []}
          icon="hero-check-circle"
          title={gettext("No broken outbound links")}
        >
          {gettext(
            "Links that answered with a bot wall, a paywall or a rate limit are not listed — a checker cannot tell those from a working page, and guessing is how a report becomes noise."
          )}
        </.empty_state>

        <p :if={@report.truncated?} class="text-sm text-warning">
          {gettext("Showing the first %{count} occurrences — fix some and re-check for the rest.",
            count: Report.row_cap()
          )}
        </p>

        <ul :if={@report.broken != []} class="space-y-4">
          <li :for={entry <- @report.broken} class="card card-pad">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <a
                  href={entry.url}
                  target="_blank"
                  rel="noopener noreferrer nofollow"
                  class="break-all font-medium underline decoration-dotted"
                >
                  {entry.url}
                </a>
                <p class="mt-1 text-xs text-base-content/60">
                  <span :if={entry.reason}>{entry.reason}</span>
                  <span :if={entry.first_failed_at}>
                    · {gettext("failing since %{at}", at: when_str(entry.first_failed_at))}
                  </span>
                  <span :if={entry.last_checked_at}>
                    · {gettext("checked %{at}", at: when_str(entry.last_checked_at))}
                  </span>
                </p>
              </div>
              <span
                :if={entry.status_code}
                class="rounded bg-error/15 px-1.5 py-0.5 text-xs font-medium text-error-ink"
              >
                {gettext("HTTP %{status}", status: entry.status_code)}
              </span>
            </div>

            <ul class="mt-3 space-y-1 text-sm">
              <li :for={document <- entry.documents} class="flex flex-wrap items-center gap-2">
                <.link navigate={editor_path(document)} class="underline">
                  {document.title || gettext("(untitled)")}
                </.link>
                <span class="text-xs text-base-content/50">{document.type}</span>
                <span :if={document.block_index} class="text-xs text-base-content/50">
                  {gettext("block %{index}", index: document.block_index + 1)}
                </span>
              </li>
            </ul>
          </li>
        </ul>

        <p class="text-xs text-base-content/50">
          {gettext(
            "A link is only listed after it fails %{count} checks in a row, so a brief outage at a busy host never reaches this page.",
            count: CheckWorker.failures_before_broken()
          )}
        </p>
      </div>
    </Layouts.console>
    """
  end
end
