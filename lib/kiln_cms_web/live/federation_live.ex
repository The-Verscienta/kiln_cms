defmodule KilnCMSWeb.FederationLive do
  @moduledoc """
  `/editor/federation` (#967, phase 2 of #491): the site's ActivityPub actor
  from inside the app rather than `mix kiln.federation`.

  What it shows, top to bottom: the **two halves of the gate** (the
  deployment's `KILN_FEDERATION_ENABLED`, which only an operator can set, and
  this site's own switch), the handle and actor id, the profile fields an
  admin may edit (`display_name` / `summary` — the `:save` action, unused
  until now), the **followers** (who, since when, how their deliveries are
  going, and a block button), the **delivery ledger** with its failures, and
  the **block list** (actors and instances refused before a `Follow` is
  written — the durable answer to an abusive follower that a bare delete was
  not).

  Admin-only, in the `:admin_routes` live session — the same tier as
  `/editor/webhooks`, and the tier `SiteFederation`/`Follower`/`Block` writes
  are policy-gated to.

  Enabling from here mints the site's permanent identity exactly as the mix
  task does (`:enable`, origin defaulted to the site's base URL, username to
  the org slug), and says so before it happens: the handle cannot be renamed
  once followers know it. Disabling keeps the identity, as the resource's
  moduledoc explains, so re-enabling restores the same handle and key.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Federation
  alias KilnCMS.Federation.Actor

  @deliveries_shown 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Federation"))
     |> load()}
  end

  # ── the gate ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("enable", params, socket) do
    org = socket.assigns.current_org
    origin = blank_to_nil(params["origin"]) || KilnCMSWeb.Tenant.base_url(org)
    username = blank_to_nil(params["username"]) || org.slug

    case Federation.enable_site_federation(origin, username, actor_opts(socket)) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Federation enabled. This site's handle is now permanent."))
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("disable", _params, socket) do
    case socket.assigns.settings do
      nil ->
        {:noreply, socket}

      settings ->
        case Federation.disable_site_federation(settings, actor_opts(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext(
                 "Federation disabled. The identity is kept, so re-enabling restores the same handle."
               )
             )
             |> load()}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, error_message(error))}
        end
    end
  end

  # ── the profile ────────────────────────────────────────────────────────────

  def handle_event("save_profile", %{"profile" => params}, socket) when is_map(params) do
    attrs = %{
      display_name: blank_to_nil(params["display_name"]),
      summary: blank_to_nil(params["summary"])
    }

    case Federation.save_site_federation(attrs, actor_opts(socket)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Profile saved.")) |> load()}
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # ── followers and blocks ───────────────────────────────────────────────────

  def handle_event("block", %{"kind" => kind, "value" => value} = params, socket)
      when kind in ["actor", "instance"] and is_binary(value) do
    reason = blank_to_nil(params["reason"])

    case Federation.block_and_drop(
           String.to_existing_atom(kind),
           value,
           reason,
           actor_opts(socket)
         ) do
      {:ok, _block} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Blocked. Matching followers were removed."))
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("block", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Something went wrong."))}

  def handle_event("unblock", %{"id" => id}, socket) when is_binary(id) do
    with %{} = block <- Enum.find(socket.assigns.blocks, &(&1.id == id)),
         :ok <- Federation.unblock(block, actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, gettext("Unblocked.")) |> load()}
    else
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Unblocked.")) |> load()}
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
      _none -> {:noreply, socket}
    end
  end

  def handle_event("remove_follower", %{"id" => id}, socket) when is_binary(id) do
    with %{} = follower <- Enum.find(socket.assigns.followers, &(&1.id == id)),
         :ok <- Federation.destroy_follower(follower, actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, gettext("Follower removed.")) |> load()}
    else
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Follower removed.")) |> load()}
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
      _none -> {:noreply, socket}
    end
  end

  # ── state ──────────────────────────────────────────────────────────────────

  defp load(socket) do
    opts = actor_opts(socket)

    settings =
      case Federation.list_site_federation(opts) do
        {:ok, [row | _]} -> row
        _ -> nil
      end

    followers = Federation.list_followers!(Keyword.put(opts, :query, sort: [inserted_at: :desc]))

    deliverable = Federation.deliverable_followers!(opts) |> length()

    deliveries =
      Federation.list_federation_deliveries!(
        Keyword.put(opts, :query, sort: [inserted_at: :desc], limit: @deliveries_shown)
      )

    socket
    |> assign(:deployment_enabled?, Federation.enabled?())
    |> assign(:settings, settings)
    |> assign(:identity, identity(settings))
    |> assign(:followers, followers)
    |> assign(:deliverable_count, deliverable)
    |> assign(:deliveries, deliveries)
    |> assign(
      :blocks,
      Federation.list_blocks!(Keyword.put(opts, :query, sort: [inserted_at: :desc]))
    )
    |> assign(:default_origin, KilnCMSWeb.Tenant.base_url(socket.assigns.current_org))
    |> assign(:default_username, socket.assigns.current_org.slug)
    |> assign(:drop_after, Federation.drop_follower_after())
    |> assign(:profile_form, to_form(%{}, as: :profile))
  end

  defp identity(%{origin: origin, username: username} = settings)
       when is_binary(origin) and is_binary(username),
       do: Actor.identity(settings)

  defp identity(_settings), do: nil

  defp actor_opts(socket),
    do: [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_to_nil(_), do: nil

  defp error_message(%Ash.Error.Forbidden{}),
    do: gettext("You don't have permission to change this site's federation settings.")

  defp error_message(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map_join(" ", &Exception.message/1)
    |> case do
      "" -> gettext("The change could not be saved.")
      message -> message
    end
  end

  defp host_of(uri), do: Federation.actor_host(uri) || uri

  defp delivery_state(:pending), do: {gettext("Pending"), "badge-ghost"}
  defp delivery_state(:delivered), do: {gettext("Delivered"), "badge-success"}
  defp delivery_state(:failed), do: {gettext("Failed"), "badge-error"}
  defp delivery_state(other), do: {to_string(other), "badge-ghost"}

  defp block_kind(:actor), do: gettext("actor")
  defp block_kind(:instance), do: gettext("instance")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:federation}
    >
      <div class="space-y-8">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("Federation")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "This site as an ActivityPub actor: who follows it, how deliveries are going, and who is refused."
            )}
          </p>
        </div>

        <%!-- ── the gate ─────────────────────────────────────────────── --%>
        <section class="card card-pad space-y-3">
          <h2 class="text-lg font-medium">{gettext("Status")}</h2>
          <dl class="grid gap-2 text-sm sm:grid-cols-[10rem_1fr]">
            <dt class="text-base-content/70">{gettext("Deployment")}</dt>
            <dd id="deployment-gate">
              <%= if @deployment_enabled? do %>
                {gettext("enabled")}
              <% else %>
                <span class="text-warning-ink">
                  {gettext(
                    "disabled — every federation route 404s until the operator sets KILN_FEDERATION_ENABLED"
                  )}
                </span>
              <% end %>
            </dd>
            <dt class="text-base-content/70">{gettext("This site")}</dt>
            <dd id="site-gate">
              <%= cond do %>
                <% is_nil(@settings) -> %>
                  {gettext("never enabled")}
                <% @settings.enabled -> %>
                  {gettext("enabled")}
                <% true -> %>
                  {gettext("disabled (identity kept)")}
              <% end %>
            </dd>
            <dt :if={@identity} class="text-base-content/70">{gettext("Handle")}</dt>
            <dd :if={@identity} id="handle" class="font-mono">{@identity.handle}</dd>
            <dt :if={@identity} class="text-base-content/70">{gettext("Actor")}</dt>
            <dd :if={@identity} class="break-all font-mono text-xs">{@identity.actor_id}</dd>
            <dt :if={@settings && @settings.last_delivered_at} class="text-base-content/70">
              {gettext("Last delivered")}
            </dt>
            <dd :if={@settings && @settings.last_delivered_at}>
              {Calendar.strftime(@settings.last_delivered_at, "%Y-%m-%d %H:%M UTC")}
            </dd>
          </dl>

          <form :if={is_nil(@settings) or not @settings.enabled} phx-submit="enable" class="space-y-2">
            <p :if={is_nil(@settings)} class="text-xs text-base-content/60">
              {gettext(
                "Enabling mints this site's permanent actor identity. The handle cannot be renamed once other servers know it — pick the username with care."
              )}
            </p>
            <div :if={is_nil(@settings)} class="grid gap-3 sm:grid-cols-2">
              <div>
                <label for="fed-username" class="text-sm font-medium">{gettext("Username")}</label>
                <input
                  id="fed-username"
                  name="username"
                  value={@default_username}
                  class="field-input mt-1 font-mono"
                />
              </div>
              <div>
                <label for="fed-origin" class="text-sm font-medium">{gettext("Origin")}</label>
                <input
                  id="fed-origin"
                  name="origin"
                  value={@default_origin}
                  class="field-input mt-1 font-mono text-xs"
                />
              </div>
            </div>
            <.button type="submit" variant="primary">
              {if is_nil(@settings),
                do: gettext("Enable federation"),
                else: gettext("Re-enable federation")}
            </.button>
          </form>

          <button
            :if={@settings && @settings.enabled}
            type="button"
            phx-click="disable"
            data-confirm={
              gettext("Disable federation? Followers stop receiving posts; the identity is kept.")
            }
            class="btn btn-ghost btn-sm"
          >
            {gettext("Disable federation")}
          </button>
        </section>

        <%!-- ── the profile ──────────────────────────────────────────── --%>
        <section :if={@settings} class="card card-pad space-y-3">
          <h2 class="text-lg font-medium">{gettext("Profile")}</h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "What other servers show for this actor. Peers refetch it on their own schedule."
            )}
          </p>
          <.form for={@profile_form} id="profile-form" phx-submit="save_profile" class="space-y-3">
            <div>
              <label for="profile-display-name" class="text-sm font-medium">{gettext("Display name")}</label>
              <input
                id="profile-display-name"
                name="profile[display_name]"
                value={@settings.display_name}
                class="field-input mt-1"
              />
            </div>
            <div>
              <label for="profile-summary" class="text-sm font-medium">{gettext("Summary")}</label>
              <textarea id="profile-summary" name="profile[summary]" rows="3" class="field-input mt-1">{@settings.summary}</textarea>
            </div>
            <.button type="submit" variant="primary">{gettext("Save profile")}</.button>
          </.form>
        </section>

        <%!-- ── followers ────────────────────────────────────────────── --%>
        <section class="space-y-3">
          <h2 class="text-lg font-medium">
            {gettext("Followers")} ({length(@followers)})
            <span class="ml-2 text-xs font-normal text-base-content/60">
              {gettext("%{count} will be delivered to", count: @deliverable_count)}
            </span>
          </h2>
          <p :if={@followers == []} class="text-sm text-base-content/60">
            {gettext("Nobody follows this site yet.")}
          </p>
          <div :if={@followers != []} class="card overflow-x-auto">
            <table class="table" id="followers-table">
              <thead>
                <tr>
                  <th scope="col">{gettext("Actor")}</th>
                  <th scope="col">{gettext("Since")}</th>
                  <th scope="col">{gettext("Last delivered")}</th>
                  <th scope="col">{gettext("Failures")}</th>
                  <th scope="col"><span class="sr-only">{gettext("Actions")}</span></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={f <- @followers} id={"follower-#{f.id}"}>
                  <td class="break-all font-mono text-xs">{f.actor_uri}</td>
                  <td class="text-xs">{Calendar.strftime(f.inserted_at, "%Y-%m-%d")}</td>
                  <td class="text-xs">
                    {if f.last_delivered_at,
                      do: Calendar.strftime(f.last_delivered_at, "%Y-%m-%d %H:%M"),
                      else: "—"}
                  </td>
                  <td class="tabular-nums text-xs">
                    {f.consecutive_failures}
                    <span :if={f.consecutive_failures >= @drop_after} class="text-warning-ink">
                      {gettext("(dropped from delivery)")}
                    </span>
                  </td>
                  <td class="flex flex-wrap gap-1">
                    <button
                      type="button"
                      phx-click="block"
                      phx-value-kind="actor"
                      phx-value-value={f.actor_uri}
                      data-confirm={
                        gettext(
                          "Block this actor? Its follow is removed and future follows are refused."
                        )
                      }
                      class="btn btn-ghost btn-xs"
                    >
                      {gettext("Block actor")}
                    </button>
                    <button
                      type="button"
                      phx-click="block"
                      phx-value-kind="instance"
                      phx-value-value={host_of(f.actor_uri)}
                      data-confirm={
                        gettext(
                          "Block this whole instance? Every follower on it is removed and future follows from it are refused."
                        )
                      }
                      class="btn btn-ghost btn-xs"
                    >
                      {gettext("Block instance")}
                    </button>
                    <button
                      type="button"
                      phx-click="remove_follower"
                      phx-value-id={f.id}
                      data-confirm={
                        gettext("Remove this follower? It can follow again unless you block it.")
                      }
                      class="btn btn-ghost btn-xs text-error"
                    >
                      {gettext("Remove")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- ── blocks ───────────────────────────────────────────────── --%>
        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Blocked")} ({length(@blocks)})</h2>
          <form phx-submit="block" class="card card-pad grid gap-3 sm:grid-cols-[8rem_1fr_1fr_auto]">
            <div>
              <label for="block-kind" class="text-sm font-medium">{gettext("Kind")}</label>
              <select id="block-kind" name="kind" class="field-input mt-1">
                <option value="instance">{gettext("instance")}</option>
                <option value="actor">{gettext("actor")}</option>
              </select>
            </div>
            <div>
              <label for="block-value" class="text-sm font-medium">{gettext("Host or actor URI")}</label>
              <input
                id="block-value"
                name="value"
                required
                class="field-input mt-1 font-mono text-xs"
                placeholder="spam.example"
              />
            </div>
            <div>
              <label for="block-reason" class="text-sm font-medium">{gettext("Reason")}</label>
              <input id="block-reason" name="reason" class="field-input mt-1" />
            </div>
            <div class="flex items-end">
              <.button type="submit" size="sm">{gettext("Block")}</.button>
            </div>
          </form>
          <p :if={@blocks == []} class="text-sm text-base-content/60">
            {gettext("Nothing is blocked.")}
          </p>
          <ul
            :if={@blocks != []}
            class="card divide-y divide-base-content/10 overflow-hidden"
            id="blocks-list"
          >
            <li
              :for={b <- @blocks}
              id={"block-#{b.id}"}
              class="flex flex-wrap items-center justify-between gap-3 p-3 text-sm"
            >
              <div class="min-w-0">
                <span class="badge badge-sm mr-2">{block_kind(b.kind)}</span>
                <span class="break-all font-mono text-xs">{b.value}</span>
                <span :if={b.reason} class="ml-2 text-xs text-base-content/60">— {b.reason}</span>
              </div>
              <button
                type="button"
                phx-click="unblock"
                phx-value-id={b.id}
                class="btn btn-ghost btn-xs"
              >
                {gettext("Unblock")}
              </button>
            </li>
          </ul>
        </section>

        <%!-- ── deliveries ───────────────────────────────────────────── --%>
        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Recent deliveries")}</h2>
          <p :if={@deliveries == []} class="text-sm text-base-content/60">
            {gettext("Nothing has been delivered yet.")}
          </p>
          <div :if={@deliveries != []} class="card overflow-x-auto">
            <table class="table" id="deliveries-table">
              <thead>
                <tr>
                  <th scope="col">{gettext("When")}</th>
                  <th scope="col">{gettext("Activity")}</th>
                  <th scope="col">{gettext("Inbox")}</th>
                  <th scope="col">{gettext("State")}</th>
                  <th scope="col">{gettext("Attempts")}</th>
                  <th scope="col">{gettext("Last error")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={d <- @deliveries} id={"delivery-#{d.id}"}>
                  <td class="text-xs">{Calendar.strftime(d.inserted_at, "%Y-%m-%d %H:%M")}</td>
                  <td class="text-xs">{d.activity_type}</td>
                  <td class="break-all font-mono text-xs">{d.inbox_uri}</td>
                  <td>
                    <% {label, class} = delivery_state(d.state) %>
                    <span class={["badge badge-sm", class]}>{label}</span>
                  </td>
                  <td class="tabular-nums text-xs">{d.attempts}</td>
                  <td class="text-xs text-base-content/70">
                    {if d.last_status, do: "#{d.last_status} ", else: ""}{d.last_error}
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
end
