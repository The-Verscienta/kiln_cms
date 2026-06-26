defmodule KilnCMSWeb.SettingsLive do
  @moduledoc """
  Per-user account settings (`/editor/settings`) — currently the workflow
  notification preferences from issue #46. Each signed-in user manages their
  own opt-in/out for review-request, publish, and return-to-draft emails;
  preferences default on, so muting is an explicit choice. Editor/admin only
  (`:live_editor_required`).
  """
  use KilnCMSWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :form, prefs_form(socket.assigns.current_user))}
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

  defp prefs_form(user) do
    user
    |> AshPhoenix.Form.for_update(:update_notification_prefs, actor: user, as: "user")
    |> to_form()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-6">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Settings")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext("Choose which workflow emails this account receives.")}
          </p>
        </div>

        <section class="max-w-xl rounded-lg border border-base-content/10 p-4">
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

        <section class="max-w-xl rounded-lg border border-base-content/10 p-4">
          <h2 class="mb-1 text-lg font-medium">{gettext("Your data")}</h2>
          <p class="mb-4 text-sm text-base-content/60">
            {gettext("Download a copy of your account profile and notification preferences as JSON.")}
          </p>

          <.link
            href={~p"/editor/account/export.json"}
            download="kiln-account-export.json"
            class="inline-flex items-center gap-2 rounded-lg border border-base-content/20 px-3 py-2 text-sm font-medium hover:bg-base-200"
          >
            <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
            {gettext("Export my data")}
          </.link>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
