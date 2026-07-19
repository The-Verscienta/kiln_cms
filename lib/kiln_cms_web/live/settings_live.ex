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
  alias KilnCMS.Accounts.WebAuthn

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
     # Transient enrolment state (secret + provisioning URI + QR) while confirming.
     |> assign(:enrolling, nil)
     # Freshly minted recovery codes, shown exactly once (#331 phase 2).
     |> assign(:recovery_codes, nil)
     # Passkeys (#331): registered credentials + the in-flight enrolment
     # challenge (parked in LV state between the JS create() round-trip).
     |> assign(:passkeys, WebAuthn.list(user))
     |> assign(:passkey_challenge, nil)}
  end

  # --- passkeys (#331) -------------------------------------------------------

  @impl true
  def handle_event("passkey_begin", params, socket) do
    user = socket.assigns.current_user
    challenge = WebAuthn.registration_challenge()

    {:noreply,
     socket
     |> assign(:passkey_challenge, challenge)
     |> push_event("passkey-register", %{
       publicKey: WebAuthn.registration_options(challenge, user),
       name: params["name"] || ""
     })}
  end

  def handle_event("passkey_attestation", payload, socket) do
    user = socket.assigns.current_user

    case socket.assigns.passkey_challenge do
      nil ->
        {:noreply, socket}

      challenge ->
        socket = assign(socket, :passkey_challenge, nil)

        case WebAuthn.register_passkey(user, challenge, payload) do
          {:ok, _passkey} ->
            {:noreply,
             socket
             |> assign(:passkeys, WebAuthn.list(user))
             |> put_flash(:info, gettext("Passkey added — you can sign in with it now."))}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Couldn't verify that passkey — try again."))}
        end
    end
  end

  def handle_event("passkey_error", _params, socket) do
    {:noreply,
     socket
     |> assign(:passkey_challenge, nil)
     |> put_flash(
       :error,
       gettext("Passkey setup was cancelled or isn't supported by this browser.")
     )}
  end

  def handle_event("remove_passkey", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    socket =
      with {:ok, passkey} <- Accounts.get_passkey(id, actor: user),
           :ok <- Accounts.remove_passkey(passkey, actor: user) do
        socket
        |> assign(:passkeys, WebAuthn.list(user))
        |> put_flash(:info, gettext("Passkey removed."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't remove that passkey."))
      end

    {:noreply, socket}
  end

  # --- two-factor authentication (#331) --------------------------------------

  @impl true
  def handle_event("start_totp", _params, socket) do
    user = socket.assigns.current_user

    case Accounts.setup_totp(user, %{}, actor: user) do
      {:ok, user} ->
        uri = Totp.otpauth_uri(user.totp_secret, to_string(user.email))

        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:enrolling, %{
           secret: Totp.base32_encode(user.totp_secret),
           uri: uri,
           qr_svg: qr_svg(uri)
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
         |> assign(:recovery_codes, Ash.Resource.get_metadata(user, :recovery_codes))
         |> put_flash(:info, gettext("Two-factor authentication is now on."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("That code isn't valid — try again."))}
    end
  end

  def handle_event("regenerate_recovery_codes", %{"code" => code}, socket) do
    user = socket.assigns.current_user

    case Accounts.regenerate_totp_recovery_codes(user, %{code: code}, actor: user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:recovery_codes, Ash.Resource.get_metadata(user, :recovery_codes))
         |> put_flash(
           :info,
           gettext("New recovery codes generated — the old ones no longer work.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("That code isn't valid — try again."))}
    end
  end

  def handle_event("dismiss_recovery_codes", _params, socket),
    do: {:noreply, assign(socket, :recovery_codes, nil)}

  def handle_event("disable_totp", %{"code" => code}, socket) do
    user = socket.assigns.current_user

    case Accounts.disable_totp(user, %{code: code}, actor: user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:totp_enabled?, false)
         |> assign(:recovery_codes, nil)
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

  # The otpauth URI as an inline QR SVG (eqrcode, pure Elixir). `nil` if
  # encoding fails for any reason — the setup key remains as the fallback.
  defp qr_svg(uri) do
    uri |> EQRCode.encode() |> EQRCode.svg(width: 176)
  rescue
    _ -> nil
  end

  attr :svg, :string, required: true

  # The SVG is generated locally by EQRCode from the otpauth URI we built —
  # never from user input — so rendering it raw is safe.
  # sobelow_skip ["XSS.Raw"]
  defp totp_qr(assigns) do
    ~H"""
    <div class="w-fit rounded-lg bg-white p-2" data-role="totp-qr">
      {Phoenix.HTML.raw(@svg)}
    </div>
    """
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

          <div
            :if={@recovery_codes}
            class="mb-4 space-y-2 rounded-lg border border-warning/50 bg-warning/10 p-4"
          >
            <p class="text-sm font-medium">
              {gettext("Your recovery codes — save them now, they won't be shown again.")}
            </p>
            <p class="text-xs text-base-content/70">
              {gettext("Each code signs you in once if you lose your authenticator.")}
            </p>
            <ul class="grid grid-cols-2 gap-x-6 gap-y-1 font-mono text-sm" data-role="recovery-codes">
              <li :for={code <- @recovery_codes}>{code}</li>
            </ul>
            <button type="button" phx-click="dismiss_recovery_codes" class="btn btn-sm btn-default">
              {gettext("I've saved them")}
            </button>
          </div>

          <div :if={@totp_enabled?} class="space-y-3">
            <p class="flex items-center gap-1.5 text-sm font-medium text-success">
              <.icon name="hero-shield-check" class="size-4" />
              {gettext("Two-factor authentication is on.")}
            </p>
            <p class="text-sm text-base-content/70">
              {gettext("%{count} unused recovery codes remain.",
                count: length(@current_user.totp_recovery_hashes || [])
              )}
            </p>
            <form
              id="regenerate-recovery-form"
              phx-submit="regenerate_recovery_codes"
              class="flex items-end gap-2"
            >
              <.input
                name="code"
                value=""
                type="text"
                inputmode="numeric"
                autocomplete="one-time-code"
                label={gettext("Enter a current code to generate new recovery codes")}
              />
              <.button type="submit" variant="ghost">{gettext("Regenerate")}</.button>
            </form>
            <form id="disable-totp-form" phx-submit="disable_totp" class="flex items-end gap-2">
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
                "Scan the QR code (or add the key) in your authenticator app, then enter the 6-digit code to confirm."
              )}
            </p>
            <.totp_qr :if={@enrolling.qr_svg} svg={@enrolling.qr_svg} />
            <p class="text-sm">
              {gettext("Setup key")}:
              <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-sm break-all">{@enrolling.secret}</code>
            </p>
            <details class="text-xs text-base-content/60">
              <summary class="cursor-pointer">{gettext("Provisioning URI")}</summary>
              <code class="break-all">{@enrolling.uri}</code>
            </details>
            <form id="confirm-totp-form" phx-submit="confirm_totp" class="flex items-end gap-2">
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

        <section class="card card-pad max-w-xl" id="passkeys" phx-hook="PasskeyEnroll">
          <h2 class="mb-1 text-lg font-medium">{gettext("Passkeys")}</h2>
          <p class="mb-4 text-sm text-base-content/60">
            {gettext(
              "Sign in with your device's fingerprint, face, or PIN instead of a password. A passkey verifies you on the device, so it counts as two factors on its own."
            )}
          </p>

          <ul :if={@passkeys != []} class="mb-4 divide-y divide-base-content/10">
            <li
              :for={passkey <- @passkeys}
              class="flex items-center justify-between gap-3 py-2"
              id={"passkey-#{passkey.id}"}
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-medium">{passkey.name}</p>
                <p class="text-xs text-base-content/60">
                  {gettext("Added %{date}",
                    date: Calendar.strftime(passkey.inserted_at, "%Y-%m-%d")
                  )}
                  <span :if={passkey.last_used_at}>
                    · {gettext("last used %{date}",
                      date: Calendar.strftime(passkey.last_used_at, "%Y-%m-%d")
                    )}
                  </span>
                </p>
              </div>
              <button
                type="button"
                phx-click="remove_passkey"
                phx-value-id={passkey.id}
                data-confirm={gettext("Remove this passkey? You can no longer sign in with it.")}
                aria-label={gettext("Remove passkey")}
                class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>

          <form phx-submit="passkey_begin" class="flex items-end gap-2" id="add-passkey-form">
            <.input
              name="name"
              value=""
              type="text"
              label={gettext("Name (e.g. \"MacBook Touch ID\")")}
              placeholder={gettext("Passkey")}
            />
            <.button type="submit" variant="primary">{gettext("Add a passkey")}</.button>
          </form>
          <p class="mt-2 text-xs text-base-content/60">
            {gettext("Your browser will prompt you to confirm with this device's screen lock.")}
          </p>
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
