defmodule KilnCMSWeb.SecurityAlertsLive do
  @moduledoc """
  The site's security alert settings (#2245): which site alert kinds are on,
  whether the site's member admins get the bell and the email, and whether an
  alert shows the full client address. The row is
  `KilnCMS.CMS.SiteSecurityAlerts`; what the settings do is
  `KilnCMS.Security.Alerts`.

  Org-scoped and admin-only, gated the same two ways as
  `KilnCMSWeb.SecurityLogLive`: the `:admin_routes` live session's
  `:live_admin_required` hook and the `SiteSecurityAlerts` org-admin policy.
  Every client-bound event re-checks the tier as well, because the socket
  outlives the mount-time check.

  ## The whole form, every time

  `:save` is an upsert that writes the default for any field it is not given,
  so a partial submit would quietly switch things back on (or off). The form
  always carries every field, and `"save"` builds the full attribute map from
  it. A disabled kind this release does not show (one a newer release added)
  is kept as it was.

  ## What the page says out loud

    * Turning an alert off, or switching off admin notifications, sends every
      member admin of the site an `alerts_silenced` notice that no setting or
      mute stops. The page says so before the save, not after.
    * Platform alerts go to platform admins and are not site settings. The
      one platform kind that can be turned off, `api_key_rate_limited`, has
      its own form (`KilnCMS.Security.PlatformAlertSettings`), shown to
      platform admins only and re-checked on save; the resource policy
      refuses anyone else. Turning it off is recorded in the instance
      security log, which the page says.
    * Site alerts go to the site's member admins only. A site with none gets
      no bell and no email for its alerts, and the page warns about it.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Security alerts"))
     |> load_settings()
     |> load_platform_settings()}
  end

  @impl true
  def handle_event("validate", %{"alerts" => params}, socket) when is_map(params) do
    if admin?(socket) do
      {:noreply, assign(socket, :form, to_form(form_params(params), as: :alerts))}
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  def handle_event("save", %{"alerts" => params}, socket) when is_map(params) do
    with true <- admin?(socket),
         attrs = attributes(params, socket.assigns.settings),
         {:ok, _row} <-
           CMS.save_site_security_alerts(attrs,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org,
             context: socket.assigns.security_context
           ) do
      {:noreply,
       socket
       |> put_flash(:info, saved_message(socket.assigns.settings, attrs))
       |> load_settings()}
    else
      false ->
        {:noreply, put_flash(socket, :error, forbidden_message())}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ash_error_message(error,
             forbidden: forbidden_message(),
             fallback: gettext("The security alert settings could not be saved.")
           )
         )}
    end
  end

  def handle_event("save_platform", %{"platform_alerts" => params}, socket)
      when is_map(params) do
    with true <- platform_admin?(socket),
         attrs = platform_attributes(params, socket.assigns.platform_disabled),
         {:ok, _row} <-
           Security.save_platform_alert_settings(attrs,
             actor: socket.assigns.current_user,
             context: socket.assigns.security_context
           ) do
      {:noreply,
       socket
       |> put_flash(:info, platform_saved_message(socket.assigns.platform_disabled, attrs))
       |> load_platform_settings()}
    else
      false ->
        {:noreply, put_flash(socket, :error, platform_forbidden_message())}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ash_error_message(error,
             forbidden: platform_forbidden_message(),
             fallback: gettext("The platform alert settings could not be saved.")
           )
         )}
    end
  end

  defp admin?(socket), do: KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin

  # The effective platform role, asked again on every event: the socket
  # outlives a temporary platform grant.
  defp platform_admin?(socket), do: KilnCMSWeb.LiveUserAuth.platform_admin?(socket)

  # The platform's disabled kinds, for a platform admin only. Anyone else gets
  # no form and no read. A row that cannot be read shows every kind on.
  defp load_platform_settings(socket) do
    if platform_admin?(socket) do
      disabled =
        case Security.list_platform_alert_settings(actor: socket.assigns.current_user) do
          {:ok, [row | _rest]} -> row.disabled_kinds || []
          _none_or_refused -> []
        end

      params = Map.new(Alerts.platform_optional_kinds(), &{key(&1), key(&1) not in disabled})

      socket
      |> assign(:platform_disabled, disabled)
      |> assign(:platform_form, to_form(params, as: :platform_alerts))
    else
      socket
      |> assign(:platform_disabled, [])
      |> assign(:platform_form, nil)
    end
  end

  # The full list `:save` writes. Kinds this page does not show stay as the
  # row has them.
  defp platform_attributes(params, disabled) do
    shown = Enum.map(Alerts.platform_optional_kinds(), &key/1)
    kept = Enum.reject(disabled, &(&1 in shown))
    %{disabled_kinds: kept ++ Enum.reject(shown, &checked?(params, &1))}
  end

  defp platform_saved_message(before, attrs) do
    if attrs.disabled_kinds -- before != [] do
      gettext(
        "Platform alert settings saved. Turning an alert off is recorded in the instance security log."
      )
    else
      gettext("Platform alert settings saved.")
    end
  end

  defp platform_forbidden_message,
    do: gettext("Only platform administrators can change the platform's security alerts.")

  defp load_settings(socket) do
    settings = current_settings(socket)

    socket
    |> assign(:settings, settings)
    |> assign(:no_member_admins?, not Alerts.member_admins?(socket.assigns.current_org))
    |> assign(:form, to_form(settings_params(settings), as: :alerts))
  end

  # The row as the signed-in admin reads it, or the defaults when there is none.
  defp current_settings(socket) do
    case CMS.list_site_security_alerts(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} ->
        %{
          disabled_kinds: row.disabled_kinds || [],
          notify_admins: row.notify_admins,
          include_full_ip: row.include_full_ip
        }

      _none_or_refused ->
        Alerts.defaults()
    end
  end

  defp settings_params(settings) do
    kinds = Map.new(Alerts.site_kinds(), &{key(&1), Alerts.enabled?(settings, &1)})

    Map.merge(kinds, %{
      "notify_admins" => settings.notify_admins,
      "include_full_ip" => settings.include_full_ip
    })
  end

  # Every field the form has, read from what was submitted; one missing reads
  # as unchecked, as a browser would send it.
  defp form_params(params) do
    Map.new(
      Enum.map(Alerts.site_kinds(), &key/1) ++ ~w(notify_admins include_full_ip),
      &{&1, checked?(params, &1)}
    )
  end

  # The full attribute map `:save` needs. Kinds this page does not show stay
  # as the row has them.
  defp attributes(params, settings) do
    shown = Enum.map(Alerts.site_kinds(), &key/1)
    unchecked = Enum.reject(shown, &checked?(params, &1))
    kept = Enum.reject(settings.disabled_kinds, &(&1 in shown))

    %{
      disabled_kinds: kept ++ unchecked,
      notify_admins: checked?(params, "notify_admins"),
      include_full_ip: checked?(params, "include_full_ip")
    }
  end

  defp checked?(params, field), do: Map.get(params, field) in ["true", true]

  # Says when the save sent the site's admins a notice, the same rule
  # `KilnCMS.Security.Changes.NoticeAlertSettings` applies.
  defp saved_message(before, attrs) do
    newly_disabled = attrs.disabled_kinds -- before.disabled_kinds

    if newly_disabled != [] or (before.notify_admins and not attrs.notify_admins) do
      gettext("Security alert settings saved. Every admin of this site has been sent a notice.")
    else
      gettext("Security alert settings saved.")
    end
  end

  defp key(kind), do: Atom.to_string(kind)

  defp forbidden_message,
    do: gettext("You don't have permission to change this site's security alerts.")

  defp kind_label(:new_admin), do: gettext("New admin")
  defp kind_label(:role_elevation), do: gettext("Role raised")
  defp kind_label(:failed_sign_ins), do: gettext("Failed sign-ins")
  defp kind_label(:lockout), do: gettext("Account locked out")
  defp kind_label(:two_factor_disabled), do: gettext("Two-factor authentication turned off")
  defp kind_label(:sso_config_changed), do: gettext("Single sign-on changed")
  defp kind_label(:blocked_ip), do: gettext("Blocked addresses")

  defp platform_kind_label(:api_key_rate_limited), do: gettext("API keys over a rate limit")

  defp platform_kind_description(:api_key_rate_limited) do
    gettext(
      "A verified API key goes over a rate limit. One alert every %{minutes} minutes, then a summary, to every platform admin.",
      minutes: div(Alerts.window_ms(), :timer.minutes(1))
    )
  end

  defp kind_description(:new_admin),
    do:
      gettext(
        "Someone is made an admin of this site: by their role, a temporary grant, or an approved registration."
      )

  defp kind_description(:role_elevation),
    do: gettext("Someone's role on this site is raised, or they are given a temporary role.")

  defp kind_description(:failed_sign_ins) do
    gettext("%{count} failed sign-ins in %{minutes} minutes on this site. Off by default.",
      count: Alerts.failed_sign_in_threshold(),
      minutes: div(Alerts.window_ms(), :timer.minutes(1))
    )
  end

  defp kind_description(:lockout),
    do: gettext("An account is locked out of signing in after too many failed attempts.")

  defp kind_description(:two_factor_disabled),
    do: gettext("Someone removes a second factor from their account.")

  defp kind_description(:sso_config_changed),
    do: gettext("This site's single sign-on provider is changed.")

  defp kind_description(:blocked_ip) do
    gettext(
      "A request from an address on this site's block list is refused. One alert every %{minutes} minutes, then a summary.",
      minutes: div(Alerts.window_ms(), :timer.minutes(1))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:security_alerts}
    >
      <.header>
        {gettext("Security alerts")}
        <:subtitle>
          {gettext(
            "Which security events on this site are worth telling its admins about, by the bell and by email. One alert per kind every 15 minutes; the rest of that time arrives as one summary."
          )}
        </:subtitle>
      </.header>

      <div
        :if={@no_member_admins?}
        id="security-alerts-no-admins"
        role="status"
        class="mt-6 flex gap-3 rounded-lg border border-info/40 bg-info/10 p-4 text-sm"
      >
        <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
        <div>
          <p class="font-medium">{gettext("This site has no admins of its own.")}</p>
          <p class="mt-1 text-base-content/70">
            {gettext(
              "Until someone is an admin of this site through their membership, its alerts and notices go to the platform admins instead. Once the site has an admin of its own, they go to its admins only."
            )}
          </p>
        </div>
      </div>

      <div
        id="security-alerts-notice-banner"
        role="note"
        class="mt-6 flex max-w-2xl gap-3 rounded-lg border border-base-content/15 bg-base-200/60 p-4 text-sm"
      >
        <.icon name="hero-bell-alert" class="mt-0.5 size-5 shrink-0" />
        <p>
          {gettext(
            "Turning an alert off or switching off admin notifications sends every admin of this site a notice. That notice can't be turned off or muted."
          )}
        </p>
      </div>

      <.form
        for={@form}
        id="security-alerts-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-8 max-w-2xl space-y-8"
      >
        <fieldset id="security-alerts-kinds">
          <legend class="text-sm font-semibold">{gettext("Alerts")}</legend>
          <div class="mt-3 space-y-3">
            <div :for={kind <- Alerts.site_kinds()} id={"security-alert-kind-#{kind}"}>
              <.input field={@form[key(kind)]} type="checkbox" label={kind_label(kind)} />
              <p class="-mt-1 ml-6 text-xs text-base-content/70">{kind_description(kind)}</p>
            </div>
          </div>
        </fieldset>

        <fieldset id="security-alerts-delivery">
          <legend class="text-sm font-semibold">{gettext("Delivery")}</legend>
          <div class="mt-3 space-y-3">
            <div>
              <.input
                field={@form[:notify_admins]}
                type="checkbox"
                label={gettext("Notify this site's admins by bell and email")}
              />
              <p class="-mt-1 ml-6 text-xs text-base-content/70">
                {gettext(
                  "Off, alerts still go to webhooks subscribed to security events. Each admin can also mute the emails in their own settings."
                )}
              </p>
            </div>

            <div>
              <.input
                field={@form[:include_full_ip]}
                type="checkbox"
                label={gettext("Show the full IP address in alerts")}
              />
              <p class="-mt-1 ml-6 text-xs text-base-content/70">
                {gettext(
                  "Off, an alert shows only the address's network: its /24 for IPv4, its /48 for IPv6. The security log keeps the full address either way."
                )}
              </p>
            </div>

            <div
              :if={@form[:include_full_ip].value == true}
              id="security-alerts-full-ip-warning"
              role="status"
              class="flex gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
            >
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
              <p>
                {gettext(
                  "Full addresses are personal data. They will be copied into every admin's inbox and sent to every subscribed webhook, where this site's retention setting no longer reaches them."
                )}
              </p>
            </div>
          </div>
        </fieldset>

        <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
      </.form>

      <section
        :if={@platform_form}
        id="security-alerts-platform"
        class="mt-12 max-w-2xl space-y-3 border-t border-base-content/10 pt-8"
      >
        <h2 class="text-sm font-semibold">{gettext("Platform alerts")}</h2>
        <p class="text-sm text-base-content/70">
          {gettext(
            "Shown to platform admins only. These go to every platform admin, for the whole installation. Turning one off is recorded in the instance security log."
          )}
        </p>
        <.form
          for={@platform_form}
          id="platform-alerts-form"
          phx-submit="save_platform"
          class="space-y-4"
        >
          <div
            :for={kind <- Alerts.platform_optional_kinds()}
            id={"platform-alert-kind-#{kind}"}
          >
            <.input
              field={@platform_form[key(kind)]}
              type="checkbox"
              label={platform_kind_label(kind)}
            />
            <p class="-mt-1 ml-6 text-xs text-base-content/70">
              {platform_kind_description(kind)}
            </p>
          </div>
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save platform alerts")}</.button>
        </.form>
      </section>

      <section id="security-alerts-elsewhere" class="mt-12 max-w-2xl space-y-3 text-sm">
        <h2 class="text-sm font-semibold">{gettext("Not set here")}</h2>
        <p id="security-alerts-platform-note" class="text-base-content/70">
          {gettext(
            "Platform alerts (new platform admins, platform role changes, new API keys, reuse of a stolen API key and API keys over a rate limit) go to the platform's admins and aren't site settings. Only a platform admin can turn one off, and only API keys over a rate limit."
          )}
        </p>
        <p class="text-base-content/70">
          {gettext(
            "To send alerts to another system, subscribe a webhook endpoint to the %{events} events.",
            events: "security.*"
          )}
          <.link navigate={~p"/editor/webhooks"} id="security-alerts-webhooks-link" class="link">
            {gettext("Webhooks")}
          </.link>
        </p>
      </section>
    </Layouts.console>
    """
  end
end
