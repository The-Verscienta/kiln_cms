defmodule KilnCMSWeb.TwoFactorSetupLive do
  @moduledoc """
  Setting up two-step sign-in (`/account/two-factor`, #2247): where a site that
  requires a second factor sends an account that has none.

  Open to every signed-in account, viewers included (`:authenticated_routes`):
  a site can require a second factor of everyone, and `/editor/settings`, the
  other place that offers one, is editors only.

  Served only on the main host and console hosts
  (`KilnCMSWeb.SecondFactorGate.setup_host?/1`): on a tenant site host it
  redirects to the main host's page before it mounts
  (`KilnCMSWeb.SecondFactorGate.setup_host/1`), where the account signs in
  again. A site host cannot register a passkey, and is the origin a site's
  injected code runs on, which must not reach a member's factors.

  ## What it shows

    * why: the site, and whether the requirement holds the account now or
      from a date (or that it is optional here);
    * the email proof, when `KilnCMS.Accounts.EnrolmentProof` asks for one:
      a password session past the deadline confirms an emailed code before
      anything else on the page works;
    * the authenticator app (`KilnCMSWeb.TotpEnrolment`), its recovery codes,
      and replacing it after a recovery-code sign-in;
    * a passkey, on a host where the ceremony can run
      (`KilnCMS.Accounts.WebAuthn.ceremony_host?/1`);
    * with `?reminder=1` and only during the grace period, "Not now";
    * for a reader held by a site that requires everyone, "Manage billing"
      and "Export my data" (decision 4): both stay reachable for them;
    * signing out.

  ## The proof is the action's, not this page's

  The page hides what the proof gates, but the decision is
  `KilnCMS.Accounts.Changes.RequireEnrolmentProof`'s, on `User.:confirm_totp`
  and `Passkey.:register`: every enrolment here passes the site, this
  session (`KilnCMSWeb.SignInMarker.enrolment_session/1`) and the proof in
  the action's context (`EnrolmentProof.context/3`), and the action decides
  again. A forged event without the proof is refused there.

  The emailed code lives only in this process, as an HMAC
  (`EnrolmentProof.send_code/3`); it is never assigned, rendered or logged.

  ## Where "Continue" goes

  `return_to`, when it is a local path (`KilnCMSWeb.SafeRedirect.local_path/2`);
  otherwise the console for an editor and `/account` for anyone else.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.EnrolmentProof
  alias KilnCMS.Accounts.Passkey
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMSWeb.SafeRedirect
  alias KilnCMSWeb.TotpEnrolment

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    org = socket.assigns.current_org
    tier = KilnCMSWeb.LiveUserAuth.effective_tier(socket)

    {:ok,
     socket
     |> assign(:page_title, gettext("Two-step sign-in"))
     |> assign(:site_name, KilnCMS.Branding.for_org(org).site_name)
     |> assign(:tier, tier)
     |> assign(:policy, TwoFactorRequirement.policy(org_id(socket)))
     |> assign(:credentials_locked?, KilnCMS.Demo.locks_credentials?(user))
     |> TotpEnrolment.init(session)
     |> assign(:enrolment_session, KilnCMSWeb.SignInMarker.enrolment_session(session))
     # The email proof (#2247): the pending code's HMAC while one is out,
     # the proof once it verified (or `:no_relay` when the site has no mail),
     # and what the last send said.
     |> assign(:proof_pending, nil)
     |> assign(:proof, nil)
     |> assign(:proof_sending?, false)
     |> assign(:passkeys, WebAuthn.list(user))
     |> assign(:passkey_challenge, nil)
     |> assign(:passkey_capable?, passkey_capable?(socket))
     |> assign(:return_to, default_return(tier))
     |> assign(:reminder?, false)
     |> assign_status()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       :return_to,
       SafeRedirect.local_path(params["return_to"], default_return(socket.assigns.tier))
     )
     |> assign(:reminder?, params["reminder"] == "1")}
  end

  # --- the email proof --------------------------------------------------------

  @impl true
  def handle_event("send_proof_code", _params, socket) do
    if socket.assigns.proof_needed? and not socket.assigns.proof_sending? do
      %{current_user: user, enrolment_session: session} = socket.assigns
      org_id = org_id(socket)

      {:noreply,
       socket
       |> assign(:proof_sending?, true)
       |> start_async(:send_proof_code, fn -> EnrolmentProof.send_code(user, org_id, session) end)}
    else
      {:noreply, socket}
    end
  end

  # No code out (none sent, or the one sent already verified): nothing to
  # compare, so nothing is charged.
  def handle_event("verify_proof_code", _params, %{assigns: %{proof_pending: nil}} = socket),
    do: {:noreply, put_flash(socket, :error, proof_error(:invalid))}

  def handle_event("verify_proof_code", %{"code" => code}, socket) when is_binary(code) do
    %{current_user: user, enrolment_session: session, proof_pending: pending} = socket.assigns

    case EnrolmentProof.verify(user, session, code, pending) do
      {:ok, proof} ->
        {:noreply,
         socket
         |> assign(:proof, proof)
         |> assign(:proof_pending, nil)
         |> assign_status()
         |> put_flash(:info, gettext("Thanks — your email address is confirmed."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, proof_error(reason))}
    end
  end

  # A payload with no code (a forged or truncated event): the same answer as
  # a wrong one, and nothing is charged.
  def handle_event("verify_proof_code", _params, socket),
    do: {:noreply, put_flash(socket, :error, proof_error(:invalid))}

  # --- the authenticator app ---------------------------------------------------

  def handle_event("start_totp", _params, socket) do
    if blocked?(socket),
      do: {:noreply, put_flash(socket, :error, proof_first())},
      else: {:noreply, TotpEnrolment.start(socket)}
  end

  def handle_event("cancel_totp", _params, socket),
    do: {:noreply, TotpEnrolment.cancel(socket)}

  # Not gated here on purpose: the action decides (`RequireEnrolmentProof`),
  # and its refusal is the message.
  def handle_event("confirm_totp", %{"code" => code} = params, socket) when is_binary(code) do
    {_result, socket} = TotpEnrolment.confirm(socket, params, enrolment_context(socket))
    {:noreply, assign_status(socket)}
  end

  # No code to check: nothing to confirm.
  def handle_event("confirm_totp", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_recovery_codes", _params, socket),
    do: {:noreply, assign(socket, :recovery_codes, nil)}

  # --- passkeys ---------------------------------------------------------------

  def handle_event("passkey_begin", params, socket) do
    cond do
      socket.assigns.credentials_locked? ->
        {:noreply, put_flash(socket, :error, TotpEnrolment.demo_locked_message())}

      not socket.assigns.passkey_capable? ->
        {:noreply, socket}

      blocked?(socket) ->
        {:noreply, put_flash(socket, :error, proof_first())}

      true ->
        begin_passkey(socket, params)
    end
  end

  def handle_event("passkey_attestation", payload, socket) do
    case socket.assigns.passkey_challenge do
      nil ->
        {:noreply, socket}

      challenge ->
        user = socket.assigns.current_user
        socket = assign(socket, :passkey_challenge, nil)
        context = Map.merge(socket.assigns.security_context, enrolment_context(socket))

        socket =
          case WebAuthn.register_passkey(user, challenge, payload, context: context) do
            {:ok, _passkey} ->
              put_flash(socket, :info, gettext("Passkey added — you can sign in with it now."))

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                TotpEnrolment.error_message(
                  reason,
                  gettext("Couldn't verify that passkey — try again.")
                )
              )
          end

        {:noreply, socket |> assign(:passkeys, WebAuthn.list(user)) |> assign_status()}
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

  def handle_event("passkey_cancel", _params, socket),
    do: {:noreply, assign(socket, :passkey_challenge, nil)}

  @impl true
  def handle_async(:send_proof_code, {:ok, result}, socket) do
    socket = assign(socket, :proof_sending?, false)

    {:noreply,
     case result do
       {:ok, pending} ->
         socket
         |> assign(:proof_pending, pending)
         |> put_flash(:info, gettext("We sent a code to %{email}.", email: email(socket)))

       {:skip, :no_relay} ->
         socket |> assign(:proof, :no_relay) |> assign_status()

       {:error, :throttled} ->
         put_flash(
           socket,
           :error,
           gettext("We've sent several codes already. Wait a while, then try again.")
         )

       {:error, _send_failed_or_no_session} ->
         put_flash(socket, :error, gettext("We couldn't send the code. Try again."))
     end}
  end

  def handle_async(:send_proof_code, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:proof_sending?, false)
     |> put_flash(:error, gettext("We couldn't send the code. Try again."))}
  end

  # --- state ------------------------------------------------------------------

  # The account's standing here, and whether this session still owes the
  # email proof. Recomputed after anything that may change either.
  defp assign_status(socket) do
    user = socket.assigns.current_user
    org_id = org_id(socket)
    status = TwoFactorRequirement.status(user, org_id, policy: socket.assigns.policy)

    proof_needed? =
      is_nil(socket.assigns.proof) and
        EnrolmentProof.required?(user, org_id, socket.assigns.enrolment_session,
          policy: socket.assigns.policy
        )

    socket
    |> assign(:status, status)
    |> assign(:proof_needed?, proof_needed?)
    |> assign_reader_controls()
  end

  # Billing and the data export (decision 4), for a reader the site holds
  # because it requires everyone: the rest of the site is closed to them
  # until they enroll, and these two are not.
  defp assign_reader_controls(socket) do
    %{policy: policy, tier: tier, status: status} = socket.assigns

    if policy.required_for == :everyone and tier == :viewer and status != :enrolled do
      socket
      |> assign(:reader_controls?, true)
      |> assign_new(:billing_manageable?, fn -> billing_manageable?(socket) end)
    else
      socket
      |> assign(:reader_controls?, false)
      |> assign(:billing_manageable?, false)
    end
  end

  defp billing_manageable?(socket) do
    user = socket.assigns.current_user

    user.id
    |> KilnCMS.Billing.memberships_for_user!(actor: user, tenant: org_id(socket))
    |> Enum.any?(&(&1.status != :incomplete and &1.provider_customer_id not in [nil, ""]))
  end

  defp blocked?(socket), do: socket.assigns.proof_needed?

  defp enrolment_context(socket),
    do:
      EnrolmentProof.context(
        socket.assigns.current_org,
        socket.assigns.enrolment_session,
        socket.assigns.proof
      )

  defp passkey_capable?(socket) do
    case socket.host_uri do
      %URI{host: host} -> WebAuthn.ceremony_host?(host)
      _not_host_scoped -> false
    end
  end

  # As `/editor/settings`: the list is re-read, so a page opened below the cap
  # does not start a ceremony the registration would refuse.
  defp begin_passkey(socket, params) do
    user = socket.assigns.current_user
    passkeys = WebAuthn.list(user)

    if at_passkey_limit?(passkeys) do
      {:noreply,
       socket
       |> assign(:passkeys, passkeys)
       |> put_flash(:error, TotpEnrolment.passkey_limit_message())}
    else
      challenge = WebAuthn.registration_challenge()

      {:noreply,
       socket
       |> assign(:passkey_challenge, challenge)
       |> push_event("passkey-register", %{
         publicKey: WebAuthn.registration_options(challenge, user),
         name: params["name"] || ""
       })}
    end
  end

  defp at_passkey_limit?(passkeys), do: length(passkeys) >= Passkey.max_per_account()

  defp default_return(tier) when tier in [:editor, :admin], do: ~p"/editor/overview"
  defp default_return(_tier), do: ~p"/account"

  defp org_id(socket), do: socket.assigns.current_org && socket.assigns.current_org.id

  defp email(socket), do: to_string(socket.assigns.current_user.email)

  defp proof_first, do: gettext("Confirm your email address before adding a second factor.")

  defp proof_error(:invalid), do: gettext("That code isn't valid — try again.")
  defp proof_error(:expired), do: gettext("That code has expired. Send a new one.")

  defp proof_error({:throttled, retry_after_ms}) do
    gettext("Too many attempts — try again in %{seconds} seconds.",
      seconds: Accounts.AccountThrottle.retry_after_seconds(retry_after_ms)
    )
  end

  defp on_date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_org={@current_org}>
      <div class="mx-auto max-w-xl space-y-6">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold">{gettext("Set up two-step sign-in")}</h1>
          <p id="two-factor-why" class="text-sm text-base-content/70">
            <%= case @status do %>
              <% {:enforced, _deadline} -> %>
                {gettext("This site requires two-step sign-in for your role. Set it up to continue.")}
              <% {:grace, deadline} -> %>
                {gettext("%{site} requires two-step sign-in for your role from %{date}.",
                  site: @site_name,
                  date: on_date(deadline)
                )}
              <% :enrolled -> %>
                {gettext("Two-step sign-in is on for your account.")}
              <% :not_required -> %>
                {gettext(
                  "A second factor keeps your account safe even if someone learns your password."
                )}
            <% end %>
          </p>
        </header>

        <.demo_locked_note :if={@credentials_locked?} />

        <section
          :if={@proof_needed? && !@credentials_locked?}
          id="two-factor-proof"
          class="card card-pad space-y-3"
        >
          <h2 class="text-lg font-medium">{gettext("First, confirm it's you")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext(
              "You signed in with your password. Before you add a second factor, enter the code we email to %{email}.",
              email: to_string(@current_user.email)
            )}
          </p>
          <form
            :if={@proof_pending}
            id="proof-code-form"
            phx-submit="verify_proof_code"
            class="flex items-end gap-2"
          >
            <.input
              name="code"
              value=""
              type="text"
              inputmode="numeric"
              autocomplete="one-time-code"
              label={gettext("Code from the email")}
            />
            <.button type="submit" variant="primary">{gettext("Confirm")}</.button>
          </form>
          <.button
            id="send-proof-code"
            type="button"
            phx-click="send_proof_code"
            variant={if @proof_pending, do: "ghost", else: "primary"}
            disabled={@proof_sending?}
          >
            {if @proof_pending, do: gettext("Send a new code"), else: gettext("Email me a code")}
          </.button>
        </section>

        <section
          :if={!@credentials_locked?}
          id="two-factor-app"
          class="card card-pad space-y-3"
        >
          <h2 class="text-lg font-medium">{gettext("Authenticator app")}</h2>

          <TotpEnrolment.recovery_codes :if={@recovery_codes} codes={@recovery_codes} />

          <div :if={@totp_enabled? && !@enrolling} class="space-y-3">
            <p class="flex items-center gap-1.5 text-sm font-medium text-success">
              <.icon name="hero-shield-check" class="size-4" />
              {gettext("Two-factor authentication is on.")}
            </p>
            <div
              :if={@recovery_login?}
              id="two-factor-recovery-login"
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
              <.button phx-click="start_totp" variant="primary" class="mt-3">
                {gettext("Set up a new authenticator")}
              </.button>
              <TotpEnrolment.added_mail_note />
            </div>
          </div>

          <div :if={@enrolling}>
            <TotpEnrolment.setup enrolling={@enrolling} />
            <TotpEnrolment.added_mail_note />
          </div>

          <div :if={!@totp_enabled? && !@enrolling} class="space-y-3">
            <p class="text-sm text-base-content/70">
              {gettext(
                "Use an app such as Google Authenticator or 1Password to make a new code every 30 seconds. It comes with recovery codes in case you lose it."
              )}
            </p>
            <p
              :if={@passkeys != []}
              id="two-factor-passkey-only"
              class="flex items-start gap-1.5 text-sm text-base-content/70"
            >
              <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
              {gettext(
                "Your passkey counts, but it has no recovery codes. Add an authenticator app too, so losing the device doesn't lock you out."
              )}
            </p>
            <.button
              id="start-totp"
              phx-click="start_totp"
              variant="primary"
              disabled={@proof_needed?}
            >
              {gettext("Set up an authenticator app")}
            </.button>
            <TotpEnrolment.added_mail_note />
          </div>
        </section>

        <section
          :if={!@credentials_locked? && @passkey_capable?}
          id="two-factor-passkey"
          phx-hook="PasskeyEnroll"
          class="card card-pad space-y-3"
        >
          <h2 class="text-lg font-medium">{gettext("Passkey")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Sign in with your device's fingerprint, face, or PIN. A passkey counts as two factors on its own."
            )}
          </p>
          <p :if={@passkeys != []} class="text-sm font-medium text-success">
            {ngettext(
              "You have %{count} passkey set up.",
              "You have %{count} passkeys set up.",
              length(@passkeys),
              count: length(@passkeys)
            )}
          </p>
          <p
            :if={length(@passkeys) >= Passkey.max_per_account()}
            id="passkeys-at-limit"
            class="flex items-center gap-1.5 text-sm text-base-content/70"
          >
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            {TotpEnrolment.passkey_limit_message()}
          </p>
          <form
            :if={!@passkey_challenge && length(@passkeys) < Passkey.max_per_account()}
            id="add-passkey-form"
            phx-submit="passkey_begin"
            class="flex items-end gap-2"
          >
            <.input
              name="name"
              value=""
              type="text"
              label={gettext("Name this passkey (optional)")}
              placeholder={gettext("e.g. MacBook Touch ID")}
            />
            <.button type="submit" variant="primary" disabled={@proof_needed?}>
              {gettext("Add a passkey")}
            </.button>
          </form>
          <%!-- `Passkey.:register` mails the owner every time
                (`NotifyFactorAdded`, `SecondFactorNotice`). Hidden with the
                form once the account holds the most it may. --%>
          <p
            :if={length(@passkeys) < Passkey.max_per_account()}
            id="passkey-added-mail"
            class="text-xs text-base-content/70"
          >
            {gettext("We'll email you each time a passkey is added to your account.")}
          </p>
          <div
            :if={@passkey_challenge}
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
        </section>

        <section
          :if={@reader_controls?}
          id="two-factor-reader-controls"
          class="card card-pad space-y-3"
        >
          <h2 class="text-lg font-medium">{gettext("Your membership and data")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext("These stay open while you set up two-step sign-in.")}
          </p>
          <div class="flex flex-wrap gap-2">
            <form :if={@billing_manageable?} method="post" action={~p"/billing/portal"}>
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <button type="submit" class="btn btn-default btn-sm">
                {gettext("Manage billing")}
              </button>
            </form>
            <.link href={~p"/editor/account/export.json"} class="btn btn-default btn-sm">
              {gettext("Export my data")}
            </.link>
          </div>
        </section>

        <div class="flex flex-wrap items-center gap-3">
          <.link
            :if={@status in [:enrolled, :not_required]}
            id="two-factor-continue"
            href={@return_to}
            class="btn btn-primary"
          >
            {gettext("Continue")}
          </.link>
          <.link
            :if={@reminder? && match?({:grace, _}, @status)}
            id="two-factor-not-now"
            href={@return_to}
            class="btn btn-ghost"
          >
            {gettext("Not now")}
          </.link>
          <.link href={~p"/sign-out"} class="btn btn-ghost">{gettext("Sign out")}</.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp demo_locked_note(assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 text-sm text-base-content/70" data-role="demo-locked">
      <.icon name="hero-lock-closed" class="size-4 shrink-0" />
      {TotpEnrolment.demo_locked_message()}
    </p>
    """
  end
end
