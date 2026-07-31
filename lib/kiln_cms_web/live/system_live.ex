defmodule KilnCMSWeb.SystemLive do
  @moduledoc """
  System info (`/editor/system`, admin-only) — which Kiln this instance is
  running, and whether a newer release exists upstream.

  ## Why this page reports instead of acting

  A deployment runs from an immutable image built off a pinned Kiln checkout
  (`projects/README.md`), so there is no source tree here to rewrite and no way
  to restart into a different one. An "update" button would be a lie on the
  deploy path this project actually uses.

  It would also be a bad idea on any path: applying an update means running
  migrations against the live database, and an admin panel that can rewrite
  application code and migrate production on one click is a serious escalation
  surface for anyone who takes over an admin session.

  So the page reports the gap and hands over the exact command. Applying it is
  `mix kiln.update`, run by someone with repository access.

  The check runs via `start_async` so a slow or blocked network never delays
  the render — the version panel is useful on its own.
  """
  use KilnCMSWeb, :live_view

  alias Kiln.Updates
  alias Kiln.Version, as: Build

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("System"))
       |> assign(:build, Build.current())
       |> assign(:update, :loading)
       |> check_for_updates()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp check_for_updates(socket, opts \\ []) do
    if Updates.enabled?() do
      socket
      |> assign(:update, :loading)
      |> start_async(:update_check, fn -> Updates.check(opts) end)
    else
      assign(socket, :update, {:error, :disabled})
    end
  end

  @impl true
  def handle_async(:update_check, {:ok, result}, socket) do
    {:noreply, assign(socket, :update, result)}
  end

  # A crashed check must not take the page down — it degrades to the same
  # "couldn't reach upstream" state as a network failure.
  def handle_async(:update_check, {:exit, reason}, socket) do
    {:noreply, assign(socket, :update, {:error, reason})}
  end

  @impl true
  def handle_event("check-now", _params, socket) do
    # The button's `disabled` attribute is client-side only, and start_async
    # does not cancel an in-flight task — without this guard a scripted client
    # could stack unbounded concurrent requests, and a late-finishing orphan
    # would still write the cache after its result was discarded for display.
    # `Kiln.Updates` also floors forced checks at one per minute.
    if socket.assigns.update == :loading do
      {:noreply, socket}
    else
      {:noreply, check_for_updates(socket, force: true)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:system}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("System")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext("The Kiln core this instance is built from, and how to update it.")}
          </p>
        </div>

        <section class="card card-pad max-w-2xl">
          <h2 class="text-lg font-semibold">{gettext("This instance")}</h2>

          <dl class="mt-4 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
            <dt class="text-base-content/60">{gettext("Kiln version")}</dt>
            <dd class="font-mono">{@build.version}</dd>

            <dt class="text-base-content/60">{gettext("Build")}</dt>
            <dd class="font-mono">
              {if @build.git_sha, do: String.slice(@build.git_sha, 0, 7), else: gettext("unknown")}
            </dd>

            <dt class="text-base-content/60">{gettext("Built")}</dt>
            <dd>
              {if @build.built_at,
                do: Calendar.strftime(@build.built_at, "%Y-%m-%d %H:%M UTC"),
                else: gettext("unknown")}
            </dd>
          </dl>

          <p :if={is_nil(@build.git_sha)} class="mt-4 text-xs text-base-content/60">
            {gettext(
              "No build stamp. Pass --build-arg GIT_SHA and --build-arg BUILD_DATE when building the image to record exactly which commit is deployed."
            )}
          </p>
        </section>

        <section class="card card-pad max-w-2xl">
          <div class="flex items-start justify-between gap-4">
            <h2 class="text-lg font-semibold">{gettext("Updates")}</h2>
            <button
              :if={Updates.enabled?()}
              type="button"
              phx-click="check-now"
              class="btn btn-sm btn-ghost"
              disabled={@update == :loading}
            >
              {gettext("Check now")}
            </button>
          </div>

          <div class="mt-4">
            <.update_status update={@update} />
          </div>
        </section>
      </div>
    </Layouts.console>
    """
  end

  # Kept out of the template: the <pre> has to hold its own newlines, which a
  # HEEx heredoc can't express without breaking its indentation rules.
  @update_command "mix kiln.update"

  # The command is the same everywhere; only *where* you run it varies, and
  # this instance genuinely cannot know that — the pin is a submodule or a
  # fetched ref at a path the project chose, and the image has no checkout to
  # look in. So the `cd` is shown only when the operator supplied it
  # (KILN_PIN_PATH); otherwise the prose says "your project's Kiln checkout"
  # rather than printing a path that is wrong on every non-reference layout.
  defp update_command do
    case Updates.pin_path() do
      nil -> @update_command
      path -> "cd #{path}\n#{@update_command}"
    end
  end

  attr :update, :any, required: true

  defp update_status(%{update: :loading} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/70">{gettext("Checking for updates...")}</p>
    """
  end

  defp update_status(%{update: {:ok, :current}} = assigns) do
    ~H"""
    <p class="text-sm">
      <.badge variant="success" class="mr-2">{gettext("Up to date")}</.badge>
      {gettext("This is the newest released version of Kiln.")}
    </p>
    """
  end

  defp update_status(%{update: {:ok, {:behind, release}}} = assigns) do
    assigns =
      assigns
      |> assign(:release, release)
      |> assign(:update_command, update_command())

    ~H"""
    <div class="space-y-4">
      <p class="text-sm">
        <.badge variant="warning" class="mr-2">{gettext("Update available")}</.badge>
        <.link href={@release.url} target="_blank" rel="noopener" class="link">
          {@release.tag}
        </.link>
        <span :if={@release.published_at} class="text-base-content/60">
          {gettext("released")} {Calendar.strftime(@release.published_at, "%Y-%m-%d")}
        </span>
      </p>

      <div>
        <p class="text-sm text-base-content/70">
          {gettext("Apply it from your project's Kiln checkout, then rebuild and redeploy:")}
        </p>
        <pre class="mt-2 rounded bg-base-200 p-3 text-xs overflow-x-auto"><code>{@update_command}</code></pre>
        <p class="mt-2 text-xs text-base-content/60">
          {gettext(
            "The command reports new migrations and any required upgrade steps before it changes the pin. It does not deploy."
          )}
        </p>
      </div>
    </div>
    """
  end

  defp update_status(%{update: {:error, :disabled}} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/70">
      {gettext(
        "Update checks are turned off (KILN_UPDATE_CHECK=false). Compare this instance's version against the upstream releases page manually."
      )}
    </p>
    """
  end

  defp update_status(%{update: {:error, :unknown_version}} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/70">
      {gettext("This build reports no usable version, so it can't be compared against upstream.")}
    </p>
    """
  end

  # Distinct from the catch-all below on purpose: nothing was requested, so
  # "couldn't reach" would send an operator to look at the network for a
  # problem that is one environment variable away.
  defp update_status(%{update: {:error, reason}} = assigns)
       when reason in [:invalid_repo, :invalid_releases_url] do
    ~H"""
    <p class="text-sm text-base-content/70">
      {gettext(
        "The update check is misconfigured: KILN_UPDATE_REPO must be owner/name, and KILN_UPDATE_RELEASES_URL a full http(s) URL. No check was made."
      )}
    </p>
    """
  end

  defp update_status(assigns) do
    ~H"""
    <p class="text-sm text-base-content/70">
      {gettext(
        "Couldn't reach the upstream release feed. This says nothing about whether an update exists."
      )}
    </p>
    """
  end
end
