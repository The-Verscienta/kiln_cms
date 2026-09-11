defmodule KilnCMSWeb.SetupLive do
  @moduledoc """
  First-run setup wizard at `/setup` (#1317).

  Three steps — the admin account, the site's identity, a review — ending in
  one call to `KilnCMS.Accounts.Bootstrap.create_first_admin/1` and, with the
  created admin as the actor, an ordinary branding save. The wizard holds no
  privilege of its own: every write runs with authorization on, and the mount
  gate here is only UX — the enforceable gates (the `:bootstrap_admin` policy
  and the advisory lock) live in the core and hold for callers this LiveView
  never sees.

  Renders only while `Bootstrap.bootstrapped?/0` is false; afterwards `/setup`
  redirects home, permanently. Dev/CI never see it — `mix setup` seeds an
  admin. The wizard deliberately does not sign the operator in: creating a
  session cookie from a LiveView means minting tokens outside the normal
  password flow, and the operator typed this password five seconds ago — the
  finish screen sends them to `/sign-in`, second factors and all.
  """
  use KilnCMSWeb, :live_view

  require Logger

  alias KilnCMS.Accounts.Bootstrap
  alias KilnCMS.Branding
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Validations.BrandTokens

  @impl true
  def mount(_params, _session, socket) do
    if Bootstrap.bootstrapped?() do
      {:ok, redirect(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, gettext("Set up your site"))
       |> assign(:step, 1)
       |> assign(:admin, %{
         "email" => "",
         "name" => "",
         "password" => "",
         "password_confirmation" => ""
       })
       |> assign(:site, %{"site_name" => "", "brand_color" => "", "theme" => "standard"})
       |> assign(:admin_error, nil)
       |> assign(:preview, nil)}
    end
  end

  @impl true
  def handle_event("validate_admin", %{"admin" => params}, socket) when is_map(params) do
    {:noreply, socket |> assign(:admin, params) |> assign(:admin_error, nil)}
  end

  def handle_event("continue_admin", %{"admin" => params}, socket) when is_map(params) do
    params = Map.merge(socket.assigns.admin, params)

    case admin_problem(params) do
      nil -> {:noreply, socket |> assign(:admin, params) |> assign(:step, 2)}
      problem -> {:noreply, socket |> assign(:admin, params) |> assign(:admin_error, problem)}
    end
  end

  def handle_event("validate_site", %{"site" => params}, socket) when is_map(params) do
    {:noreply, socket |> assign(:site, params) |> assign_preview(params)}
  end

  def handle_event("continue_site", %{"site" => params}, socket) when is_map(params) do
    params = Map.merge(socket.assigns.site, params)
    {:noreply, socket |> assign(:site, params) |> assign_preview(params) |> assign(:step, 3)}
  end

  def handle_event("back", %{"to" => to}, socket) when to in ["1", "2"] do
    {:noreply, assign(socket, :step, String.to_integer(to))}
  end

  def handle_event("finish", _params, socket) do
    admin = socket.assigns.admin

    case Bootstrap.create_first_admin(%{
           email: admin["email"],
           name: presence(admin["name"]),
           password: admin["password"],
           password_confirmation: admin["password_confirmation"]
         }) do
      {:ok, user} ->
        save_branding(socket, user)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Your site is ready — sign in with the account you just created.")
         )
         |> redirect(to: ~p"/sign-in")}

      {:error, :already_bootstrapped} ->
        # Someone else finished first (a race, or a second tab). Nothing to do
        # here — the instance has its admin.
        {:noreply, redirect(socket, to: ~p"/")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:step, 1)
         |> assign(
           :admin_error,
           ash_error_message(error, fallback: gettext("The account could not be created."))
         )}
    end
  end

  # Lightweight step gate so obvious problems surface next to the fields rather
  # than at Finish. The action re-validates all of it — this duplicates only
  # what makes for a decent form, and the bounds match `:bootstrap_admin`'s.
  defp admin_problem(params) do
    cond do
      not String.contains?(params["email"] || "", "@") ->
        gettext("Enter the email address you will sign in with.")

      String.length(params["password"] || "") < 8 ->
        gettext("The password needs at least 8 characters.")

      params["password"] != params["password_confirmation"] ->
        gettext("The passwords don't match.")

      true ->
        nil
    end
  end

  # Branding is optional and its absence must not fail the bootstrap: the admin
  # exists either way, and an error here is recoverable in the console. Runs as
  # the created admin — a platform admin passes the org-admin write policy on
  # every org, so no bypass is needed.
  defp save_branding(socket, user) do
    attrs =
      %{
        "site_name" => presence(socket.assigns.site["site_name"]),
        "brand_color" => presence(socket.assigns.site["brand_color"]),
        "theme" => socket.assigns.site["theme"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(Map.drop(attrs, ["theme"])) > 0 or attrs["theme"] != "standard" do
      case CMS.save_site_branding(attrs,
             actor: user,
             tenant: socket.assigns.current_org
           ) do
        {:ok, _row} ->
          :ok

        {:error, error} ->
          # Recoverable in the console, so it must not fail the bootstrap —
          # but "who finds out?": the operator does, in the log, not nobody.
          Logger.warning("first-run branding save failed: #{Exception.message(error)}")
      end
    end

    :ok
  end

  defp assign_preview(socket, params) do
    case Branding.Color.derive(BrandTokens.normalize_color(params["brand_color"]) || "") do
      {:ok, color} -> assign(socket, :preview, color)
      :error -> assign(socket, :preview, nil)
    end
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp theme_options do
    labels = %{
      standard: gettext("Standard — the stock look"),
      editorial: gettext("Editorial — serif, narrower reading column"),
      studio: gettext("Studio — wide, bold display headings"),
      monograph: gettext("Monograph — condensed display type, full-bleed images")
    }

    Enum.map(Branding.themes(), fn theme ->
      {Map.get(labels, theme, Phoenix.Naming.humanize(theme)), Atom.to_string(theme)}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div :if={KilnCMS.Environment.label()} class="mt-6 flex justify-center">
      <Layouts.environment_banner />
    </div>

    <main id="main" class="mx-auto w-full max-w-xl px-4 py-12 sm:px-6">
      <div class="mb-8 text-center">
        <h1 class="text-2xl font-semibold tracking-tight">{gettext("Set up your site")}</h1>
        <p class="mt-2 text-sm text-base-content/70">
          {gettext("Three quick steps: your admin account, your site's look, and you're in.")}
        </p>
      </div>

      <ol class="mb-8 flex items-center justify-center gap-2 text-xs" aria-label={gettext("Steps")}>
        <li
          :for={
            {label, number} <- [{gettext("Account"), 1}, {gettext("Site"), 2}, {gettext("Finish"), 3}]
          }
          aria-current={@step == number && "step"}
          class={[
            "rounded-full px-3 py-1",
            if(@step == number,
              do: "bg-primary text-primary-content font-semibold",
              else: "bg-base-200 text-base-content/70"
            )
          ]}
        >
          {label}
        </li>
      </ol>

      <div :if={@step == 1} class="card card-pad space-y-4">
        <h2 class="text-sm font-medium">{gettext("Create your admin account")}</h2>

        <form id="setup-admin-form" phx-change="validate_admin" phx-submit="continue_admin">
          <div class="space-y-4">
            <.input
              name="admin[email]"
              type="email"
              value={@admin["email"]}
              label={gettext("Email")}
              autocomplete="username"
            />
            <.input
              name="admin[name]"
              type="text"
              value={@admin["name"]}
              label={gettext("Display name (optional)")}
              hint={gettext("Shown as the author byline on what you publish.")}
            />
            <.input
              name="admin[password]"
              type="password"
              value={@admin["password"]}
              label={gettext("Password")}
              autocomplete="new-password"
              hint={gettext("At least 8 characters.")}
            />
            <.input
              name="admin[password_confirmation]"
              type="password"
              value={@admin["password_confirmation"]}
              label={gettext("Password (again)")}
              autocomplete="new-password"
            />

            <p :if={@admin_error} class="text-sm text-error" role="alert">{@admin_error}</p>

            <.button type="submit" variant="primary">{gettext("Continue")}</.button>
          </div>
        </form>
      </div>

      <div :if={@step == 2} class="card card-pad space-y-4">
        <h2 class="text-sm font-medium">{gettext("Name your site")}</h2>
        <p class="text-sm text-base-content/70">
          {gettext("All of this is optional and can be changed later under Branding.")}
        </p>

        <form id="setup-site-form" phx-change="validate_site" phx-submit="continue_site">
          <div class="space-y-4">
            <.input
              name="site[site_name]"
              type="text"
              value={@site["site_name"]}
              label={gettext("Site name")}
            />
            <.input
              name="site[brand_color]"
              type="text"
              value={@site["brand_color"]}
              label={gettext("Primary colour")}
              placeholder="#1d4ed8"
              hint={
                gettext(
                  "The light and dark variants, and the text colour on buttons, are derived from this so they always meet WCAG AA."
                )
              }
            />

            <div :if={@preview} class="flex items-center gap-2">
              <span
                class="inline-flex items-center rounded-md px-3 py-1.5 text-xs font-semibold"
                style={"background-color:#{@preview.light_primary};color:#{@preview.light_content}"}
              >
                {gettext("Light")}
              </span>
              <span
                class="inline-flex items-center rounded-md px-3 py-1.5 text-xs font-semibold"
                style={"background-color:#{@preview.dark_primary};color:#{@preview.dark_content}"}
              >
                {gettext("Dark")}
              </span>
            </div>

            <.input
              name="site[theme]"
              type="select"
              value={@site["theme"]}
              label={gettext("Theme")}
              options={theme_options()}
              hint={gettext("Typography and page width for the public pages.")}
            />

            <div class="flex items-center gap-3">
              <.button type="button" phx-click="back" phx-value-to="1">{gettext("Back")}</.button>
              <.button type="submit" variant="primary">{gettext("Continue")}</.button>
            </div>
          </div>
        </form>
      </div>

      <div :if={@step == 3} class="card card-pad space-y-4">
        <h2 class="text-sm font-medium">{gettext("Ready to finish")}</h2>

        <dl class="space-y-2 text-sm">
          <div class="flex justify-between gap-4">
            <dt class="text-base-content/70">{gettext("Admin")}</dt>
            <dd class="font-medium">{@admin["email"]}</dd>
          </div>
          <div class="flex justify-between gap-4">
            <dt class="text-base-content/70">{gettext("Site name")}</dt>
            <dd class="font-medium">{presence(@site["site_name"]) || gettext("(default)")}</dd>
          </div>
          <div class="flex justify-between gap-4">
            <dt class="text-base-content/70">{gettext("Theme")}</dt>
            <dd class="font-medium">{@site["theme"]}</dd>
          </div>
        </dl>

        <div class="rounded-lg border border-base-300 p-4 text-sm text-base-content/70">
          <p class="font-medium text-base-content">
            {gettext("A few things stay with the operator")}
          </p>
          <p class="mt-1">
            {gettext(
              "Object storage, outgoing email, and search are configured with environment variables, not in the console — see the environment variables guide in the docs when you need them."
            )}
          </p>
        </div>

        <div class="flex items-center gap-3">
          <.button type="button" phx-click="back" phx-value-to="2">{gettext("Back")}</.button>
          <.button type="button" variant="primary" phx-click="finish">
            {gettext("Create account and finish")}
          </.button>
        </div>
      </div>
    </main>
    """
  end
end
