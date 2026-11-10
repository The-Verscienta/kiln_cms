defmodule KilnCMSWeb.InviteLive do
  @moduledoc """
  The page a site invitation's link opens (`/auth/invite/:invite_token`, #2135).

  Opening it only **peeks** at the token (`KilnCMS.Accounts.Invitations.peek/1`);
  nothing is consumed until a button is pressed, so a mail scanner that follows
  the link changes nothing. What it shows depends on the invited address:

    * **no account** — a form for a password (and an optional display name),
      submitted to `User.:register_with_invitation`;
    * an **unconfirmed** account — the same form, submitted to
      `User.:accept_invitation_with_password`, which sets the password over
      whatever was there and signs every old session out: anyone could have
      registered the address, so its old password proves nothing;
    * a **confirmed** account — one "Accept" button
      (`Invitation.:accept_existing`), which adds the membership and changes
      nothing on the account.

  An account already on the site is raised to the invited tier when it held a
  lower one there, and left as it is otherwise (#2452). The flash after the
  accept says which: joined, now at the invited tier, or already a member at
  the tier it holds, with nothing changed.

  A made-up, expired, revoked or used token — or an `:admin` invitation whose
  sender is no longer a standing admin — gets one fixed page that names
  nothing, so the link is not a way to learn which of those it was.

  Every write is a system-only action called with `authorize?: false`: the
  token is the credential, and each action re-checks it under a row lock.
  The page does not sign anyone in. Creating a session from a LiveView would
  mean minting tokens outside the password flow (`KilnCMSWeb.SetupLive` makes
  the same choice), so success sends the invitee to `/sign-in`.

  The link is built on the invited site's host for the invited tier
  (`KilnCMSWeb.Plugs.ConsoleHost.tier_url/3`). Opened on another site's host,
  or on the wrong kind of host, the page sends the browser to the right one, so
  the account is set up — and the sign-in that follows happens — where the
  invitee will use it.
  """
  use KilnCMSWeb, :live_view

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AddressThrottled
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.Preparations.ThrottleSignIn
  alias KilnCMSWeb.Plugs.ClientIp
  alias KilnCMSWeb.Plugs.ConsoleHost
  alias KilnCMSWeb.RateLimit

  @impl true
  def mount(%{"invite_token" => token}, _session, socket) when is_binary(token) do
    socket =
      socket
      |> assign(:page_title, gettext("Invitation"))
      |> assign(:token, token)
      |> assign(:form, blank_form())
      |> assign(:error, nil)
      |> assign(:context, action_context(socket))
      |> load(token)

    case elsewhere(socket) do
      nil -> {:ok, socket}
      url -> {:ok, redirect(socket, external: url)}
    end
  end

  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(:page_title, gettext("Invitation")) |> invalid()}

  # --- events ----------------------------------------------------------------

  @impl true
  def handle_event("accept_new", %{"invite" => params}, socket) when is_map(params) do
    form = Map.merge(blank_form(), Map.take(params, Map.keys(blank_form())))

    if socket.assigns.branch in [:new, :unconfirmed] and Enum.all?(Map.values(form), &is_binary/1) do
      {:noreply, socket |> assign(:form, form) |> submit_password(form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("accept_existing", _params, socket) do
    if socket.assigns.branch == :existing do
      {:noreply, accept_existing(socket)}
    else
      {:noreply, socket}
    end
  end

  # A pushed payload is client-chosen; give the guarded head above somewhere
  # to fall (#764).
  def handle_event("accept_new", _params, socket), do: {:noreply, socket}

  # --- accepting -------------------------------------------------------------

  defp submit_password(socket, form) do
    input = %{
      token: socket.assigns.token,
      name: presence(form["name"]),
      password: form["password"],
      password_confirmation: form["password_confirmation"]
    }

    result =
      case socket.assigns.branch do
        # authorize?: false — the system-only accept; the emailed token is the
        # credential, and the action re-checks it under a row lock.
        :new ->
          Accounts.register_with_invitation(input,
            authorize?: false,
            context: socket.assigns.context
          )

        :unconfirmed ->
          accept_over_unconfirmed(socket, input)
      end

    case result do
      {:ok, user} ->
        socket
        |> put_flash(:info, password_accepted(user, socket))
        |> redirect(to: ~p"/sign-in")

      {:error, error} ->
        password_refused(socket, error)
    end
  end

  defp accept_over_unconfirmed(socket, input) do
    # authorize?: false — a system read of the unconfirmed account the invited
    # address holds; the token just proved the address.
    case Accounts.get_user_by_email(socket.assigns.email,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %Accounts.User{confirmed_at: nil} = user} ->
        # authorize?: false — the system-only accept over an unconfirmed
        # account; the emailed token is the credential, re-checked under a lock.
        Accounts.accept_invitation_with_password(user, input,
          authorize?: false,
          context: socket.assigns.context
        )

      _changed ->
        {:error, :account_changed}
    end
  end

  defp password_refused(socket, error) do
    cond do
      InvitationRefused.in?(error, :invalid) ->
        invalid(socket)

      error == :account_changed or taken?(error) ->
        # The address gained an account between the page opening and the
        # submit (a sign-up, an identity provider). Nothing was set; say so,
        # and offer what fits the account it has now.
        socket
        |> load(socket.assigns.token)
        |> assign(:form, blank_form())
        |> assign(
          :error,
          gettext("An account with this address already exists — accept the invitation with it.")
        )

      throttled?(error) ->
        assign(
          socket,
          :error,
          gettext("Too many attempts from this address — try again shortly.")
        )

      true ->
        assign(socket, :error, form_error(error))
    end
  end

  defp accept_existing(socket) do
    # authorize?: false — the system-only accept for a confirmed account; the
    # emailed token is the credential, and the action re-checks it under a lock.
    case Accounts.accept_invitation_for_existing_account(socket.assigns.token,
           authorize?: false,
           context: socket.assigns.context
         ) do
      {:ok, outcome} ->
        socket
        |> put_flash(:info, accepted(outcome, socket.assigns.site_name))
        |> redirect(to: ~p"/sign-in")

      {:error, error} ->
        cond do
          throttled?(error) ->
            assign(
              socket,
              :error,
              gettext("Too many attempts from this address — try again shortly.")
            )

          InvitationRefused.in?(error, :invalid) ->
            invalid(socket)

          true ->
            Logger.warning(
              "Accepting an invitation failed: #{Exception.message(Ash.Error.to_error_class(error))}"
            )

            assign(socket, :error, gettext("The invitation could not be accepted. Try again."))
        end
    end
  end

  # What the accept did (#2452), in the flash the sign-in page shows. The
  # password paths set the account up whichever it was, so only an unchanged
  # membership needs saying differently there.
  defp accepted(%{outcome: :raised, role: role}, site), do: raised(role, site)

  defp accepted(%{outcome: :already_member, role: role}, site),
    do:
      gettext("You're already a member of %{site} as %{tier}; nothing changed.",
        site: site,
        tier: tier(role)
      )

  defp accepted(_joined, site),
    do: gettext("You've joined %{site} — sign in to continue.", site: site)

  # Accepting over an unconfirmed account forgets every credential it held
  # (#2453); when one the invitee may have set up was among them, say so.
  defp password_accepted(user, socket) do
    accepted = password_outcome(user.__metadata__[:invitation_outcome], socket)

    if user.__metadata__[:forgotten_credentials] == true,
      do:
        accepted <>
          " " <>
          gettext(
            "Any two-step verification, passkeys or API keys set up on this address before were removed; set them up again."
          ),
      else: accepted
  end

  defp password_outcome(%{outcome: :raised, role: role}, socket),
    do: raised(role, socket.assigns.site_name)

  defp password_outcome(%{outcome: :already_member, role: role}, socket),
    do:
      gettext(
        "Your account is ready. You were already a member of %{site} as %{tier}, and that is unchanged.",
        site: socket.assigns.site_name,
        tier: tier(role)
      )

  defp password_outcome(_joined, socket),
    do: gettext("Your account is ready — sign in to %{site}.", site: socket.assigns.site_name)

  defp raised(role, site),
    do:
      gettext("You're now %{tier} on %{site} — sign in to continue.",
        tier: tier(role),
        site: site
      )

  # --- loading ---------------------------------------------------------------

  defp load(socket, token) do
    with %{} = invitation <- Invitations.peek(token),
         true <- Invitations.inviter_still_admin?(invitation),
         {:ok, branch} <- branch(invitation) do
      socket
      |> assign(:branch, branch)
      |> assign(:org_id, invitation.organization_id)
      |> assign(:email, to_string(invitation.email))
      |> assign(:role, invitation.role)
      |> assign(:site_name, KilnCMS.Branding.for_org(invitation.organization_id).site_name)
    else
      _invalid -> invalid(socket)
    end
  end

  defp branch(invitation) do
    # authorize?: false — a system read of whether the invited address has an
    # account, to pick the form; the token just proved the address, and only
    # the branch is kept.
    case Accounts.get_user_by_email(invitation.email, authorize?: false, not_found_error?: false) do
      {:ok, nil} -> {:ok, :new}
      {:ok, %Accounts.User{anonymized_at: %DateTime{}}} -> :error
      {:ok, %Accounts.User{confirmed_at: nil}} -> {:ok, :unconfirmed}
      {:ok, %Accounts.User{}} -> {:ok, :existing}
      _error -> :error
    end
  end

  # One page for every token that names nothing live: nothing on it comes from
  # the invitation.
  defp invalid(socket) do
    socket
    |> assign(:branch, :invalid)
    |> assign(:org_id, nil)
    |> assign(:email, nil)
    |> assign(:role, nil)
    |> assign(:site_name, nil)
    |> assign(:error, nil)
  end

  # The host the invitation's link names (`ConsoleHost.tier_url/3`: the site
  # host for a viewer, the console host for an editor or admin), when the page
  # was opened on another site's host — or, with the console gate on, on the
  # wrong kind of host for the invited tier.
  defp elsewhere(%{assigns: %{branch: :invalid}}), do: nil

  defp elsewhere(socket) do
    %{org_id: org_id, current_org: current_org, token: token, role: role} = socket.assigns

    if (current_org && current_org.id == org_id) and right_kind_of_host?(socket, role) do
      nil
    else
      url = ConsoleHost.tier_url("/auth/invite/#{token}", organization(org_id), role)

      # A host that does not resolve back to the org would bounce forever;
      # stay, since accepting does not depend on the host.
      if URI.parse(url).host != socket.host_uri.host, do: url
    end
  end

  defp right_kind_of_host?(socket, role) do
    case ConsoleHost.console_host() do
      nil -> true
      _gate_on -> ConsoleHost.console_host_name?(socket.host_uri.host) == (role != :viewer)
    end
  end

  defp organization(org_id) do
    # The plain org read the accounts system actor is admitted to.
    case Accounts.get_organization(org_id, actor: Accounts.system(), not_found_error?: false) do
      {:ok, org} -> org
      _missing -> nil
    end
  end

  # The request context for the audit events, plus the socket's own client
  # address for the per-IP registration budget — this page's submits arrive over
  # `/live`, past every router plug (`KilnCMSWeb.SignInLive` does the same).
  defp action_context(socket) do
    if connected?(socket) and is_nil(socket.parent_pid),
      do: Map.merge(socket.assigns.security_context, client_ip_context(socket)),
      else: socket.assigns.security_context
  end

  defp client_ip_context(socket) do
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

    peer_address =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _none -> nil
      end

    x_headers
    |> ClientIp.resolve(peer_address)
    |> RateLimit.client_key()
    |> ThrottleSignIn.client_ip_context()
  end

  defp taken?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &taken?/1)
  defp taken?(%{field: :email, message: "has already been taken"}), do: true
  defp taken?(_other), do: false

  defp throttled?(%AddressThrottled{}), do: true
  defp throttled?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &throttled?/1)
  defp throttled?(_other), do: false

  defp form_error(error) do
    ash_error_message(error, fallback: gettext("The account could not be set up."))
  end

  defp blank_form, do: %{"name" => "", "password" => "", "password_confirmation" => ""}

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp tier(:admin), do: gettext("an admin")
  defp tier(:editor), do: gettext("an editor")
  defp tier(_viewer), do: gettext("a viewer")

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="auth-page">
      <div class="auth-card py-12">
        <div :if={@branch == :invalid} id="invite-invalid">
          <h2 class="auth-title mb-2">{gettext("This invitation is no longer valid")}</h2>
          <p class="auth-muted mb-6">
            {gettext("Ask a site admin to send you a new one.")}
          </p>
          <.link navigate={~p"/sign-in"} class="link text-sm font-medium text-base-content">
            {gettext("Go to sign in")}
          </.link>
        </div>

        <div :if={@branch != :invalid} id="invite-valid">
          <h2 class="auth-title mb-2">
            {gettext("Join %{site}", site: @site_name)}
          </h2>
          <p class="auth-muted mb-6">
            {gettext("You've been invited to %{site} as %{tier}, at %{email}.",
              site: @site_name,
              tier: tier(@role),
              email: @email
            )}
          </p>

          <p :if={@error} id="invite-error" role="alert" class="mb-4 text-sm text-error">
            {@error}
          </p>

          <div :if={@branch == :existing} id="invite-existing">
            <p class="auth-muted mb-4">
              {gettext(
                "This address already has an account. Accept to add this site to it, or to take the invited role there if yours is lower; nothing else about the account changes."
              )}
            </p>
            <button
              id="invite-accept"
              type="button"
              phx-click="accept_existing"
              phx-disable-with={gettext("Accepting…")}
              class="btn btn-primary btn-block"
            >
              {gettext("Accept invitation")}
            </button>
          </div>

          <form
            :if={@branch in [:new, :unconfirmed]}
            id="invite-form"
            phx-submit="accept_new"
            class="space-y-4"
          >
            <p :if={@branch == :unconfirmed} class="auth-muted">
              {gettext(
                "An unconfirmed account was already started with this address. Choose a password to take it over; any password set before stops working."
              )}
            </p>
            <.input
              id="invite-name"
              name="invite[name]"
              type="text"
              value={@form["name"]}
              label={gettext("Display name (optional)")}
              autocomplete="name"
            />
            <.input
              id="invite-password"
              name="invite[password]"
              type="password"
              reveal
              value={@form["password"]}
              label={gettext("Password")}
              autocomplete="new-password"
              hint={gettext("At least 8 characters.")}
              required
            />
            <.input
              id="invite-password-confirmation"
              name="invite[password_confirmation]"
              type="password"
              reveal
              value={@form["password_confirmation"]}
              label={gettext("Password (again)")}
              autocomplete="new-password"
              required
            />
            <button
              type="submit"
              phx-disable-with={gettext("Setting up…")}
              class="btn btn-primary btn-block"
            >
              {gettext("Set up my account")}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
