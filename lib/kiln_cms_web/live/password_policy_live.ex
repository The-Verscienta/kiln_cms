defmodule KilnCMSWeb.PasswordPolicyLive do
  @moduledoc """
  This site's stance on breached passwords (#2240): when someone sets a password
  (registers, changes it, resets it, or the first-run wizard), it is looked up
  against a public breach corpus by k-anonymity (`KilnCMS.Accounts.BreachedPassword`).
  This page chooses what happens when it is found.

  Scoped to the request's org like `/editor/security-txt`. Writes are
  policy-gated to org admins by `KilnCMS.CMS.SitePasswordPolicy`, and this
  LiveView sits in the `:admin_routes` live session whose tier gate agrees. The
  decision itself is not made here: `KilnCMS.Accounts.PasswordPolicy` resolves
  it, and the page only edits the row and explains the outcome.

  A deployment that has switched the check off (`BREACHED_PASSWORD_CHECK=false`)
  makes this setting inert; the page says so rather than letting an admin think
  they are protected.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.CMS

  @policies ~w(off warn block)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Password policy"))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", %{"password_policy" => %{"breached_password_policy" => value}}, socket)
      when value in @policies do
    case CMS.save_site_password_policy(
           %{breached_password_policy: String.to_existing_atom(value)},
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org,
           context: socket.assigns.security_context
         ) do
      {:ok, _row} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Password policy saved.")) |> load_settings()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket) do
    # Re-read rather than destroying the struct assigned at mount: a second tab
    # may already have dropped it.
    case current_row(socket) do
      nil ->
        {:noreply, load_settings(socket)}

      row ->
        case CMS.reset_site_password_policy(row,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_org,
               context: socket.assigns.security_context
             ) do
          {:error, error} ->
            {:noreply, socket |> put_flash(:error, error_message(error)) |> load_settings()}

          _destroyed ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Password policy reset to the default."))
             |> load_settings()}
        end
    end
  end

  defp load_settings(socket) do
    row = current_row(socket)
    default = BreachedPassword.default_policy()
    selected = if row, do: row.breached_password_policy, else: default

    socket
    |> assign(:row, row)
    |> assign(:default_policy, default)
    |> assign(:check_enabled?, BreachedPassword.enabled?())
    |> assign(
      :form,
      to_form(%{"breached_password_policy" => to_string(selected)}, as: :password_policy)
    )
  end

  defp current_row(socket) do
    case CMS.list_site_password_policy(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's password policy."),
      fallback: gettext("The password policy could not be saved.")
    )
  end

  defp options do
    [
      {gettext("Off - don't warn"), "off"},
      {gettext("Warn - allow it, with a warning"), "warn"},
      {gettext("Block - refuse it for administrators"), "block"}
    ]
  end

  defp policy_name(:off), do: gettext("Off")
  defp policy_name(:warn), do: gettext("Warn")
  defp policy_name(:block), do: gettext("Block")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:password_policy}
    >
      <.header>
        {gettext("Password policy")}
        <:subtitle>
          {gettext(
            "What happens when a new password is found in a public data breach. Only a short fragment of the password's fingerprint is ever sent to check it; the password itself never leaves this server."
          )}
        </:subtitle>
      </.header>

      <div
        :if={!@check_enabled?}
        id="password-policy-disabled"
        role="status"
        class="mt-6 flex gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
        <div>
          <p class="font-medium">{gettext("The breached-password check is switched off.")}</p>
          <p class="mt-1 text-base-content/70">
            {gettext(
              "The server's operator has turned it off for the whole deployment (BREACHED_PASSWORD_CHECK=false). No password is looked up, and this setting has no effect until they turn it back on."
            )}
          </p>
        </div>
      </div>

      <.form for={@form} id="password-policy-form" phx-submit="save" class="mt-8 max-w-2xl space-y-6">
        <.input
          field={@form[:breached_password_policy]}
          type="select"
          label={gettext("When a new password is in a known breach")}
          options={options()}
        />

        <ul class="-mt-2 space-y-2 text-sm text-base-content/70">
          <%!-- Off is this site's egress switch only, and only while its row
                can be read (`CheckBreachedPassword` falls back to :warn);
                the server-wide one is BREACHED_PASSWORD_CHECK=false (#2868). --%>
          <li id="password-policy-off">
            <span class="font-medium">{gettext("Off")}</span>
            - {gettext(
              "Passwords set on this site are not checked, and nothing about them is sent to Have I Been Pwned. If this setting can't be read, Warn applies instead; only the server's operator can stop the check for every site (BREACHED_PASSWORD_CHECK=false)."
            )}
          </li>
          <li>
            <span class="font-medium">{gettext("Warn")}</span>
            - {gettext(
              "The password is accepted and the person is told it appears in a breach and that they should consider another. This is the default."
            )}
          </li>
          <li>
            <span class="font-medium">{gettext("Block")}</span>
            - {gettext(
              "Administrator accounts cannot use a breached password. Block applies to administrators; editors and everyone else are warned instead, so a visitor is never locked out of signing up."
            )}
          </li>
        </ul>

        <p class="text-xs text-base-content/70">
          {gettext(
            "If the breach service can't be reached the password is accepted, so an outage never stops anyone setting one. Signing in is never checked. This applies to registering, changing or resetting a password, and the first-run setup."
          )}
        </p>

        <p id="password-policy-default" class="text-xs text-base-content/70">
          <%= if @row do %>
            {gettext("This site sets its own policy. Without it the default would be: %{policy}.",
              policy: policy_name(@default_policy)
            )}
          <% else %>
            {gettext("No policy has been set for this site, so the default applies: %{policy}.",
              policy: policy_name(@default_policy)
            )}
          <% end %>
        </p>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <button
            :if={@row}
            type="button"
            phx-click="reset"
            data-confirm={gettext("Go back to the default policy for this site?")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Use the default")}
          </button>
        </div>
      </.form>
    </Layouts.console>
    """
  end
end
