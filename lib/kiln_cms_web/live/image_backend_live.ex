defmodule KilnCMSWeb.ImageBackendLive do
  @moduledoc """
  System → Image backend (`/editor/system/image-backend`, platform-admin): the
  state of the external image service new uploads go to (#1955).

  Three questions, each with its own answer on the page:

    * **Which backend is selected, and is it taking uploads?** From
      `Kiln.ImageBackend.Registry` — the config line, whether that module is
      an installed backend, and whether it reports its own settings present.
    * **Does the service answer?** `c:Kiln.ImageBackend.check/0`, run on
      demand. A revoked token shows here rather than as the next upload's
      error, which an editor would see first.
    * **How much of this site's library does it hold?** `KilnCMS.Media.Adoption.census/2`:
      the rows it holds, the imported rows it recognises but doesn't hold yet,
      and the rows it doesn't recognise.

  Both of the last two reach outside the request — a network call and a scan
  of every row with no stored file — so they run in `start_async/3` and the
  page renders without them.

  Like System, it reports rather than acts. Selecting a backend is a config
  line and a deploy; adopting rows is `mix kiln.media.adopt_image_backend`,
  whose dry run shows the count this page shows. Platform-admin because the
  backend is the operator's choice, made once for every site on the
  deployment; the census is for the site being viewed.
  """
  use KilnCMSWeb, :live_view

  alias Kiln.ImageBackend.Registry
  alias KilnCMS.Media.Adoption

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      selected = Registry.configured()
      backend = if selected && Registry.backend?(selected), do: selected

      {:ok,
       socket
       |> assign(:page_title, gettext("Image backend"))
       |> assign(:selected, selected)
       |> assign(:backend, backend)
       |> assign(:state, state(selected, backend))
       |> assign(:plugin, backend && Registry.plugin_for(backend))
       |> assign(:installed, Enum.filter(Registry.installed(), &Registry.backend?/1))
       |> assign(:checked_at, nil)
       |> run_checks()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp state(nil, _backend), do: :none
  defp state(_selected, nil), do: :not_a_backend

  defp state(_selected, backend),
    do: if(Registry.active() == backend, do: :active, else: :unconfigured)

  defp run_checks(%{assigns: %{backend: nil}} = socket),
    do: assign(socket, check: nil, census: nil)

  defp run_checks(%{assigns: %{backend: backend, current_org: org}} = socket) do
    socket
    |> assign(check: :loading, census: :loading)
    |> start_async(:check, fn -> Registry.check(backend) end)
    |> start_async(:census, fn -> Adoption.census(org.id, backend) end)
  end

  @impl true
  def handle_async(:check, {:ok, result}, socket) do
    {:noreply, assign(socket, check: result, checked_at: DateTime.utc_now())}
  end

  # `Registry.check/1` doesn't raise, but a plugin's check can still hang past
  # its own timeout and be killed with the task — the page says it failed.
  def handle_async(:check, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       check: {:error, Exception.format_exit(reason)},
       checked_at: DateTime.utc_now()
     )}
  end

  def handle_async(:census, {:ok, result}, socket),
    do: {:noreply, assign(socket, :census, result)}

  def handle_async(:census, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :census, :error)}

  @impl true
  def handle_event("check-again", _params, socket) do
    # `disabled` on the button is client-side only, and start_async doesn't
    # cancel a running task: without this a scripted client could stack
    # network calls and library scans.
    if socket.assigns.check == :loading or socket.assigns.census == :loading do
      {:noreply, socket}
    else
      {:noreply, run_checks(socket)}
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
          <.link navigate={~p"/editor/system"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("System")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Image backend")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "An external image service, from a plugin, that stores new image uploads and renders their sizes and formats."
            )}
          </p>
        </div>

        <section id="image-backend-selection" class="card card-pad max-w-2xl">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <h2 class="text-lg font-semibold">{gettext("Selection")}</h2>
            <.selection_badge state={@state} />
          </div>

          <dl :if={@backend} class="mt-4 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
            <dt class="text-base-content/60">{gettext("Name")}</dt>
            <dd class="font-mono">{@backend.name()}</dd>

            <dt class="text-base-content/60">{gettext("Module")}</dt>
            <dd class="font-mono break-all">{inspect(@backend)}</dd>

            <dt class="text-base-content/60">{gettext("Plugin")}</dt>
            <dd :if={@plugin} class="font-mono">{@plugin.name()}</dd>
            <dd :if={is_nil(@plugin)} class="text-base-content/70">
              {gettext("None — set in config without a plugin declaring it")}
            </dd>
          </dl>

          <p :if={@state == :active} class="mt-4 text-sm text-base-content/70">
            {gettext(
              "New image uploads go to it once their metadata is stripped. Documents, video and audio, uploads to a site's own bucket, and images whose strip failed stay in this server's storage."
            )}
          </p>

          <p :if={@state == :unconfigured} class="mt-4 text-sm text-warning-ink">
            {gettext(
              "It is selected but reports its settings missing, so new uploads go to this server's storage. Images it already holds are still served from it. Its plugin's README lists the settings it needs."
            )}
          </p>

          <div :if={@state == :none} class="mt-4 space-y-3 text-sm text-base-content/70">
            <p>{gettext("No image backend is selected. New images go to this server's storage.")}</p>
            <p :if={@installed != []}>
              {gettext("Installed, and available to select in config/runtime.exs:")}
            </p>
            <ul :if={@installed != []} class="space-y-1">
              <li :for={module <- @installed} class="font-mono text-xs">
                config :kiln_cms, :image_backend, {inspect(module)}
              </li>
            </ul>
            <p :if={@installed == []}>
              {gettext("No installed plugin provides one.")}
            </p>
          </div>

          <p :if={@state == :not_a_backend} class="mt-4 text-sm text-error-ink">
            {gettext(
              "config :kiln_cms, :image_backend names %{module}, which isn't an installed image backend, so new uploads go to this server's storage. %{doctor} says what's wrong.",
              module: inspect(@selected),
              doctor: "mix kiln.plugins.doctor"
            )}
          </p>
        </section>

        <section :if={@backend} id="image-backend-connection" class="card card-pad max-w-2xl">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <h2 class="text-lg font-semibold">{gettext("Connection")}</h2>
            <button
              type="button"
              phx-click="check-again"
              class="btn btn-sm btn-ghost"
              disabled={@check == :loading or @census == :loading}
            >
              {gettext("Check again")}
            </button>
          </div>

          <.check_result check={@check} />

          <p :if={@checked_at} class="mt-3 text-xs text-base-content/60">
            {gettext("Checked at %{time}.", time: Calendar.strftime(@checked_at, "%H:%M:%S UTC"))}
          </p>
        </section>

        <section :if={@backend} id="image-backend-library" class="card card-pad max-w-2xl">
          <h2 class="text-lg font-semibold">{gettext("This site's images")}</h2>

          <p :if={@census == :loading} class="mt-4 text-sm text-base-content/60">
            {gettext("Counting…")}
          </p>

          <p :if={@census == :error} class="mt-4 text-sm text-error-ink">
            {gettext("Couldn't count this site's images. The server log has the reason.")}
          </p>

          <div :if={is_map(@census)}>
            <dl class="mt-4 grid grid-cols-[1fr_auto] gap-x-6 gap-y-2 text-sm">
              <dt>{gettext("Held by the backend")}</dt>
              <dd id="census-held" class="text-right font-mono">{@census.held}</dd>

              <dt>{gettext("Imported links it holds, not yet adopted")}</dt>
              <dd id="census-awaiting" class="text-right font-mono">{@census.awaiting}</dd>

              <dt>{gettext("Imported links it doesn't recognise")}</dt>
              <dd id="census-unrecognised" class="text-right font-mono">
                {@census.unrecognised}
              </dd>
            </dl>

            <p class="mt-4 text-xs text-base-content/60">
              {gettext(
                "An imported link is a row with a URL and no file in Kiln, so Kiln can't make its sizes, rotate it or delete the image. Adopting hands the backend the ones it already holds."
              )}
            </p>

            <div :if={@census.awaiting > 0} class="mt-4 space-y-2">
              <p class="text-sm">
                {gettext(
                  "To adopt them, run these on the server. The first only counts what it would adopt; the second adopts."
                )}
              </p>
              <p class="text-xs font-semibold">
                {gettext("From a release, such as Kiln's Docker image (in /app):")}
              </p>
              <pre class="overflow-x-auto rounded-lg bg-base-200 p-3 text-xs"><code id="adopt-release">{adopt_commands(:release, @current_org)}</code></pre>
              <p class="text-xs font-semibold">
                {gettext("From a source checkout, with Mix:")}
              </p>
              <pre class="overflow-x-auto rounded-lg bg-base-200 p-3 text-xs"><code id="adopt-mix">{adopt_commands(:mix, @current_org)}</code></pre>
              <p :if={@state != :active} class="text-xs text-warning-ink">
                {gettext("Adopting needs the backend's settings in place first.")}
              </p>
            </div>
          </div>
        </section>
      </div>
    </Layouts.console>
    """
  end

  attr :state, :atom, required: true

  defp selection_badge(assigns) do
    ~H"""
    <.badge :if={@state == :active} variant="success">{gettext("Receiving uploads")}</.badge>
    <.badge :if={@state == :unconfigured} variant="warning">{gettext("Missing settings")}</.badge>
    <.badge :if={@state == :none} variant="neutral">{gettext("None selected")}</.badge>
    <.badge :if={@state == :not_a_backend} variant="error">{gettext("Not installed")}</.badge>
    """
  end

  attr :check, :any, required: true

  defp check_result(assigns) do
    ~H"""
    <div class="mt-4 text-sm">
      <p :if={@check == :loading} class="text-base-content/60">{gettext("Checking…")}</p>

      <div :if={match?({:ok, _}, @check)} id="check-ok">
        <.badge variant="success">{gettext("Reachable")}</.badge>
        <dl
          :if={elem(@check, 1) != []}
          class="mt-3 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2"
        >
          <div :for={{label, value} <- elem(@check, 1)} class="contents">
            <dt class="text-base-content/60">{label}</dt>
            <dd class="font-mono">{value}</dd>
          </div>
        </dl>
      </div>

      <div :if={match?({:error, _}, @check)} id="check-error">
        <.badge variant="error">{gettext("Not reachable")}</.badge>
        <p class="mt-2 break-words text-error-ink">{elem(@check, 1)}</p>
      </div>

      <p :if={@check == :unsupported} id="check-unsupported" class="text-base-content/70">
        {gettext("This backend can't check its connection.")}
      </p>
    </div>
    """
  end

  # Each form a dry run, then the real one: a release has no Mix, so it calls
  # `KilnCMS.Release` through `rpc`. The default site's release command names no
  # org, so it carries no inner quotes for a `docker exec` or `ssh -C` wrapper
  # to strip.
  defp adopt_commands(:release, org) do
    org_opts =
      if org.id == KilnCMS.Accounts.default_org_id(), do: [], else: [~s(org: "#{org.id}")]

    rpc = &"bin/kiln_cms rpc 'KilnCMS.Release.adopt_image_backend(#{Enum.join(&1, ", ")})'"
    Enum.join([rpc.(org_opts ++ ["dry_run: true"]), rpc.(org_opts)], "\n")
  end

  defp adopt_commands(:mix, org) do
    mix = "mix kiln.media.adopt_image_backend --org #{org.id}"
    Enum.join([mix <> " --dry-run", mix], "\n")
  end
end
