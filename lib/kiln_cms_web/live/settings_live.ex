defmodule KilnCMSWeb.SettingsLive do
  @moduledoc """
  Per-user account settings (`/editor/settings`): display-name profile, password
  change (#141), workflow notification preferences (#46), and a data export.
  Each signed-in user manages only their own account. Editor/admin only
  (`:live_editor_required`).
  """
  use KilnCMSWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("Settings"))
     |> assign(:form, prefs_form(user))
     |> assign(:profile_form, profile_form(user))
     |> assign(:password_form, password_form(user))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:form, prefs_form(user))
         |> put_flash(:info, gettext("Notification preferences saved."))}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> put_flash(:error, gettext("Couldn't save your preferences."))}
    end
  end

  def handle_event("validate_profile", %{"user" => params}, socket) do
    {:noreply,
     assign(socket, :profile_form, AshPhoenix.Form.validate(socket.assigns.profile_form, params))}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.profile_form, params: params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:profile_form, profile_form(user))
         |> put_flash(:info, gettext("Profile updated."))}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:profile_form, form)
         |> put_flash(:error, gettext("Couldn't update your profile."))}
    end
  end

  def handle_event("validate_password", %{"user" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :password_form,
       AshPhoenix.Form.validate(socket.assigns.password_form, params)
     )}
  end

  def handle_event("save_password", %{"user" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.password_form, params: params) do
      {:ok, user} ->
        # Reset the form so the password fields clear after a successful change.
        {:noreply,
         socket
         |> assign(:password_form, password_form(user))
         |> put_flash(:info, gettext("Password changed."))}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:password_form, form)
         |> put_flash(
           :error,
           gettext("Couldn't change your password. Check your current password and try again.")
         )}
    end
  end

  defp prefs_form(user) do
    user
    |> AshPhoenix.Form.for_update(:update_notification_prefs, actor: user, as: "user")
    |> to_form()
  end

  defp profile_form(user) do
    user
    |> AshPhoenix.Form.for_update(:update_profile, actor: user, as: "user")
    |> to_form()
  end

  defp password_form(user) do
    user
    |> AshPhoenix.Form.for_update(:change_password, actor: user, as: "user")
    |> to_form()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:settings}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("Settings")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext("Manage your profile, password, and notification preferences.")}
          </p>
        </div>

        <section class="card card-pad max-w-xl">
          <h2 class="mb-1 text-lg font-medium">{gettext("Profile")}</h2>
          <p class="mb-4 text-sm text-base-content/60">
            {gettext("Your display name is used as the author byline on content you publish.")}
          </p>

          <.form
            for={@profile_form}
            id="profile-form"
            phx-change="validate_profile"
            phx-submit="save_profile"
            class="space-y-3"
          >
            <.input field={@profile_form[:name]} type="text" label={gettext("Display name")} />
            <.button type="submit" variant="primary">{gettext("Save profile")}</.button>
          </.form>
        </section>

        <section class="card card-pad max-w-xl">
          <h2 class="mb-1 text-lg font-medium">{gettext("Password")}</h2>
          <p class="mb-4 text-sm text-base-content/60">
            {gettext("Enter your current password, then choose a new one (at least 8 characters).")}
          </p>

          <.form
            for={@password_form}
            id="password-form"
            phx-change="validate_password"
            phx-submit="save_password"
            class="space-y-3"
          >
            <.input
              field={@password_form[:current_password]}
              type="password"
              label={gettext("Current password")}
              autocomplete="current-password"
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label={gettext("New password")}
              autocomplete="new-password"
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label={gettext("Confirm new password")}
              autocomplete="new-password"
            />
            <.button type="submit" variant="primary">{gettext("Change password")}</.button>
          </.form>
        </section>

        <section class="card card-pad max-w-xl">
          <h2 class="mb-1 text-lg font-medium">{gettext("Email notifications")}</h2>
          <p class="mb-4 text-sm text-base-content/60">
            {gettext("All notifications are on by default. Uncheck any you'd rather not receive.")}
          </p>

          <.form
            for={@form}
            id="notification-prefs-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-3"
          >
            <.input
              field={@form[:notify_on_review_request]}
              type="checkbox"
              label={gettext("Review requested — content I can approve was submitted for review")}
            />
            <.input
              field={@form[:notify_on_publish]}
              type="checkbox"
              label={gettext("Published — content I authored went live")}
            />
            <.input
              field={@form[:notify_on_return_to_draft]}
              type="checkbox"
              label={gettext("Changes requested — content I authored was returned to draft")}
            />

            <.button type="submit" variant="primary">
              {gettext("Save preferences")}
            </.button>
          </.form>
        </section>

        <section class="card card-pad max-w-xl">
          <h2 class="mb-1 text-lg font-medium">{gettext("Your data")}</h2>
          <p class="mb-4 text-sm text-base-content/60">
            {gettext("Download a copy of your account profile and notification preferences as JSON.")}
          </p>

          <.link
            href={~p"/editor/account/export.json"}
            download="kiln-account-export.json"
            class="btn btn-default"
          >
            <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
            {gettext("Export my data")}
          </.link>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
