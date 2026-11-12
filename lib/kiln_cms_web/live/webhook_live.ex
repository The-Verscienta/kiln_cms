defmodule KilnCMSWeb.WebhookLive do
  @moduledoc """
  Webhooks (`/editor/webhooks`) — register outbound endpoints and choose which
  events each one receives. Admin-only, mirroring the `WebhookEndpoint` policy.

  Each endpoint's signing secret is masked in the list (`•••• ` and its last
  four characters, or dots alone for a secret under 16 characters) and is not
  sent to the browser until an admin reveals it (#2140). Reveal re-reads the
  endpoint with the admin as actor and the site as tenant, so a forged id from
  another site reveals nothing. A revealed secret gets a Copy button; Hide
  masks it again. Revealed state lasts for this LiveView session only. A newly
  added endpoint's secret starts revealed, so it can be copied into the
  receiver straight away. Rotate secret (#2347) replaces it and reveals the
  new one the same way, with a hint under it that deliveries already use the
  new secret (#2384). Hiding the secret drops the hint.

  A new endpoint starts with `WebhookEndpoint.default_events/1` ticked, which
  leaves out the events that carry unpublished content; those are marked in
  the list, and an endpoint subscribed to any of them says so on its row
  (#1776).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Webhooks

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Webhooks"))
     |> assign(:available_events, WebhookEndpoint.events(socket.assigns.current_org.id))
     |> assign(:default_events, WebhookEndpoint.default_events(socket.assigns.current_org))
     |> assign(:edit, nil)
     |> assign(:revealed, MapSet.new())
     |> assign(:rotated, MapSet.new())
     |> assign(:form, create_form(actor, socket.assigns.current_org))
     |> load_endpoints()
     |> load_deliveries()}
  end

  # --- create ----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"webhook" => params}, socket) when is_map(params) do
    {:noreply,
     assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, normalize(params)))}
  end

  def handle_event("create", %{"webhook" => params}, socket) when is_map(params) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: normalize(params)) do
      {:ok, endpoint} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
         |> load_endpoints()
         |> update(:revealed, &MapSet.put(&1, endpoint.id))
         |> put_flash(
           :info,
           gettext("Webhook added. Copy its signing secret into your receiver.")
         )}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  # --- bulk event selection (#1776) ----------------------------------------------

  # "Select all", "Clear", "Reset to defaults" and the per-group toggle, for the
  # new-endpoint form (`target=new`) or the one being edited (`target=edit`).
  # Runs through `validate` like a checkbox click, so the URL typed so far is
  # kept.
  def handle_event("select_events", %{"target" => target, "op" => op} = params, socket)
      when target in ["new", "edit"] and is_binary(op) do
    case target_form(socket, target) do
      nil ->
        {:noreply, socket}

      form ->
        events =
          bulk_select(
            op,
            params["group"],
            checked_events(form),
            socket.assigns.available_events,
            socket.assigns.default_events
          )

        form_params = form.source |> AshPhoenix.Form.params() |> Map.put("events", events)
        {:noreply, put_target_form(socket, target, AshPhoenix.Form.validate(form, form_params))}
    end
  end

  # --- inline edit -----------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org)
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"webhook" => params}, socket) when is_map(params) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, normalize(params))
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"webhook" => params}, socket) when is_map(params) do
    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: normalize(params)) do
      {:ok, _endpoint} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_endpoints() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
    end
  end

  # --- signing secret (#2140) ----------------------------------------------------

  # The id comes from the client, so re-read the endpoint as this admin on this
  # site before revealing: an id from another site, or one already deleted,
  # reveals nothing.
  def handle_event("reveal_secret", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor

    socket =
      with {:ok, endpoint} <-
             CMS.get_webhook_endpoint(id, actor: actor, tenant: socket.assigns.current_org),
           secret when is_binary(secret) <- WebhookEndpoint.secret(endpoint) do
        update(socket, :revealed, &MapSet.put(&1, endpoint.id))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't reveal that signing secret."))
      end

    {:noreply, socket}
  end

  # Replace the signing secret (#2347). The old one stops working at once. The
  # id comes from the client, so the endpoint is re-read inside this site
  # first: the tenant is what stops another site's id from being rotated.
  def handle_event("rotate_secret", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, endpoint} <- CMS.get_webhook_endpoint(id, actor: actor, tenant: org),
           {:ok, rotated} <- CMS.rotate_webhook_secret(endpoint, actor: actor, tenant: org) do
        socket
        |> load_endpoints()
        |> update(:revealed, &MapSet.put(&1, rotated.id))
        |> update(:rotated, &MapSet.put(&1, rotated.id))
        |> put_flash(
          :info,
          gettext(
            "Signing secret replaced. Copy the new secret into your receiver; the old one no longer works."
          )
        )
      else
        _ -> put_flash(socket, :error, gettext("Couldn't rotate that signing secret."))
      end

    {:noreply, socket}
  end

  def handle_event("hide_secret", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     socket
     |> update(:revealed, &MapSet.delete(&1, id))
     |> update(:rotated, &MapSet.delete(&1, id))}
  end

  # Pushed by the `Clipboard` hook on a revealed secret's Copy button.
  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Signing secret copied."))}

  # --- quick actions ---------------------------------------------------------

  def handle_event("toggle_active", %{"id" => id}, socket) when is_binary(id) do
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
  def handle_event("ping", %{"id" => id}, socket) when is_binary(id) do
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
  def handle_event("redeliver", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor

    socket =
      case CMS.get_webhook_delivery(id, actor: actor, tenant: socket.assigns.current_org) do
        {:ok, delivery} ->
          case Webhooks.redeliver(delivery) do
            # The page is stale: the endpoint was deleted after it rendered
            # (#2330). Reload so the row loses its button.
            {:error, :endpoint_deleted} ->
              socket
              |> load_deliveries()
              |> put_flash(
                :error,
                gettext("That delivery's endpoint was deleted, so it can't be redelivered.")
              )

            _queued ->
              socket |> load_deliveries() |> put_flash(:info, gettext("Redelivery queued."))
          end

        _ ->
          put_flash(socket, :error, gettext("Couldn't redeliver that webhook."))
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) when is_binary(id) do
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

  # A revealed secret stays revealed across a refresh only while its endpoint
  # is still listed.
  defp load_endpoints(socket) do
    endpoints =
      CMS.list_webhook_endpoints!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [sort: [inserted_at: :asc]]
      )

    listed = MapSet.new(endpoints, & &1.id)

    socket
    |> assign(:endpoints, endpoints)
    |> update(:revealed, &MapSet.intersection(&1, listed))
    |> update(:rotated, &MapSet.intersection(&1, listed))
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

  # Pre-checked with exactly the resource's default subscription for this org —
  # the list an endpoint created without naming events gets. It leaves out the
  # events that carry unpublished content (#1776); ticking every event here
  # used to send drafts to receivers that never asked for them.
  defp create_form(actor, org),
    do:
      WebhookEndpoint
      |> AshPhoenix.Form.for_create(:create,
        actor: actor,
        tenant: org,
        as: "webhook",
        params: %{"events" => WebhookEndpoint.default_events(org)}
      )
      |> to_form()

  defp edit_form(id, actor, org) do
    CMS.get_webhook_endpoint!(id, actor: actor, tenant: org)
    # Its own `id` so its inputs don't share the new form's DOM ids
    # (`webhook_url`); `as` keeps the `webhook[...]` param names.
    |> AshPhoenix.Form.for_update(:update,
      actor: actor,
      tenant: org,
      as: "webhook",
      id: "webhook_edit"
    )
    |> to_form()
  end

  # Checkboxes only submit checked boxes, so a fully-unchecked group sends no
  # `events` key at all. A hidden sentinel input guarantees the key is present;
  # here we drop that "" sentinel so it never reaches the array attribute.
  defp normalize(params) do
    events = params |> Map.get("events", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    Map.put(params, "events", events)
  end

  # The new form is seeded with the default events (`create_form/2`) and an
  # edit form with the endpoint's own, so a missing value checks nothing.
  defp checked_events(form) do
    case form[:events].value do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp target_form(socket, "new"), do: socket.assigns.form
  defp target_form(%{assigns: %{edit: %{form: form}}}, "edit"), do: form
  defp target_form(_socket, _target), do: nil

  defp put_target_form(socket, "new", form), do: assign(socket, :form, form)

  defp put_target_form(socket, "edit", form),
    do: assign(socket, :edit, %{socket.assigns.edit | form: form})

  # Events the list does not offer (a type deleted since) are kept by every
  # operation except Clear; the offered ones come back in the list's order.
  #
  # Select all leaves the security alert events out (#2642), keeping any
  # already ticked. It exists to mirror content: an endpoint that took every
  # event that way would ship client addresses and actor ids to a receiver
  # nobody chose for them, and every later edit of it would send each admin
  # an un-mutable notice. The security group's own toggle still ticks them.
  defp bulk_select("all", _group, current, available, _defaults) do
    Enum.filter(available, &(&1 in current or not security_event?(&1))) ++
      (current -- available)
  end

  defp bulk_select("none", _group, _current, _available, _defaults), do: []

  defp bulk_select("defaults", _group, _current, _available, defaults), do: defaults

  defp bulk_select("group", group, current, available, _defaults) when is_binary(group) do
    members = Enum.filter(available, &(event_group(&1) == group))

    if members != [] and Enum.all?(members, &(&1 in current)) do
      current -- members
    else
      Enum.filter(available, &(&1 in current or &1 in members)) ++ (current -- available)
    end
  end

  defp bulk_select(_op, _group, current, _available, _defaults), do: current

  # By prefix, like the delivery side: a kind a later release adds is one too.
  defp security_event?(event), do: String.starts_with?(event, "security.")

  # `page.published` → `page`; `form.submitted` → `form`.
  defp event_group(event), do: event |> String.split(".", parts: 2) |> hd()

  # The offered events in their list order, one group per leading segment.
  defp event_groups(available), do: Enum.chunk_by(available, &event_group/1)

  defp draft_events(events), do: Enum.filter(events, &WebhookEndpoint.carries_drafts?/1)

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:webhooks}
    >
      <div class="space-y-8">
        <div>
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:webhooks}
          />
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
              <.event_checkboxes form={@form} available_events={@available_events} target="new" />
            </fieldset>
            <.button type="submit" variant="primary">{gettext("Add webhook")}</.button>
          </.form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">
            {gettext("Endpoints")} ({length(@endpoints)})
          </h2>

          <.empty_state
            :if={@endpoints == []}
            icon="hero-bolt"
            title={gettext("No webhooks yet")}
          >
            {gettext("Add an endpoint above to push content events to another system.")}
          </.empty_state>

          <ul
            :if={@endpoints != []}
            class="card divide-y divide-base-content/10 overflow-hidden"
          >
            <li :for={endpoint <- @endpoints} id={"webhook-#{endpoint.id}"} class="p-4">
              <div
                :if={!editing?(@edit, endpoint.id)}
                class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4"
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
                    <span
                      :if={draft_events(endpoint.events || []) != []}
                      id={"webhook-#{endpoint.id}-drafts"}
                      title={Enum.join(draft_events(endpoint.events || []), ", ")}
                      class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning-ink"
                    >
                      {gettext("Receives unpublished content")}
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
                  <.signing_secret
                    endpoint={endpoint}
                    revealed={MapSet.member?(@revealed, endpoint.id)}
                    rotated={MapSet.member?(@rotated, endpoint.id)}
                  />
                </div>
                <div class="flex shrink-0 flex-wrap items-center gap-1">
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
                    :if={CMS.can_rotate_webhook_secret?(@actor, endpoint, tenant: @current_org)}
                    type="button"
                    id={"rotate-secret-#{endpoint.id}"}
                    phx-click="rotate_secret"
                    phx-value-id={endpoint.id}
                    phx-disable-with={gettext("Rotating…")}
                    data-confirm={rotate_confirmation()}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Rotate secret")}
                  </button>
                  <%!-- Labelled, not icon-only (#2136): beside three text
                       buttons an unlabelled trash icon went unseen. This and
                       the edit form's Delete share a selector; the row and
                       the form are `:if`-exclusive, so only one renders. --%>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={endpoint.id}
                    data-confirm={delete_confirmation()}
                    aria-label={gettext("Delete webhook")}
                    class="btn btn-sm btn-danger"
                  >
                    <.icon name="hero-trash" class="size-4" />
                    {gettext("Delete")}
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
                  <.event_checkboxes
                    form={@edit.form}
                    available_events={@available_events}
                    target="edit"
                  />
                </fieldset>
                <div class="flex flex-wrap items-center gap-2">
                  <.button type="submit" variant="primary">{gettext("Save")}</.button>
                  <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-default">
                    {gettext("Cancel")}
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={endpoint.id}
                    data-confirm={delete_confirmation()}
                    class="btn btn-sm btn-danger ml-auto"
                  >
                    <.icon name="hero-trash" class="size-4" />
                    {gettext("Delete webhook")}
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

          <.empty_state
            :if={@deliveries == []}
            id="webhook-deliveries-empty"
            icon="hero-arrow-up-tray"
            title={gettext("No deliveries yet.")}
            compact
          >
            {gettext("Each attempt to call an endpoint is listed here.")}
          </.empty_state>

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
                    <code :if={delivery.endpoint_id} class="text-xs">
                      {delivery.endpoint && delivery.endpoint.url}
                    </code>
                    <%!-- The endpoint was deleted; the row keeps its URL copy (#2330). --%>
                    <code :if={is_nil(delivery.endpoint_id) and delivery.endpoint_url} class="text-xs">
                      {delivery.endpoint_url}
                    </code>
                    <span
                      :if={is_nil(delivery.endpoint_id)}
                      data-role="deleted-endpoint"
                      class="text-xs italic text-base-content/70"
                    >
                      ({gettext("deleted endpoint")})
                    </span>
                  </td>
                  <td>
                    <span class={[
                      "rounded px-1.5 py-0.5 text-xs font-medium",
                      delivery.status == :succeeded && "bg-success/15 text-success-ink",
                      delivery.status == :failed && "bg-error/15 text-error-ink",
                      delivery.status == :pending && "bg-warning/15 text-warning-ink"
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
                      :if={delivery.status != :pending and not is_nil(delivery.endpoint_id)}
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

  attr :endpoint, :map, required: true
  attr :revealed, :boolean, required: true
  attr :rotated, :boolean, default: false

  # The plaintext secret is rendered only while revealed; masked, the page
  # carries at most its last four characters (#2140).
  defp signing_secret(assigns) do
    assigns = assign(assigns, :secret, WebhookEndpoint.secret(assigns.endpoint))

    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/70">
      <span>{gettext("Signing secret")}:</span>
      <%= cond do %>
        <% is_nil(@secret) -> %>
          <span class="text-error">
            {gettext(
              "unreadable — it was encrypted under a SECRET_KEY_BASE this server no longer has. Rotate the secret, or delete and re-create the endpoint."
            )}
          </span>
        <% @revealed -> %>
          <code id={"webhook-#{@endpoint.id}-secret"} class="break-all">{@secret}</code>
          <button
            type="button"
            id={"copy-secret-#{@endpoint.id}"}
            phx-hook="Clipboard"
            data-clipboard-text={@secret}
            aria-label={gettext("Copy signing secret for %{url}", url: @endpoint.url)}
            class="btn btn-sm btn-default px-2 py-0.5 text-xs"
          >
            <.icon name="hero-clipboard-document" class="size-3.5" />
            {gettext("Copy")}
          </button>
          <button
            type="button"
            id={"reveal-secret-#{@endpoint.id}"}
            phx-click="hide_secret"
            phx-value-id={@endpoint.id}
            aria-label={gettext("Hide signing secret for %{url}", url: @endpoint.url)}
            class="btn btn-sm btn-default px-2 py-0.5 text-xs"
          >
            <.icon name="hero-eye-slash" class="size-3.5" />
            {gettext("Hide")}
          </button>
          <p
            :if={@rotated}
            id={"webhook-#{@endpoint.id}-rotated-hint"}
            class="basis-full text-warning-ink"
          >
            <.icon name="hero-exclamation-triangle" class="size-3.5" />
            {gettext("Update your receiver now: deliveries already use this secret.")}
          </p>
        <% true -> %>
          <span id={"webhook-#{@endpoint.id}-secret-masked"} class="font-mono">
            {mask_secret(@secret)}
          </span>
          <button
            type="button"
            id={"reveal-secret-#{@endpoint.id}"}
            phx-click="reveal_secret"
            phx-value-id={@endpoint.id}
            aria-label={gettext("Reveal signing secret for %{url}", url: @endpoint.url)}
            class="btn btn-sm btn-default px-2 py-0.5 text-xs"
          >
            <.icon name="hero-eye" class="size-3.5" />
            {gettext("Reveal")}
          </button>
      <% end %>
    </div>
    """
  end

  # A short secret's last four characters would be most of it, so it shows
  # dots alone.
  @mask "••••"
  defp mask_secret(secret) do
    if String.length(secret) >= 16, do: @mask <> " " <> String.slice(secret, -4, 4), else: @mask
  end

  defp delivery_status_label(:succeeded), do: gettext("Delivered")
  defp delivery_status_label(:failed), do: gettext("Failed")
  defp delivery_status_label(:pending), do: gettext("Retrying")

  attr :form, :any, required: true
  attr :available_events, :list, required: true
  attr :target, :string, required: true, doc: ~s("new" or "edit": which form the buttons act on)

  defp event_checkboxes(assigns) do
    assigns = assign(assigns, :checked, checked_events(assigns.form))

    ~H"""
    <p class="mt-1 text-xs text-base-content/70">
      {gettext(
        "Events marked “includes unpublished content” send the full body of drafts and embargoed documents. They are off by default: select them only if this receiver should see content before it is published."
      )}
    </p>
    <div class="mt-2 flex flex-wrap gap-2" role="group" aria-label={gettext("Select events")}>
      <button
        type="button"
        phx-click="select_events"
        phx-value-target={@target}
        phx-value-op="all"
        title={gettext("Select all events except security alerts")}
        class="btn btn-sm btn-default"
      >
        {gettext("Select all")}
      </button>
      <button
        type="button"
        phx-click="select_events"
        phx-value-target={@target}
        phx-value-op="none"
        class="btn btn-sm btn-default"
      >
        {gettext("Clear")}
      </button>
      <button
        type="button"
        phx-click="select_events"
        phx-value-target={@target}
        phx-value-op="defaults"
        class="btn btn-sm btn-default"
      >
        {gettext("Reset to defaults")}
      </button>
    </div>
    <%!-- Sentinel so an all-unchecked group still submits an (empty) events key. --%>
    <input type="hidden" name="webhook[events][]" value="" />
    <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <div
        :for={events <- event_groups(@available_events)}
        id={"#{@target}-events-#{event_group(hd(events))}"}
        class="rounded-lg border border-base-content/10 p-3"
      >
        <div class="mb-2 flex items-center justify-between gap-2">
          <code class="text-xs font-semibold">{event_group(hd(events))}</code>
          <button
            type="button"
            phx-click="select_events"
            phx-value-target={@target}
            phx-value-op="group"
            phx-value-group={event_group(hd(events))}
            aria-label={
              if Enum.all?(events, &(&1 in @checked)),
                do: gettext("Clear %{group} events", group: event_group(hd(events))),
                else: gettext("Select all %{group} events", group: event_group(hd(events)))
            }
            class="btn btn-sm btn-default px-2 py-0.5 text-xs"
          >
            {if Enum.all?(events, &(&1 in @checked)),
              do: gettext("Clear"),
              else: gettext("Select all")}
          </button>
        </div>
        <div class="space-y-1.5">
          <label :for={event <- events} class="flex flex-wrap items-center gap-x-2 text-sm">
            <input
              type="checkbox"
              name="webhook[events][]"
              value={event}
              checked={event in @checked}
              class="size-4 rounded border border-base-content/30 accent-primary"
            />
            <code class="text-xs">{event}</code>
            <span
              :if={WebhookEndpoint.carries_drafts?(event)}
              class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning-ink"
            >
              {gettext("includes unpublished content")}
            </span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  defp rotate_confirmation do
    gettext(
      "Rotate this signing secret? Deliveries start using the new secret now, and the old one stops working, so update the receiver with the new secret."
    )
  end

  # Deleting nilifies the deliveries' endpoint (history stays, under the usual
  # retention), and the delivery worker settles a queued row whose endpoint is
  # gone as failed rather than sending it.
  defp delete_confirmation do
    gettext(
      "Delete this webhook? Queued deliveries, including retractions, won't be sent. Delivery history is kept."
    )
  end

  defp editing?(nil, _id), do: false
  defp editing?(%{id: id}, id), do: true
  defp editing?(_edit, _id), do: false
end
