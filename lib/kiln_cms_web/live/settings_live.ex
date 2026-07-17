defmodule KilnCMSWeb.SettingsLive do
  @moduledoc """
  Per-user account settings (`/editor/settings`): display-name profile, password
  change (#141), workflow notification preferences (#46), and a data export.
  Each signed-in user manages only their own account. Editor/admin only
  (`:live_editor_required`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Totp

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("Settings"))
     |> assign(:form, prefs_form(user))
     |> assign(:profile_form, profile_form(user))
     |> assign(:password_form, password_form(user))
     |> assign(:totp_enabled?, Accounts.totp_enabled?(user))
     # Transient enrolment state (secret + provisioning URI) while confirming.
     |> assign(:enrolling, nil)}
  end

  # --- two-factor authentication (#331) --------------------------------------

  @impl true
  def handle_event("start_totp", _params, socket) do
    user = socket.assigns.current_user

    case Accounts.setup_totp(user, %{}, actor: user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:enrolling, %{
           secret: Totp.base32_encode(user.totp_secret),
           uri: Totp.otpauth_uri(user.totp_secret, to_string(user.email))
         })}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't start two-factor setup."))}
    end
  end

  def handle_event("cancel_totp", _params, socket),
    do: {:noreply, assign(socket, :enrolling, nil)}

  def handle_event("confirm_totp", %{"code" => code}, socket) do
    user = socket.assigns.current_user

    case Accounts.confirm_totp(user, %{code: code}, actor: user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:totp_enabled?, true)
         |> assign(:enrolling, nil)
         |> put_flash(:info, gettext("Two-factor authentication is now on."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("That code isn't valid — try again."))}
    end
  end

  def handle_event("disable_totp", %{"code" => code}, socket) do
    user = socket.assigns.current_user

    case Accounts.disable_totp(user, %{code: code}, actor: user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:totp_enabled?, false)
         |> put_flash(:info, gettext("Two-factor authentication is now off."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("That code isn't valid — 2FA is still on."))}
    end
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
          <h2 class="mb-1 text-lg font-medium">{gettext("Two-factor authentication")}</h2>
          <p class="mb-4 text-sm text-base-content/60">
            {gettext(
              "Require a time-based code from an authenticator app (Google Authenticator, 1Password, …) as a second factor when you sign in."
            )}
          </p>

          <div :if={@totp_enabled?} class="space-y-3">
            <p class="flex items-center gap-1.5 text-sm font-medium text-success">
              <.icon name="hero-shield-check" class="size-4" />
              {gettext("Two-factor authentication is on.")}
            </p>
            <form phx-submit="disable_totp" class="flex items-end gap-2">
              <.input
                name="code"
                value=""
                type="text"
                inputmode="numeric"
                autocomplete="one-time-code"
                label={gettext("Enter a current code to turn it off")}
              />
              <.button type="submit" variant="danger">{gettext("Disable")}</.button>
            </form>
          </div>

          <div :if={!@totp_enabled? && @enrolling} class="space-y-3">
            <p class="text-sm text-base-content/70">
              {gettext(
                "Add this key to your authenticator app, then enter the 6-digit code to confirm."
              )}
            </p>
            <p class="text-sm">
              {gettext("Setup key")}:
              <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-sm break-all">{@enrolling.secret}</code>
            </p>
            <details class="text-xs text-base-content/60">
              <summary class="cursor-pointer">{gettext("Provisioning URI")}</summary>
              <code class="break-all">{@enrolling.uri}</code>
            </details>
            <form phx-submit="confirm_totp" class="flex items-end gap-2">
              <.input
                name="code"
                value=""
                type="text"
                inputmode="numeric"
                autocomplete="one-time-code"
                label={gettext("6-digit code")}
              />
              <.button type="submit" variant="primary">{gettext("Confirm")}</.button>
              <button type="button" phx-click="cancel_totp" class="btn btn-default">
                {gettext("Cancel")}
              </button>
            </form>
          </div>

          <div :if={!@totp_enabled? && !@enrolling}>
            <.button phx-click="start_totp" variant="primary">
              {gettext("Enable two-factor authentication")}
            </.button>
          </div>
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
