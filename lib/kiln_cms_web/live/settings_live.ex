defmodule KilnCMSWeb.SettingsLive do
  @moduledoc """
  Per-user account settings (`/editor/settings`): the sidebar preset, the
  content list's status marks (#1323), display-name profile and your access on
  this site (#2142), password change
  (#141), two-factor and passkeys, the account's active sessions (#1823),
  workflow notification preferences (#46), and a data export.
  Each signed-in user manages only their own account. Editor/admin only
  (`:live_editor_required`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.EnrolmentProof
  alias KilnCMS.Accounts.Errors.DemoAccountLocked
  alias KilnCMS.Accounts.Errors.LastSecondFactorRequired
  alias KilnCMS.Accounts.Errors.PasskeyLimitReached
  alias KilnCMS.Accounts.Errors.PasskeyRegistrationThrottled
  alias KilnCMS.Accounts.Passkey
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMS.Push
  alias KilnCMSWeb.RoleDisplay
  alias KilnCMSWeb.TotpEnrolment

  import KilnCMSWeb.RoleDisplay, only: [role_summary: 1]

  @status_marks %{"words" => :words, "trigrams" => :trigrams}

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     # "Your settings", as the nav names it (#1319): site configuration lives in
     # the Configure hub, and a page titled plain "Settings" invites the search
     # for it here.
     |> assign(:page_title, gettext("Your settings"))
     # The client and org the credential changes below are logged with (#2241).
     |> assign(:security_context, KilnCMS.Security.AuthEvents.context(socket))
     |> assign(:form, prefs_form(user))
     # The registration-notice switch (#2251), for anyone who would get the
     # notice on some site: the flag is one per account, across every site.
     |> assign(
       :registration_notices?,
       KilnCMS.Notifications.Registrations.administers_any_site?(user)
     )
     # The security-alert mute (#2245), for a member admin of some site: only
     # they get site alerts, and the mute is one per account, across sites.
     |> assign(:security_alert_mute?, KilnCMS.Security.Alerts.member_admin_anywhere?(user))
     |> assign(:profile_form, profile_form(user))
     # A "Saved" line beside the button (#1828), cleared by the next edit: the
     # flash alone was easy to miss on a long page.
     |> assign(:profile_saved?, false)
     |> assign_access(user)
     |> assign(:password_form, password_form(user, socket.assigns.current_org))
     # Demo mode (docs/demo-mode.md): the shared account's password, 2FA and
     # passkeys are fixed, so their forms give way to a note saying why. The
     # actions refuse regardless — this only spares a visitor the attempt.
     |> assign(:credentials_locked?, KilnCMS.Demo.locks_credentials?(user))
     # The authenticator-app flow (#331), shared with `/account/two-factor`.
     |> TotpEnrolment.init(session)
     # What the enrolment actions are told about this session, for the email
     # proof a site's requirement may ask for (#2247).
     |> assign(:enrolment_session, KilnCMSWeb.SignInMarker.enrolment_session(session))
     # Whether that proof is owed (#2872): this page has no step to give it,
     # so the add controls say where to go instead of only refusing.
     |> assign_proof_elsewhere()
     # Passkeys (#331): registered credentials + the in-flight enrolment
     # challenge (parked in LV state between the JS create() round-trip).
     |> assign(:passkeys, WebAuthn.list(user))
     |> assign(:passkey_challenge, nil)
     # Whether a site this account uses requires a second factor (#2247): if
     # so, the last one left has no "Disable" or "Remove", and a note says
     # why. The actions refuse regardless.
     |> assign(
       :second_factor_required?,
       KilnCMS.Accounts.TwoFactorRequirement.required_somewhere?(user)
     )
     # The most an account may hold (#2247): at it, the add form gives way to
     # a note, and the registration refuses regardless.
     |> assign(:passkey_limit, Passkey.max_per_account())
     # The outcome of the last attempt, shown in the section itself (#1829):
     # `{:ok | :error, message}` or nil.
     |> assign(:passkey_status, nil)
     # The account's own active sessions (#1823). `:current_session_jti` is
     # assigned by `KilnCMSWeb.SessionTracking` on every signed-in mount.
     |> assign(:sessions, Sessions.list(user))
     # This site's idle timeout for this account, if any (#2246), so the list
     # says why a session may end on its own.
     |> assign(:idle_timeout_minutes, idle_timeout_minutes(socket))
     # Web Push (#628). `push_available?` is the *server* half — this site has
     # a VAPID key, its own (#1560) or the deployment's; `push_supported?` is
     # the browser half, which only the hook can answer, so it starts
     # optimistic and is corrected on mount.
     |> assign_push_key()
     |> assign(:push_supported?, true)
     |> assign(:push_subscribed?, false)
     |> assign(:push_note, nil)
     |> assign(:push_devices, push_devices(user))}
  end

  defp push_devices(user), do: Push.list(user)

  # The enrolment actions' email-proof context (#2247): this site, this
  # session, and no proof. This page has no proof step (that is
  # `/account/two-factor`'s), so where the site asks for one the action
  # refuses.
  defp enrolment_context(socket),
    do:
      EnrolmentProof.context(
        socket.assigns.current_org,
        socket.assigns.enrolment_session,
        nil
      )

  # The email proof is `EnrolmentProof.decide/4`'s, the same call the actions
  # make: when it is owed, this page's adds are refused (it passes no proof),
  # and the setup page is where the code is emailed and entered. That page is
  # not served on a tenant site host, so the link there goes to the main
  # host's and says so (as `/account` does).
  defp assign_proof_elsewhere(socket) do
    %{current_user: user, current_org: org, enrolment_session: session} = socket.assigns
    host = KilnCMSWeb.SecondFactorGate.socket_host(socket)
    url = KilnCMSWeb.SecondFactorGate.setup_href(host)

    socket
    |> assign(:proof_elsewhere?, EnrolmentProof.required?(user, org && org.id, session))
    |> assign(:setup_url, url)
    |> assign(
      :setup_host,
      if(KilnCMSWeb.SecondFactorGate.setup_host?(host), do: nil, else: URI.parse(url).host)
    )
  end

  # "Your access" (#2142): the tier this page was reached with, as the policies
  # resolve it on this site, and when a temporary one changes. Read-only, and
  # only ever about the signed-in user.
  defp assign_access(socket, user),
    do: assign(socket, :access, RoleDisplay.site_access(user, socket.assigns.current_org))

  # The key the toggle hands the browser, and the one `Push.subscribe/4` is
  # told the browser used — one assign, so the two cannot differ.
  defp assign_push_key(socket) do
    key = Push.public_key(socket.assigns.current_org)

    socket
    |> assign(:push_key, key)
    |> assign(:push_available?, not is_nil(key))
  end

  # --- passkeys (#331) -------------------------------------------------------

  @impl true
  # Refused before the browser prompt, not after it: the registration would be
  # refused anyway, and a visitor shouldn't touch their fingerprint reader first.
  def handle_event("passkey_begin", _params, %{assigns: %{credentials_locked?: true}} = socket),
    do: {:noreply, put_flash(socket, :error, demo_locked_message())}

  # At the cap (#2247), for the same reason. Re-read rather than taken from the
  # list this page rendered: another tab may have added or removed one since.
  def handle_event("passkey_begin", params, socket) do
    user = socket.assigns.current_user
    passkeys = WebAuthn.list(user)

    if length(passkeys) >= Passkey.max_per_account() do
      {:noreply,
       socket
       |> assign(:passkeys, passkeys)
       |> assign(:passkey_status, {:error, passkey_limit_message()})
       |> put_flash(:error, passkey_limit_message())}
    else
      challenge = WebAuthn.registration_challenge()

      {:noreply,
       socket
       |> assign(:passkey_challenge, challenge)
       |> assign(:passkey_status, nil)
       |> push_event("passkey-register", %{
         publicKey: WebAuthn.registration_options(challenge, user),
         name: params["name"] || ""
       })}
    end
  end

  def handle_event("passkey_attestation", payload, socket) do
    user = socket.assigns.current_user

    case socket.assigns.passkey_challenge do
      nil ->
        {:noreply, socket}

      challenge ->
        socket = assign(socket, :passkey_challenge, nil)

        case WebAuthn.register_passkey(user, challenge, payload,
               context: Map.merge(socket.assigns.security_context, enrolment_context(socket))
             ) do
          {:ok, _passkey} ->
            message = gettext("Passkey added — you can sign in with it now.")

            {:noreply,
             socket
             |> assign(:passkeys, WebAuthn.list(user))
             |> assign(:passkey_status, {:ok, message})
             |> put_flash(:info, message)}

          {:error, reason} ->
            message =
              passkey_refusal(reason) ||
                TotpEnrolment.error_message(
                  reason,
                  gettext("Couldn't verify that passkey — try again.")
                )

            {:noreply,
             socket
             |> assign(:passkeys, WebAuthn.list(user))
             |> assign(:passkey_status, {:error, message})
             |> put_flash(:error, message)}
        end
    end
  end

  def handle_event("passkey_error", _params, socket) do
    message = gettext("Passkey setup was cancelled or isn't supported by this browser.")

    {:noreply,
     socket
     |> assign(:passkey_challenge, nil)
     |> assign(:passkey_status, {:error, message})
     |> put_flash(:error, message)}
  end

  # The browser's prompt can be dismissed without the hook ever hearing back
  # (a closed window, a stalled authenticator), which would leave the button
  # waiting for good. The challenge is single-use and server-side, so dropping
  # it here is all "cancel" needs.
  def handle_event("passkey_cancel", _params, socket),
    do: {:noreply, socket |> assign(:passkey_challenge, nil) |> assign(:passkey_status, nil)}

  def handle_event("remove_passkey", %{"id" => id}, socket) when is_binary(id) do
    user = socket.assigns.current_user

    socket =
      with {:ok, passkey} <- Accounts.get_passkey(id, actor: user),
           :ok <-
             Accounts.remove_passkey(passkey,
               actor: user,
               context: socket.assigns.security_context
             ) do
        socket
        |> assign(:passkeys, WebAuthn.list(user))
        |> assign(:passkey_status, {:ok, gettext("Passkey removed.")})
        |> put_flash(:info, gettext("Passkey removed."))
      else
        error ->
          put_flash(socket, :error, refusal_or(error, gettext("Couldn't remove that passkey.")))
      end

    {:noreply, socket}
  end

  # --- active sessions (#1823) ------------------------------------------------
  #
  # Both refuse on the shared demo account, like the credential forms: one
  # visitor signing out "all other sessions" would sign out every other visitor.

  def handle_event(
        "sign_out_session",
        _params,
        %{assigns: %{credentials_locked?: true}} = socket
      ),
      do: {:noreply, put_flash(socket, :error, demo_locked_message())}

  def handle_event("sign_out_session", %{"id" => jti}, socket) when is_binary(jti) do
    user = socket.assigns.current_user

    socket =
      case Sessions.revoke(user, jti) do
        :ok -> put_flash(socket, :info, gettext("Signed out of that session."))
        {:error, _error} -> put_flash(socket, :error, gettext("That session has already ended."))
      end

    {:noreply, assign(socket, :sessions, Sessions.list(user))}
  end

  def handle_event(
        "sign_out_other_sessions",
        _params,
        %{assigns: %{credentials_locked?: true}} = socket
      ),
      do: {:noreply, put_flash(socket, :error, demo_locked_message())}

  # Without the jti of this session there is no way to keep it, and "sign out
  # everything" is not what the button says.
  def handle_event(
        "sign_out_other_sessions",
        _params,
        %{assigns: %{current_session_jti: nil}} = socket
      ),
      do: {:noreply, put_flash(socket, :error, sign_out_others_failed())}

  def handle_event("sign_out_other_sessions", _params, socket) do
    %{current_user: user, current_session_jti: current} = socket.assigns

    socket =
      case Sessions.revoke_others(user, current) do
        {:ok, 0} ->
          put_flash(socket, :info, gettext("You weren't signed in anywhere else."))

        {:ok, count} ->
          put_flash(
            socket,
            :info,
            ngettext(
              "Signed out of %{count} other session.",
              "Signed out of %{count} other sessions.",
              count,
              count: count
            )
          )

        {:error, _error} ->
          put_flash(socket, :error, sign_out_others_failed())
      end

    {:noreply, assign(socket, :sessions, Sessions.list(user))}
  end

  # --- two-factor authentication (#331) --------------------------------------

  @impl true
  def handle_event("start_totp", _params, socket),
    do: {:noreply, TotpEnrolment.start(socket)}

  def handle_event("cancel_totp", _params, socket),
    do: {:noreply, TotpEnrolment.cancel(socket)}

  # The action asks for the email proof when the site requires a second factor
  # and this session signed in with only a password after the deadline
  # (#2247). This page offers no proof step, so then it is refused, and says
  # why.
  def handle_event("confirm_totp", %{"code" => code} = params, socket) when is_binary(code) do
    {_result, socket} = TotpEnrolment.confirm(socket, params, enrolment_context(socket))
    {:noreply, socket}
  end

  def handle_event("regenerate_recovery_codes", %{"code" => code}, socket) when is_binary(code) do
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

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           second_factor_error(error, gettext("That code isn't valid — try again."))
         )}
    end
  end

  def handle_event("dismiss_recovery_codes", _params, socket),
    do: {:noreply, assign(socket, :recovery_codes, nil)}

  def handle_event("disable_totp", %{"code" => code}, socket) when is_binary(code) do
    user = socket.assigns.current_user

    case Accounts.disable_totp(user, %{code: code},
           actor: user,
           context: socket.assigns.security_context
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:totp_enabled?, false)
         |> assign(:recovery_codes, nil)
         |> put_flash(:info, gettext("Two-factor authentication is now off."))}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           second_factor_error(error, gettext("That code isn't valid — 2FA is still on."))
         )}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"user" => params}, socket) when is_map(params) do
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

  # The content list's status marks (#1323). Only the one field is copied onto
  # the socket's user, for the reason `KilnCMSWeb.NavPreset` gives: the update's
  # return value need not carry what the session actor was loaded with.
  def handle_event("set_status_marks", %{"marks" => marks}, socket)
      when is_map_key(@status_marks, marks) do
    %{current_user: user} = socket.assigns

    case Accounts.set_status_marks(user, Map.fetch!(@status_marks, marks), actor: user) do
      {:ok, updated} ->
        {:noreply, assign(socket, :current_user, %{user | status_marks: updated.status_marks})}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Your choice could not be saved."))}
    end
  end

  # A pushed payload is client-chosen; give the guard above somewhere to fall.
  def handle_event("set_status_marks", _params, socket), do: {:noreply, socket}

  def handle_event("validate_profile", %{"user" => params}, socket) when is_map(params) do
    {:noreply,
     socket
     |> assign(:profile_form, AshPhoenix.Form.validate(socket.assigns.profile_form, params))
     |> assign(:profile_saved?, false)}
  end

  def handle_event("save_profile", %{"user" => params}, socket) when is_map(params) do
    case AshPhoenix.Form.submit(socket.assigns.profile_form, params: params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:profile_form, profile_form(user))
         |> assign(:profile_saved?, true)
         |> put_flash(:info, gettext("Profile updated."))}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:profile_form, form)
         |> assign(:profile_saved?, false)
         |> put_flash(:error, gettext("Couldn't update your profile."))}
    end
  end

  def handle_event("validate_password", %{"user" => params}, socket) when is_map(params) do
    {:noreply,
     assign(
       socket,
       :password_form,
       AshPhoenix.Form.validate(socket.assigns.password_form, params)
     )}
  end

  def handle_event("save_password", %{"user" => params}, socket) when is_map(params) do
    case AshPhoenix.Form.submit(socket.assigns.password_form, params: params) do
      {:ok, user} ->
        # The change revoked every stored token the account had, this
        # session's included (#734) — see `:change_password` for why this
        # device is not exempt — so there is nothing left to stay signed in
        # on. Say so and send them to sign in, rather than leave them on a
        # page whose next request (or the socket's reconnect after the
        # eviction) would bounce them there without explanation.
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Password changed. Sign in again with your new password.")
         )
         |> put_breach_warning(user)
         |> redirect(to: ~p"/sign-in")}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:password_form, form)
         |> put_flash(
           :error,
           # The submitted changeset carries the action's errors; the
           # `Phoenix.HTML.Form` wrapping it holds only rendered field errors.
           refusal_or(
             form.source.source,
             gettext("Couldn't change your password. Check your current password and try again.")
           )
         )}
    end
  end

  # The otpauth URI as an inline QR SVG (eqrcode, pure Elixir). `nil` if
  # encoding fails for any reason — the setup key remains as the fallback.

  # --- web push (#628) -------------------------------------------------------
  #
  # The browser is the source of truth for whether *this* device is subscribed:
  # a reviewer can revoke permission or clear site data and nothing tells us.
  # So the hook reports what it finds on mount and after every change, and the
  # server reconciles rather than assuming its rows are current.

  @impl true
  def handle_event("push_state", %{"subscribed" => subscribed?}, socket)
      when is_boolean(subscribed?) do
    {:noreply, assign(socket, push_subscribed?: subscribed?, push_note: nil)}
  end

  def handle_event("push_unsupported", _params, socket),
    do: {:noreply, assign(socket, push_supported?: false)}

  def handle_event("push_denied", _params, socket) do
    {:noreply,
     assign(socket,
       push_subscribed?: false,
       push_note:
         gettext(
           "Your browser is blocking notifications for this site. Allow them in the site settings, then try again."
         )
     )}
  end

  def handle_event("push_failed", _params, socket) do
    {:noreply,
     assign(socket,
       push_subscribed?: false,
       push_note: gettext("Couldn't register this device for notifications.")
     )}
  end

  def handle_event(
        "push_subscribed",
        %{"endpoint" => endpoint, "p256dh" => p256dh, "auth" => auth} = params,
        socket
      )
      when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) do
    user = socket.assigns.current_user

    case Push.subscribe(params, user, socket.assigns.current_org,
           public_key: socket.assigns.push_key
         ) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> assign(push_subscribed?: true, push_note: nil)
         |> assign(:push_devices, push_devices(user))
         |> put_flash(:info, gettext("Notifications are on for this device."))}

      # The site's key was rotated while this page was open (#1560): the
      # browser subscribed with a key nothing signs with any more. Hand it the
      # current one; the next click re-subscribes against it.
      {:error, :stale_key} ->
        {:noreply,
         socket
         |> assign_push_key()
         |> assign(
           push_subscribed?: false,
           push_note:
             gettext("This site's notification key has changed. Turn notifications on again.")
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           push_subscribed?: false,
           push_note: gettext("Couldn't register this device for notifications.")
         )}
    end
  end

  def handle_event("push_unsubscribed", %{"endpoint" => endpoint}, socket)
      when is_binary(endpoint) do
    user = socket.assigns.current_user
    Push.unsubscribe(endpoint, user)

    {:noreply,
     socket
     |> assign(push_subscribed?: false, push_note: nil)
     |> assign(:push_devices, push_devices(user))
     |> put_flash(:info, gettext("Notifications are off for this device."))}
  end

  def handle_event("remove_push_device", %{"id" => id}, socket) when is_binary(id) do
    user = socket.assigns.current_user

    socket =
      case Enum.find(push_devices(user), &(&1.id == id)) do
        nil ->
          socket

        device ->
          Push.remove(device, user)

          socket
          |> assign(:push_devices, push_devices(user))
          |> put_flash(:info, gettext("Device removed."))
      end

    {:noreply, socket}
  end

  defp nav_preset_value(user), do: Atom.to_string(KilnCMSWeb.ConsoleNav.preset(user))

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

  # The warning rides the same redirect as the "sign in again" note, as an
  # `:error` flash (the info one dismisses itself).
  defp put_breach_warning(socket, user) do
    case user.__metadata__ do
      %{password_breach: %{status: :breached}} ->
        put_flash(socket, :error, KilnCMS.Accounts.PasswordNotice.message())

      _none ->
        socket
    end
  end

  # The request org's breached-password policy applies (#2240), so the action
  # needs the tenant.
  defp password_form(user, org) do
    user
    |> AshPhoenix.Form.for_update(:change_password, actor: user, tenant: org, as: "user")
    |> to_form()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:settings}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("Your settings")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext("Manage your profile, password, and notification preferences.")}
          </p>
        </div>

        <.page_with_toc
          id="settings-toc"
          items={settings_toc(@push_available?)}
          class="max-w-4xl"
        >
          <div class="space-y-6">
            <%!-- The sidebar preset — the same choice as the switch at the foot of
              the sidebar, and the same event (`KilnCMSWeb.NavPreset`), which
              updates `@current_user` so both redraw together. --%>
            <section id="settings-sidebar" class="card card-pad max-w-xl scroll-mt-24">
              <h2 class="mb-1 text-lg font-medium">{gettext("Sidebar")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "Every screen stays in search (⌘K) either way; this only decides what the sidebar lists."
                )}
              </p>
              <div class="flex flex-wrap gap-2" role="group" aria-label={gettext("Sidebar")}>
                <button
                  :for={
                    {value, label} <- [
                      {"essentials", gettext("Essentials")},
                      {"everything", gettext("Everything")}
                    ]
                  }
                  type="button"
                  id={"settings-nav-preset-#{value}"}
                  phx-click="set_nav_preset"
                  phx-value-preset={value}
                  aria-pressed={to_string(nav_preset_value(@current_user) == value)}
                  class={[
                    "btn btn-sm",
                    nav_preset_value(@current_user) == value && "btn-primary"
                  ]}
                >
                  {label}
                </button>
              </div>
              <p class="mt-3 text-xs text-base-content/60">
                {if nav_preset_value(@current_user) == "essentials",
                  do:
                    gettext(
                      "Essentials: Home, Content, Media, Calendar, Tasks and Inbox, then Configure and Your settings."
                    ),
                  else: gettext("Everything: every screen you can open, grouped by section.")}
              </p>
            </section>

            <%!-- How the content list marks each row (#1323). Words by default;
              the trigram glyph is kept for the people who read it. --%>
            <section id="settings-status-marks" class="card card-pad max-w-xl scroll-mt-24">
              <h2 class="mb-1 text-lg font-medium">{gettext("Content list")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "How each item in the content list shows whether it is published, translated and scheduled."
                )}
              </p>
              <div class="flex flex-wrap gap-2" role="group" aria-label={gettext("Status marks")}>
                <button
                  :for={
                    {value, label} <- [
                      {:words, gettext("Words")},
                      {:trigrams, gettext("Trigram glyphs")}
                    ]
                  }
                  type="button"
                  id={"settings-status-marks-#{value}"}
                  phx-click="set_status_marks"
                  phx-value-marks={value}
                  aria-pressed={to_string(status_marks(@current_user) == value)}
                  class={["btn btn-sm", status_marks(@current_user) == value && "btn-primary"]}
                >
                  {label}
                </button>
              </div>
              <p class="mt-3 text-xs text-base-content/60">
                {if status_marks(@current_user) == :trigrams,
                  do:
                    gettext(
                      "Trigram glyphs: three lines per item — published at the bottom, translated in the middle, scheduled on top; solid means yes. Hover one for its reading."
                    ),
                  else:
                    gettext(
                      "Words: the state badge, the date an item publishes or unpublishes, and “Missing translations” when a language is still to do."
                    )}
              </p>
            </section>

            <section id="settings-profile" class="card card-pad max-w-xl scroll-mt-24">
              <h2 class="mb-1 text-lg font-medium">{gettext("Profile")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext("How your name appears to readers and to the people you work with.")}
              </p>

              <div id="settings-access" class="mb-4 space-y-1 rounded-md bg-base-200/60 p-3">
                <p class="text-sm font-medium">{gettext("Your access")}</p>
                <.role_summary
                  id="settings-access-role"
                  label={gettext("On this site:")}
                  access={@access}
                >
                  <:note :if={@access.source == :platform}>{gettext("platform admin")}</:note>
                </.role_summary>
                <p
                  :if={RoleDisplay.console_access_ends_at(@access)}
                  class="text-xs text-base-content/60"
                >
                  {gettext("Your access to this console ends at %{when}.",
                    when: KilnCMSWeb.RoleGrantForm.format(RoleDisplay.console_access_ends_at(@access))
                  )}
                </p>
              </div>

              <.form
                for={@profile_form}
                id="profile-form"
                phx-change="validate_profile"
                phx-submit="save_profile"
                class="space-y-3"
              >
                <.input
                  field={@profile_form[:name]}
                  type="text"
                  label={gettext("Display name (optional)")}
                  placeholder={gettext("e.g. Alex Rivera")}
                  autocomplete="name"
                  hint={
                    gettext(
                      "Shown as the author of content you publish, on your comments, and to people editing at the same time as you."
                    )
                  }
                />
                <div class="flex items-center gap-3">
                  <.button type="submit" variant="primary" phx-disable-with={gettext("Saving…")}>
                    {gettext("Save profile")}
                  </.button>
                  <p id="profile-saved" role="status" class="text-sm text-success">
                    <span :if={@profile_saved?} class="flex items-center gap-1">
                      <.icon name="hero-check-circle" class="size-4" />
                      {gettext("Saved.")}
                    </span>
                  </p>
                </div>
              </.form>
            </section>

            <section id="settings-password" class="card card-pad max-w-xl scroll-mt-24">
              <h2 class="mb-1 text-lg font-medium">{gettext("Password")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "Enter your current password, then choose a new one (at least 8 characters)."
                )}
              </p>

              <.demo_locked_note :if={@credentials_locked?} />
              <.form
                :if={!@credentials_locked?}
                for={@password_form}
                id="password-form"
                phx-change="validate_password"
                phx-submit="save_password"
                class="space-y-3"
              >
                <.input
                  field={@password_form[:current_password]}
                  type="password"
                  reveal
                  label={gettext("Current password")}
                  autocomplete="current-password"
                />
                <.input
                  field={@password_form[:password]}
                  type="password"
                  reveal
                  label={gettext("New password")}
                  autocomplete="new-password"
                />
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  reveal
                  label={gettext("Confirm new password")}
                  autocomplete="new-password"
                />
                <.button type="submit" variant="primary">{gettext("Change password")}</.button>
              </.form>
            </section>

            <section id="settings-two-factor" class="card card-pad max-w-xl scroll-mt-24">
              <h2 class="mb-1 text-lg font-medium">{gettext("Two-factor authentication")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "Require a time-based code from an authenticator app (Google Authenticator, 1Password, …) as a second factor when you sign in."
                )}
              </p>

              <TotpEnrolment.recovery_codes :if={@recovery_codes} codes={@recovery_codes} />

              <.demo_locked_note :if={@credentials_locked?} />

              <div :if={@totp_enabled? && !@enrolling && !@credentials_locked?} class="space-y-3">
                <p class="flex items-center gap-1.5 text-sm font-medium text-success">
                  <.icon name="hero-shield-check" class="size-4" />
                  {gettext("Two-factor authentication is on.")}
                </p>
                <p class="text-sm text-base-content/70">
                  {gettext("%{count} unused recovery codes remain.",
                    count: length(@current_user.totp_recovery_hashes || [])
                  )}
                </p>
                <%!-- After a recovery-code sign-in the live authenticator may be
                  gone; surface re-enrolment (backend already accepts
                  `recovery_login?`) instead of only disable/regenerate forms
                  that still need a live code. --%>
                <div
                  :if={@recovery_login?}
                  class="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm"
                >
                  <p class="font-medium text-warning-content">
                    {gettext("You signed in with a recovery code.")}
                  </p>
                  <p class="mt-1 text-base-content/70">
                    {gettext(
                      "Set up a new authenticator app so you can keep signing in without using another recovery code."
                    )}
                  </p>
                  <.proof_elsewhere_note
                    :if={@proof_elsewhere?}
                    id="totp-proof-elsewhere"
                    setup_url={@setup_url}
                    setup_host={@setup_host}
                    class="mt-3"
                  />
                  <.button phx-click="start_totp" variant="primary" class="mt-3">
                    {gettext("Set up a new authenticator")}
                  </.button>
                  <TotpEnrolment.added_mail_note />
                </div>
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
                <.last_factor_note :if={
                  last_factor?(@second_factor_required?, @totp_enabled?, @passkeys, :totp)
                } />
                <form
                  :if={!last_factor?(@second_factor_required?, @totp_enabled?, @passkeys, :totp)}
                  id="disable-totp-form"
                  phx-submit="disable_totp"
                  class="flex items-end gap-2"
                >
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

              <div :if={@enrolling && !@credentials_locked?}>
                <TotpEnrolment.setup enrolling={@enrolling} />
                <TotpEnrolment.added_mail_note />
              </div>

              <div :if={!@totp_enabled? && !@enrolling && !@credentials_locked?}>
                <.proof_elsewhere_note
                  :if={@proof_elsewhere?}
                  id="totp-proof-elsewhere"
                  setup_url={@setup_url}
                  setup_host={@setup_host}
                  class="mb-3"
                />
                <.button phx-click="start_totp" variant="primary">
                  {gettext("Enable two-factor authentication")}
                </.button>
                <TotpEnrolment.added_mail_note />
              </div>
            </section>

            <section
              class="card card-pad max-w-xl scroll-mt-24"
              id="passkeys"
              phx-hook="PasskeyEnroll"
            >
              <h2 class="mb-1 text-lg font-medium">{gettext("Passkeys")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "Sign in with your device's fingerprint, face, or PIN instead of a password. A passkey verifies you on the device, so it counts as two factors on its own."
                )}
              </p>

              <%!-- Whether any are set up, said in words (#1829): the list alone
                left "is a passkey active?" to be inferred from an empty space. --%>
              <p
                :if={@passkeys == []}
                id="passkeys-none"
                class="mb-4 flex items-center gap-1.5 text-sm text-base-content/70"
              >
                <.icon name="hero-key" class="size-4 shrink-0" />
                {gettext("No passkeys yet. You sign in with your password.")}
              </p>
              <p
                :if={@passkeys != []}
                id="passkeys-count"
                class="mb-2 flex items-center gap-1.5 text-sm font-medium text-success"
              >
                <.icon name="hero-shield-check" class="size-4 shrink-0" />
                {ngettext(
                  "You have %{count} passkey set up.",
                  "You have %{count} passkeys set up.",
                  length(@passkeys),
                  count: length(@passkeys)
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
                    :if={
                      !@credentials_locked? &&
                        !last_factor?(@second_factor_required?, @totp_enabled?, @passkeys, :passkey)
                    }
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

              <.demo_locked_note :if={@credentials_locked?} />
              <.last_factor_note :if={
                last_factor?(@second_factor_required?, @totp_enabled?, @passkeys, :passkey)
              } />
              <p
                :if={!@credentials_locked? && length(@passkeys) >= @passkey_limit}
                id="passkeys-at-limit"
                class="flex items-center gap-1.5 text-sm text-base-content/70"
              >
                <.icon name="hero-information-circle" class="size-4 shrink-0" />
                {passkey_limit_message()}
              </p>
              <.proof_elsewhere_note
                :if={
                  @proof_elsewhere? && !@credentials_locked? && !@passkey_challenge &&
                    length(@passkeys) < @passkey_limit
                }
                id="passkey-proof-elsewhere"
                setup_url={@setup_url}
                setup_host={@setup_host}
                class="mb-3"
              />
              <form
                :if={
                  !@credentials_locked? && !@passkey_challenge &&
                    length(@passkeys) < @passkey_limit
                }
                phx-submit="passkey_begin"
                class="flex items-end gap-2"
                id="add-passkey-form"
              >
                <.input
                  name="name"
                  value=""
                  type="text"
                  label={gettext("Name this passkey (optional)")}
                  placeholder={gettext("e.g. MacBook Touch ID")}
                />
                <.button type="submit" variant="primary" phx-disable-with={gettext("Starting…")}>
                  {gettext("Add a passkey")}
                </.button>
              </form>
              <%!-- While the browser's own prompt is open (#1829). Server state,
                not a client spinner: the challenge is set from `passkey_begin`
                until the hook reports back, either way. --%>
              <div
                :if={!@credentials_locked? && @passkey_challenge}
                id="passkey-waiting"
                class="flex flex-wrap items-center gap-3 rounded-lg border border-base-content/10 bg-base-200/50 p-3"
              >
                <.icon name="hero-arrow-path" class="size-4 shrink-0 motion-safe:animate-spin" />
                <p class="flex-1 text-sm" role="status">
                  {gettext("Waiting for your device… Follow your browser's prompt to finish.")}
                </p>
                <button type="button" phx-click="passkey_cancel" class="btn btn-sm btn-default">
                  {gettext("Cancel")}
                </button>
              </div>
              <p
                :if={!@credentials_locked? && length(@passkeys) < @passkey_limit}
                class="mt-2 text-xs text-base-content/70"
              >
                {gettext("Your browser will prompt you to confirm with this device's screen lock.")}
                <%!-- `Passkey.:register` mails the owner every time
                      (`NotifyFactorAdded`, `SecondFactorNotice`). --%>
                <span id="passkey-added-mail">
                  {gettext("We'll email you each time a passkey is added to your account.")}
                </span>
              </p>
              <p
                :if={@passkey_status}
                id="passkey-status"
                role="status"
                class={[
                  "mt-3 flex items-center gap-1.5 text-sm",
                  elem(@passkey_status, 0) == :ok && "text-success",
                  elem(@passkey_status, 0) == :error && "text-error"
                ]}
              >
                <.icon
                  name={
                    if elem(@passkey_status, 0) == :ok,
                      do: "hero-check-circle",
                      else: "hero-exclamation-circle"
                  }
                  class="size-4 shrink-0"
                />
                {elem(@passkey_status, 1)}
              </p>
            </section>

            <section id="settings-sessions" class="card card-pad max-w-xl scroll-mt-24">
              <h2 class="mb-1 text-lg font-medium">{gettext("Active sessions")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "The browsers and devices signed in to your account. If you don't recognize one, sign it out and change your password."
                )}
              </p>
              <p
                :if={@idle_timeout_minutes}
                id="sessions-idle-timeout"
                class="mb-4 flex items-start gap-2 text-sm text-base-content/70"
              >
                <.icon name="hero-clock" class="mt-0.5 size-4 shrink-0" />
                {ngettext(
                  "This site signs a browser out after %{count} minute without activity.",
                  "This site signs a browser out after %{count} minutes without activity.",
                  @idle_timeout_minutes
                )}
              </p>

              <.demo_locked_note :if={@credentials_locked?} />

              <div :if={!@credentials_locked?}>
                <ul id="session-list" class="mb-4 divide-y divide-base-content/10">
                  <li
                    :for={session <- sessions_current_first(@sessions, @current_session_jti)}
                    id={"session-#{session_dom_id(session)}"}
                    class="flex items-center justify-between gap-3 py-2"
                  >
                    <div class="flex min-w-0 items-start gap-3">
                      <.icon
                        name={session_icon(session)}
                        class="mt-0.5 size-5 shrink-0 text-base-content/60"
                      />
                      <div class="min-w-0">
                        <p class="flex flex-wrap items-center gap-2 text-sm font-medium">
                          <span class="truncate">{session_label(session)}</span>
                          <.badge :if={session.jti == @current_session_jti} variant="success">
                            {gettext("This session")}
                          </.badge>
                        </p>
                        <p class="text-xs text-base-content/60">
                          {session_activity(session, @current_session_jti)} · {gettext(
                            "signed in %{date}",
                            date: Calendar.strftime(session.created_at, "%Y-%m-%d")
                          )}
                        </p>
                      </div>
                    </div>
                    <button
                      :if={session.jti != @current_session_jti}
                      type="button"
                      phx-click="sign_out_session"
                      phx-value-id={session.jti}
                      phx-disable-with={gettext("Signing out…")}
                      aria-label={gettext("Sign out %{device}", device: session_label(session))}
                      class="btn btn-sm btn-default"
                    >
                      {gettext("Sign out")}
                    </button>
                  </li>
                </ul>

                <p
                  :if={Enum.all?(@sessions, &(&1.jti == @current_session_jti))}
                  id="sessions-only-this"
                  class="text-sm text-base-content/70"
                >
                  {gettext("You're not signed in anywhere else.")}
                </p>
                <button
                  :if={Enum.any?(@sessions, &(&1.jti != @current_session_jti))}
                  id="sign-out-other-sessions"
                  type="button"
                  phx-click="sign_out_other_sessions"
                  phx-disable-with={gettext("Signing out…")}
                  data-confirm={
                    gettext("Sign out every other browser and device? This one stays signed in.")
                  }
                  class="btn btn-sm btn-danger"
                >
                  {gettext("Sign out of all other sessions")}
                </button>
              </div>
            </section>

            <section id="settings-email-notifications" class="card card-pad max-w-xl scroll-mt-24">
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
                <.input
                  field={@form[:notify_on_comment]}
                  type="checkbox"
                  label={
                    gettext("Comments — replies on threads I'm in, and when someone @mentions me")
                  }
                />
                <.input
                  :if={@registration_notices?}
                  field={@form[:notify_on_registration]}
                  type="checkbox"
                  label={
                    gettext(
                      "New registrations — email me when someone is waiting for approval on a site I administer"
                    )
                  }
                />
                <div :if={@security_alert_mute?} id="notify-on-security-alert">
                  <.input
                    field={@form[:notify_on_security_alert]}
                    type="checkbox"
                    label={
                      gettext(
                        "Security alerts — email me about security events on sites I administer"
                      )
                    }
                  />
                  <p class="-mt-1 ml-6 text-xs text-base-content/70">
                    {gettext(
                      "This mutes the email for site alerts only; they still appear in your notifications. Platform alerts, and notices that a site's alerts were turned down, are always sent."
                    )}
                  </p>
                </div>

                <.button type="submit" variant="primary">
                  {gettext("Save preferences")}
                </.button>
              </.form>
            </section>

            <section
              :if={@push_available?}
              id="push-settings"
              class="card card-pad max-w-xl scroll-mt-24"
            >
              <h2 class="mb-1 text-lg font-medium">{gettext("Push notifications")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "Get a notification on this device when something needs your review. Install KilnCMS to your home screen first — on iPhone and iPad, notifications only work for the installed app."
                )}
              </p>

              <p class="mb-3 text-xs text-base-content/60">
                {gettext(
                  "Notifications never contain draft content — only that something is waiting, and what kind."
                )}
              </p>

              <button
                id="push-toggle"
                type="button"
                phx-hook="PushToggle"
                data-vapid-key={@push_key}
                data-enabled={to_string(@push_subscribed?)}
                disabled={not @push_supported?}
                class={[
                  "btn btn-sm",
                  if(@push_subscribed?, do: "btn-default", else: "btn-primary"),
                  not @push_supported? && "opacity-50"
                ]}
              >
                {if @push_subscribed?,
                  do: gettext("Turn off on this device"),
                  else: gettext("Turn on for this device")}
              </button>

              <p :if={not @push_supported?} class="mt-2 text-sm text-base-content/60">
                {gettext(
                  "This browser can't receive push notifications. On iPhone and iPad they need iOS 16.4 or later and the app added to your home screen."
                )}
              </p>

              <p :if={@push_note} class="mt-2 text-sm text-warning">{@push_note}</p>

              <div :if={@push_devices != []} class="mt-4">
                <h3 class="mb-2 text-sm font-medium">{gettext("Devices receiving notifications")}</h3>
                <ul class="space-y-2">
                  <li
                    :for={device <- @push_devices}
                    class="flex items-center justify-between gap-3 rounded border border-base-content/10 px-3 py-2 text-sm"
                  >
                    <span>
                      {device.label}
                      <span class="ml-2 text-xs text-base-content/50">
                        {if device.last_delivered_at,
                          do: gettext("last used %{ago} ago", ago: ago(device.last_delivered_at)),
                          else: gettext("not used yet")}
                      </span>
                    </span>
                    <button
                      type="button"
                      phx-click="remove_push_device"
                      data-confirm={gettext("Stop sending notifications to this device?")}
                      phx-value-id={device.id}
                      class="btn btn-sm btn-ghost"
                    >
                      {gettext("Remove")}
                    </button>
                  </li>
                </ul>
              </div>
            </section>

            <section id="settings-data" class="card card-pad max-w-xl scroll-mt-24">
              <h2 class="mb-1 text-lg font-medium">{gettext("Your data")}</h2>
              <p class="mb-4 text-sm text-base-content/60">
                {gettext(
                  "Download a copy of your account profile and notification preferences as JSON."
                )}
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
        </.page_with_toc>
      </div>
    </Layouts.console>
    """
  end

  # The "On this page" contents (#1680): one entry per section, in page order,
  # each an id the section above carries. Push is listed only when its
  # section renders — a link to a missing id would jump nowhere.
  defp settings_toc(push_available?) do
    Enum.reject(
      [
        {"settings-sidebar", gettext("Sidebar")},
        {"settings-status-marks", gettext("Content list")},
        {"settings-profile", gettext("Profile")},
        {"settings-password", gettext("Password")},
        {"settings-two-factor", gettext("Two-factor authentication")},
        {"passkeys", gettext("Passkeys")},
        {"settings-sessions", gettext("Active sessions")},
        {"settings-email-notifications", gettext("Email notifications")},
        push_available? && {"push-settings", gettext("Push notifications")},
        {"settings-data", gettext("Your data")}
      ],
      &(&1 == false)
    )
  end

  defp sign_out_others_failed,
    do: gettext("Couldn't sign out of your other sessions. Try again.")

  # --- the session list (#1823) ----------------------------------------------

  # This session first, then the rest most recently used first (the read's
  # own order).
  defp idle_timeout_minutes(socket) do
    case socket.assigns[:current_org] do
      %{id: org_id} ->
        org_id
        |> KilnCMS.Accounts.IdleTimeout.policy()
        |> KilnCMS.Accounts.IdleTimeout.timeout_seconds(
          KilnCMSWeb.LiveUserAuth.effective_tier(socket)
        )
        |> case do
          nil -> nil
          seconds -> div(seconds, 60)
        end

      _no_site ->
        nil
    end
  end

  defp sessions_current_first(sessions, current_jti) do
    {current, others} = Enum.split_with(sessions, &(&1.jti == current_jti))
    current ++ others
  end

  # The jti is the row's identity, but it is a bearer secret's name rather than
  # something to scatter through the DOM's ids; a short hash is unique enough
  # for a list of one person's sessions and says nothing.
  defp session_dom_id(%{jti: jti}),
    do: :crypto.hash(:sha256, jti) |> binary_part(0, 6) |> Base.url_encode64(padding: false)

  defp session_label(%{browser: browser, platform: platform})
       when is_binary(browser) and is_binary(platform),
       do: gettext("%{browser} on %{platform}", browser: browser, platform: platform)

  defp session_label(%{browser: browser}) when is_binary(browser), do: browser
  defp session_label(%{platform: platform}) when is_binary(platform), do: platform
  defp session_label(_session), do: gettext("Unknown browser")

  defp session_icon(%{platform: platform}) when platform in ["iOS", "Android"],
    do: "hero-device-phone-mobile"

  defp session_icon(_session), do: "hero-computer-desktop"

  # "Active now" for the page you are reading; otherwise the last recorded use,
  # which is written at most every few minutes and so is said approximately.
  defp session_activity(%{jti: jti}, jti), do: gettext("Active now")

  defp session_activity(%{last_used_at: %DateTime{} = at}, _current),
    do: gettext("last active %{ago} ago", ago: ago(at))

  defp session_activity(_session, _current), do: gettext("no recent activity recorded")

  # A spent second-factor budget (#727) and a wrong code are opposite advice:
  # "check your authenticator" sends someone to type five more codes into a
  # budget that has nothing left. Telling them apart discloses nothing — whoever
  # is here is already signed in as this account.
  # A spent second-factor budget, a demo-mode refusal, or the handler's own
  # message — the same wording the authenticator-app flow uses.
  defp second_factor_error(error, wrong_code_message),
    do: TotpEnrolment.error_message(error, wrong_code_message)

  # A demo-mode refusal (`DemoAccountLocked`) or the last factor a site
  # requires (`LastSecondFactorRequired`) says so; anything else keeps the
  # handler's own message. Takes an Ash error or a changeset (both carry
  # `errors`), or whatever an `{:error, _}` held.
  defp refusal_or(%{errors: errors}, fallback) do
    Enum.find_value(List.wrap(errors), fallback, fn
      %DemoAccountLocked{} -> demo_locked_message()
      %LastSecondFactorRequired{} -> TotpEnrolment.last_factor_message()
      _other -> nil
    end)
  end

  defp refusal_or({:error, error}, fallback), do: refusal_or(error, fallback)
  defp refusal_or(_error, fallback), do: fallback

  # The registration's own refusals (#2247): the account is at the passkey cap,
  # or has added too many this hour. `nil` for anything else.
  defp passkey_refusal(%{errors: errors}) do
    Enum.find_value(List.wrap(errors), fn
      %PasskeyLimitReached{} ->
        passkey_limit_message()

      %PasskeyRegistrationThrottled{retry_after_seconds: seconds} ->
        gettext(
          "You've added several passkeys in a short time. Try again in %{minutes} minutes.",
          minutes: max(div(seconds + 59, 60), 1)
        )

      _other ->
        nil
    end)
  end

  defp passkey_refusal(_reason), do: nil

  defp passkey_limit_message do
    gettext("You have %{max} passkeys, the most an account can hold. Remove one to add another.",
      max: Passkey.max_per_account()
    )
  end

  defp demo_locked_message, do: TotpEnrolment.demo_locked_message()

  # The one factor this account has left, while a site requires one (#2247):
  # the authenticator app with no passkey, or the only passkey with no app.
  defp last_factor?(false = _required?, _totp?, _passkeys, _kind), do: false
  defp last_factor?(true, totp?, passkeys, :totp), do: totp? and passkeys == []
  defp last_factor?(true, totp?, passkeys, :passkey), do: not totp? and length(passkeys) == 1

  defp last_factor_note(assigns) do
    ~H"""
    <p
      id="last-factor-note"
      class="flex items-start gap-1.5 text-sm text-base-content/70"
    >
      <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
      {TotpEnrolment.last_factor_message()}
    </p>
    """
  end

  attr :id, :string, required: true
  attr :setup_url, :string, required: true
  attr :setup_host, :string, default: nil, doc: "set when the setup page is on another host"
  attr :class, :any, default: nil

  # Up front, where `RequireEnrolmentProof` would refuse this page's add: the
  # refusal flash ("Confirm your email address before adding a second
  # factor.") stays as the backstop.
  defp proof_elsewhere_note(assigns) do
    ~H"""
    <div
      id={@id}
      class={["rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm", @class]}
    >
      <p class="flex items-start gap-1.5">
        <.icon name="hero-envelope" class="mt-0.5 size-4 shrink-0" />
        {gettext(
          "Before you add a second factor, you need to confirm your email address with a code we send you. Do that on the two-step sign-in page."
        )}
      </p>
      <p :if={@setup_host} class="mt-1 text-base-content/70">
        {gettext("This opens on %{host}, where you sign in again.", host: @setup_host)}
      </p>
      <.link href={@setup_url} class="btn btn-sm btn-default mt-2">
        {gettext("Set up two-step sign-in")}
      </.link>
    </div>
    """
  end

  defp demo_locked_note(assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 text-sm text-base-content/70" data-role="demo-locked">
      <.icon name="hero-lock-closed" class="size-4 shrink-0" />
      {demo_locked_message()}
    </p>
    """
  end
end
