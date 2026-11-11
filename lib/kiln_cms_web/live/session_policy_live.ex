defmodule KilnCMSWeb.SessionPolicyLive do
  @moduledoc """
  This site's signed-in sessions (#2246): how long a browser may sit idle
  before it is signed out — for everyone, and optionally a shorter time for
  administrators — and a button that signs everyone out of the site at once.

  Scoped to the request's org like `/editor/password-policy`. Every write is
  policy-gated to org admins by `KilnCMS.CMS.SiteSessionPolicy` (the save and
  the `:sign_out_all` action alike), and this LiveView sits in the
  `:admin_routes` live session whose tier gate agrees. Enforcement is not here:
  `KilnCMS.Accounts.IdleTimeout` decides, `KilnCMSWeb.Plugs.IdleTimeout` and
  `KilnCMSWeb.IdleSession` act.

  "Off" saves no timeout rather than deleting the row: the row also holds the
  watermark of the last "sign out everyone", which must outlive a change of
  mind about the timeout.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteSessionPolicy

  # Minutes. The resource accepts anything from 10 minutes to a day; the page
  # offers these, plus a saved value that is not one of them.
  @presets [15, 30, 60, 120, 240, 480, 720, 1440]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Sessions"))
     |> assign(:sign_out_form, to_form(%{"keep_me" => "true"}, as: :sign_out_all))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", %{"session_policy" => params}, socket) when is_map(params) do
    with {:ok, idle} <- parse_minutes(params["idle_timeout_minutes"]),
         {:ok, admin} <- parse_minutes(params["admin_idle_timeout_minutes"]),
         {:ok, _row} <-
           CMS.save_site_session_policy(
             %{idle_timeout_minutes: idle, admin_idle_timeout_minutes: admin},
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org,
             context: socket.assigns.security_context
           ) do
      {:noreply,
       socket |> put_flash(:info, gettext("Session settings saved.")) |> load_settings()}
    else
      :invalid ->
        {:noreply, put_flash(socket, :error, gettext("Choose one of the listed times."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, save_error(error))}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("sign_out_all", params, socket) when is_map(params) do
    # Matched, not `get_in/2`: a malformed payload must not raise (#764).
    keep_me? = match?(%{"sign_out_all" => %{"keep_me" => "true"}}, params)
    except = if keep_me?, do: socket.assigns[:current_session_jti]

    # The action re-checks that the caller is an admin of this site, and that
    # the kept session is the caller's own.
    case CMS.sign_out_all_sessions(%{except_session_jti: except},
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org,
           context: socket.assigns.security_context
         ) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "Signed out %{count} session on this site.",
             "Signed out %{count} sessions on this site.",
             count
           )
         )
         |> load_settings()}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ash_error_message(error,
             forbidden: gettext("You don't have permission to sign everyone out of this site."),
             fallback: gettext("Nobody was signed out. Try again.")
           )
         )}
    end
  end

  defp load_settings(socket) do
    row = current_row(socket)
    idle = row && row.idle_timeout_minutes
    admin = row && row.admin_idle_timeout_minutes

    socket
    |> assign(:row, row)
    |> assign(:idle_minutes, idle)
    |> assign(:admin_minutes, admin)
    |> assign(:can_sign_out_all?, can_sign_out_all?(socket))
    |> assign(
      :form,
      to_form(
        %{
          "idle_timeout_minutes" => minutes_value(idle),
          "admin_idle_timeout_minutes" => minutes_value(admin)
        },
        as: :session_policy
      )
    )
  end

  defp current_row(socket) do
    case CMS.list_site_session_policy(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  defp can_sign_out_all?(socket) do
    CMS.can_sign_out_all_sessions?(socket.assigns.current_user, %{},
      tenant: socket.assigns.current_org
    )
  end

  defp parse_minutes(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_minutes(value) when is_binary(value) do
    case Integer.parse(value) do
      {minutes, ""} -> {:ok, minutes}
      _other -> :invalid
    end
  end

  defp parse_minutes(_value), do: :invalid

  defp minutes_value(nil), do: ""
  defp minutes_value(minutes), do: Integer.to_string(minutes)

  defp save_error(%Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(errors, &match?(%{field: :admin_idle_timeout_minutes}, &1)) and
         not Enum.any?(errors, &match?(%{field: :idle_timeout_minutes}, &1)) do
      gettext("The time for administrators can't be longer than the time for everyone.")
    else
      generic_save_error(error)
    end
  end

  defp save_error(error), do: generic_save_error(error)

  defp generic_save_error(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's session settings."),
      fallback: gettext("The session settings could not be saved.")
    )
  end

  defp options(current, off_label) do
    presets =
      if is_integer(current) and current not in @presets,
        do: Enum.sort([current | @presets]),
        else: @presets

    [{off_label, ""} | Enum.map(presets, &{duration(&1), Integer.to_string(&1)})]
  end

  defp duration(minutes) when rem(minutes, 60) == 0 do
    hours = div(minutes, 60)
    ngettext("%{count} hour", "%{count} hours", hours)
  end

  defp duration(minutes), do: ngettext("%{count} minute", "%{count} minutes", minutes)

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:idle_options, options(assigns.idle_minutes, gettext("Never")))
      |> assign(
        :admin_options,
        options(assigns.admin_minutes, gettext("Same as everyone"))
      )
      |> assign(:min_minutes, SiteSessionPolicy.min_minutes())

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:session_policy}
    >
      <.header>
        {gettext("Sessions")}
        <:subtitle>
          {gettext(
            "How long a browser can sit unused on this site before it is signed out, and a way to sign everyone out at once."
          )}
        </:subtitle>
      </.header>

      <section id="session-idle" class="mt-8 max-w-2xl">
        <h2 class="text-lg font-medium">{gettext("Sign out when idle")}</h2>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext(
            "A browser that does nothing on this site for this long is signed out, even if it chose “remember me”. Reading a page, clicking or typing counts as activity; a tab left open does not."
          )}
        </p>

        <.form for={@form} id="session-policy-form" phx-submit="save" class="mt-6 space-y-6">
          <.input
            field={@form[:idle_timeout_minutes]}
            type="select"
            label={gettext("Everyone")}
            options={@idle_options}
          />
          <.input
            field={@form[:admin_idle_timeout_minutes]}
            type="select"
            label={gettext("Administrators")}
            options={@admin_options}
          />
          <p class="-mt-2 text-xs text-base-content/70">
            {gettext(
              "Administrators can be given a shorter time than everyone else, never a longer one. Turning this on, or shortening it, starts the clock from now: nobody is signed out for time they spent idle before."
            )}
          </p>

          <p id="session-policy-current" class="text-xs text-base-content/70">
            <%= if @idle_minutes || @admin_minutes do %>
              {gettext("This site signs idle browsers out.")}
            <% else %>
              {gettext("No idle timeout is set: browsers stay signed in until they sign out.")}
            <% end %>
          </p>

          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
        </.form>
      </section>

      <section
        id="session-sign-out-all"
        class="mt-10 max-w-2xl rounded-lg border border-error/40 p-5"
      >
        <h2 class="flex items-center gap-2 text-lg font-medium">
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
          {gettext("Sign out everyone")}
        </h2>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext(
            "Every browser signed in to this site is signed out now, including “remember me” and sign-ins waiting for a two-factor code. Open pages go to the sign-in page. Other sites on this server are not affected."
          )}
        </p>
        <p class="mt-2 text-sm text-base-content/70">
          {gettext(
            "API keys and app tokens keep working. If an account may be compromised, reset its password; a platform admin can also use “Sign out everywhere” on the Accounts page."
          )}
        </p>

        <.form
          for={@sign_out_form}
          id="sign-out-all-form"
          phx-submit="sign_out_all"
          class="mt-4 space-y-4"
        >
          <.input
            field={@sign_out_form[:keep_me]}
            type="checkbox"
            label={gettext("Keep me signed in on this browser")}
          />
          <button
            :if={@can_sign_out_all?}
            id="sign-out-all"
            type="submit"
            phx-disable-with={gettext("Signing out…")}
            data-confirm={gettext("Sign out everyone on this site now?")}
            class="btn btn-danger"
          >
            {gettext("Sign out everyone")}
          </button>
        </.form>
      </section>
    </Layouts.console>
    """
  end
end
