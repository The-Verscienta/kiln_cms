defmodule KilnCMSWeb.WebhookLive do
  @moduledoc """
  Webhooks (`/editor/webhooks`) — register outbound endpoints and choose which
  content lifecycle events (`<type>.published` / `.unpublished` / `.updated`)
  each one receives. Admin-only, mirroring the `WebhookEndpoint` policy; the
  per-endpoint signing secret is shown so receivers can verify deliveries.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Webhooks

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Webhooks"))
       |> assign(:available_events, WebhookEndpoint.events())
       |> assign(:edit, nil)
       |> assign(:form, create_form(actor, socket.assigns.current_org))
       |> load_endpoints()
       |> load_deliveries()}
    else
      # Defense-in-depth: the `:live_admin_required` on_mount guard already
      # redirects non-admins with this flash before mount runs; mirror it here so
      # this fallback stays consistent rather than silently bouncing to /editor.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- create ----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"webhook" => params}, socket) do
    {:noreply,
     assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, normalize(params)))}
  end

  def handle_event("create", %{"webhook" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: normalize(params)) do
      {:ok, _endpoint} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
         |> load_endpoints()
         |> put_flash(:info, gettext("Webhook added."))}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  # --- inline edit -----------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org)
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"webhook" => params}, socket) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, normalize(params))
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"webhook" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: normalize(params)) do
      {:ok, _endpoint} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_endpoints() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
    end
  end

  # --- quick actions ---------------------------------------------------------

  def handle_event("toggle_active", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, endpoint} <- CMS.get_webhook_endpoint(id, actor: actor, tenant: org),
           {:ok, _} <-
             CMS.update_webhook_endpoint(endpoint, %{active: !endpoint.active},
               actor: actor,
               tenant: org
             ) do
        load_endpoints(socket)
      else
        _ -> put_flash(socket, :error, gettext("Couldn't update that webhook."))
      end

    {:noreply, socket}
  end

  # Send a test "ping" delivery to one endpoint (works while disabled too, so
  # a receiver can be verified before enabling).
  def handle_event("ping", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case CMS.get_webhook_endpoint(id, actor: actor, tenant: socket.assigns.current_org) do
        {:ok, endpoint} ->
          Webhooks.ping(endpoint)

          socket
          |> load_deliveries()
          |> put_flash(:info, gettext("Test ping queued — see deliveries below."))

        _ ->
          put_flash(socket, :error, gettext("Couldn't ping that webhook."))
      end

    {:noreply, socket}
  end

  # Replay a delivery as a fresh ledger row.
  def handle_event("redeliver", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case CMS.get_webhook_delivery(id, actor: actor, tenant: socket.assigns.current_org) do
        {:ok, delivery} ->
          Webhooks.redeliver(delivery)
          socket |> load_deliveries() |> put_flash(:info, gettext("Redelivery queued."))

        _ ->
          put_flash(socket, :error, gettext("Couldn't redeliver that webhook."))
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    org = socket.assigns.current_org

    socket =
      with {:ok, endpoint} <- CMS.get_webhook_endpoint(id, actor: actor, tenant: org),
           :ok <- CMS.destroy_webhook_endpoint(endpoint, actor: actor, tenant: org) do
        socket |> load_endpoints() |> put_flash(:info, gettext("Webhook deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that webhook."))
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  # --- data ------------------------------------------------------------------

  defp load_endpoints(socket) do
    assign(
      socket,
      :endpoints,
      CMS.list_webhook_endpoints!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [sort: [inserted_at: :asc]]
      )
    )
  end

  defp load_deliveries(socket) do
    assign(
      socket,
      :deliveries,
      CMS.recent_webhook_deliveries!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        load: [:endpoint]
      )
    )
  end

  defp create_form(actor, org),
    do:
      WebhookEndpoint
      |> AshPhoenix.Form.for_create(:create, actor: actor, tenant: org, as: "webhook")
      |> to_form()

  defp edit_form(id, actor, org) do
    CMS.get_webhook_endpoint!(id, actor: actor, tenant: org)
    |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "webhook")
    |> to_form()
  end

  # Checkboxes only submit checked boxes, so a fully-unchecked group sends no
  # `events` key at all. A hidden sentinel input guarantees the key is present;
  # here we drop that "" sentinel so it never reaches the array attribute.
  defp normalize(params) do
    events = params |> Map.get("events", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    Map.put(params, "events", events)
  end

  # A new endpoint (no value yet) defaults to every event, mirroring the
  # resource default; once edited, only the selected events stay checked.
  defp event_checked?(form, event) do
    case form[:events].value do
      nil -> true
      list when is_list(list) -> event in list
      _ -> false
    end
  end

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:webhooks}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Webhooks")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "POST a signed payload to external services when content is published, updated, or unpublished."
            )}
          </p>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Add a webhook")}</h2>
          <.form
            for={@form}
            id="new-webhook-form"
            phx-change="validate"
            phx-submit="create"
            class="card card-pad space-y-4"
          >
            <.input
              field={@form[:url]}
              type="url"
              label={gettext("Endpoint URL")}
              placeholder="https://example.com/hooks/kiln"
            />
            <fieldset>
              <legend class="text-sm font-medium">{gettext("Events")}</legend>
              <.event_checkboxes form={@form} available_events={@available_events} />
            </fieldset>
            <.button type="submit" variant="primary">{gettext("Add webhook")}</.button>
          </.form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">
            {gettext("Endpoints")} ({length(@endpoints)})
          </h2>

          <p :if={@endpoints == []} class="text-sm text-base-content/60">
            {gettext("No webhooks yet.")}
          </p>

          <ul
            :if={@endpoints != []}
            class="card divide-y divide-base-content/10 overflow-hidden"
          >
            <li :for={endpoint <- @endpoints} id={"webhook-#{endpoint.id}"} class="p-4">
              <div
                :if={!editing?(@edit, endpoint.id)}
                class="flex items-start justify-between gap-4"
              >
                <div class="min-w-0 space-y-2">
                  <div class="flex items-center gap-2">
                    <span class={[
                      "inline-block size-2 shrink-0 rounded-full",
                      endpoint.active && "bg-success",
                      !endpoint.active && "bg-base-content/30"
                    ]} />
                    <span class="sr-only">
                      {if endpoint.active, do: gettext("Active"), else: gettext("Disabled")}
                    </span>
                    <code class="truncate text-sm">{endpoint.url}</code>
                    <span
                      :if={endpoint.auto_disabled_at}
                      class="rounded bg-error/15 px-1.5 py-0.5 text-xs font-medium text-error"
                    >
                      {gettext("Auto-disabled after %{count} failed deliveries",
                        count: endpoint.consecutive_failures
                      )}
                    </span>
                    <span
                      :if={is_nil(endpoint.auto_disabled_at) && endpoint.consecutive_failures > 0}
                      class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning"
                    >
                      {gettext("%{count} failing", count: endpoint.consecutive_failures)}
                    </span>
                  </div>
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={event <- endpoint.events}
                      class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                    >
                      {event}
                    </span>
                  </div>
                  <p class="text-xs text-base-content/70">
                    {gettext("Signing secret")}: <code>{endpoint.secret}</code>
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="ping"
                    phx-value-id={endpoint.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Ping")}
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_active"
                    phx-value-id={endpoint.id}
                    class="btn btn-sm btn-default"
                  >
                    {if endpoint.active, do: gettext("Disable"), else: gettext("Enable")}
                  </button>
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-id={endpoint.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Edit")}
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={endpoint.id}
                    data-confirm={gettext("Delete this webhook? Deliveries will stop.")}
                    aria-label={gettext("Delete webhook")}
                    class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </div>

              <.form
                :if={editing?(@edit, endpoint.id)}
                for={@edit.form}
                id={"edit-webhook-#{endpoint.id}"}
                phx-change="validate_edit"
                phx-submit="save_edit"
                class="space-y-4"
              >
                <.input field={@edit.form[:url]} type="url" label={gettext("Endpoint URL")} />
                <label class="flex items-center gap-2 text-sm">
                  <input type="hidden" name="webhook[active]" value="false" />
                  <input
                    type="checkbox"
                    name="webhook[active]"
                    value="true"
                    checked={@edit.form[:active].value in [true, "true"]}
                    class="size-4 rounded border border-base-content/30 accent-primary"
                  />
                  {gettext("Active")}
                </label>
                <fieldset>
                  <legend class="text-sm font-medium">{gettext("Events")}</legend>
                  <.event_checkboxes form={@edit.form} available_events={@available_events} />
                </fieldset>
                <div class="flex gap-2">
                  <.button type="submit" variant="primary">{gettext("Save")}</.button>
                  <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-default">
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            </li>
          </ul>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Recent deliveries")}</h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Every delivery attempt is recorded; failures retry with backoff, and %{count} exhausted deliveries in a row disable an endpoint. History is kept for %{days} days.",
              count: Webhooks.auto_disable_after(),
              days: KilnCMS.CMS.WebhookDelivery.retention_days()
            )}
          </p>

          <p :if={@deliveries == []} class="text-sm text-base-content/60">
            {gettext("No deliveries yet.")}
          </p>

          <div :if={@deliveries != []} class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("When")}</th>
                  <th>{gettext("Event")}</th>
                  <th>{gettext("Endpoint")}</th>
                  <th>{gettext("Status")}</th>
                  <th>{gettext("Attempts")}</th>
                  <th>{gettext("HTTP")}</th>
                  <th>{gettext("Error")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={delivery <- @deliveries} id={"delivery-#{delivery.id}"}>
                  <td class="whitespace-nowrap text-base-content/70">
                    {Calendar.strftime(delivery.inserted_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td><code class="text-xs">{delivery.event}</code></td>
                  <td class="max-w-48 truncate">
                    <code class="text-xs">{delivery.endpoint && delivery.endpoint.url}</code>
                  </td>
                  <td>
                    <span class={[
                      "rounded px-1.5 py-0.5 text-xs font-medium",
                      delivery.status == :succeeded && "bg-success/15 text-success",
                      delivery.status == :failed && "bg-error/15 text-error",
                      delivery.status == :pending && "bg-warning/15 text-warning"
                    ]}>
                      {delivery_status_label(delivery.status)}
                    </span>
                  </td>
                  <td>{delivery.attempts}</td>
                  <td>{delivery.last_status}</td>
                  <td class="max-w-56 truncate text-xs text-base-content/70">
                    {delivery.last_error}
                  </td>
                  <td class="text-right">
                    <button
                      :if={delivery.status != :pending}
                      type="button"
                      phx-click="redeliver"
                      phx-value-id={delivery.id}
                      class="btn btn-sm btn-default"
                    >
                      {gettext("Redeliver")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.console>
    """
  end

  defp delivery_status_label(:succeeded), do: gettext("Delivered")
  defp delivery_status_label(:failed), do: gettext("Failed")
  defp delivery_status_label(:pending), do: gettext("Retrying")

  attr :form, :any, required: true
  attr :available_events, :list, required: true

  defp event_checkboxes(assigns) do
    ~H"""
    <%!-- Sentinel so an all-unchecked group still submits an (empty) events key. --%>
    <input type="hidden" name="webhook[events][]" value="" />
    <div class="mt-2 grid gap-1.5 sm:grid-cols-2 lg:grid-cols-3">
      <label :for={event <- @available_events} class="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          name="webhook[events][]"
          value={event}
          checked={event_checked?(@form, event)}
          class="size-4 rounded border border-base-content/30 accent-primary"
        />
        <code class="text-xs">{event}</code>
      </label>
    </div>
    """
  end

  defp editing?(nil, _id), do: false
  defp editing?(%{id: id}, id), do: true
  defp editing?(_edit, _id), do: false
end
