defmodule KilnCMSWeb.TeamLive do
  @moduledoc """
  Team management (`/editor/team`) — granular RBAC without AshAdmin (#332,
  slice 4). Admin-only, mirroring the `OrgMembership`/`Role` policies.

  Two panels for the *current* org (multi-site admins switch org by host, like
  every other console page):

    * **Members** — the org's memberships: capability tier, assigned custom
      role, and per-member overrides of the scope axes.
    * **Roles** — the org's custom roles: named bundles of `editable_types` /
      `readable_types` / `field_grants` (see docs/granular-rbac.md).

  Scope-axis inputs are deliberately plain: comma-separated type lists and a
  JSON textarea for field grants (the same convention as the automation rule
  config), keeping the first team UI honest instead of half-modelling a
  permission matrix.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Role

  @tier_options [{"Viewer", :viewer}, {"Editor", :editor}, {"Admin", :admin}]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Team"))
       |> assign(:member_edit, nil)
       |> assign(:role_edit, nil)
       |> assign(:role_form, role_form(actor))
       |> load_data()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- members ---------------------------------------------------------------

  @impl true
  def handle_event("add_member", %{"member" => %{"email" => email} = params}, socket) do
    %{actor: actor, current_org: org} = socket.assigns

    with {:ok, user} <- find_user(email, actor),
         {:ok, _} <-
           Accounts.create_org_membership(
             %{
               user_id: user.id,
               organization_id: org.id,
               role: params["role"] || "viewer",
               role_id: presence(params["role_id"])
             },
             actor: actor
           ) do
      {:noreply, socket |> load_data() |> put_flash(:info, gettext("Member added to this site."))}
    else
      {:error, :not_found} ->
        {:noreply,
         put_flash(socket, :error, gettext("No account with that email address exists."))}

      {:error, _error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Couldn't add that member — are they already on this site?")
         )}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    %{actor: actor} = socket.assigns

    socket =
      with {:ok, membership} <- get_membership(socket, id),
           :ok <- Accounts.remove_org_membership(membership, actor: actor) do
        socket |> load_data() |> put_flash(:info, gettext("Member removed."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't remove that member."))
      end

    {:noreply, assign(socket, :member_edit, nil)}
  end

  def handle_event("edit_member", %{"id" => id}, socket) do
    case get_membership(socket, id) do
      {:ok, membership} ->
        form =
          membership
          |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.actor, as: "member")
          |> to_form()

        {:noreply, assign(socket, :member_edit, %{id: id, form: form})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_member_edit", _params, socket),
    do: {:noreply, assign(socket, :member_edit, nil)}

  def handle_event("save_member", %{"member" => params}, socket) do
    case submit_scoped(socket.assigns.member_edit.form, params) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:member_edit, nil) |> load_data() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :member_edit, %{socket.assigns.member_edit | form: form})}

      {:invalid_json, form} ->
        {:noreply,
         socket
         |> assign(:member_edit, %{socket.assigns.member_edit | form: form})
         |> put_flash(:error, gettext("Field grants must be a JSON object."))}
    end
  end

  # --- roles -----------------------------------------------------------------

  def handle_event("create_role", %{"role" => params}, socket) do
    params = Map.put(params, "org_id", socket.assigns.current_org.id)

    case submit_scoped(socket.assigns.role_form, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:role_form, role_form(socket.assigns.actor))
         |> load_data()
         |> put_flash(:info, gettext("Role added."))}

      {:error, form} ->
        {:noreply, assign(socket, :role_form, form)}

      {:invalid_json, form} ->
        {:noreply,
         socket
         |> assign(:role_form, form)
         |> put_flash(:error, gettext("Field grants must be a JSON object."))}
    end
  end

  def handle_event("edit_role", %{"id" => id}, socket) do
    case Accounts.get_role(id, actor: socket.assigns.actor) do
      {:ok, role} ->
        form =
          role
          |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.actor, as: "role")
          |> to_form()

        {:noreply, assign(socket, :role_edit, %{id: id, form: form})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_role_edit", _params, socket),
    do: {:noreply, assign(socket, :role_edit, nil)}

  def handle_event("save_role", %{"role" => params}, socket) do
    case submit_scoped(socket.assigns.role_edit.form, params) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:role_edit, nil) |> load_data() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :role_edit, %{socket.assigns.role_edit | form: form})}

      {:invalid_json, form} ->
        {:noreply,
         socket
         |> assign(:role_edit, %{socket.assigns.role_edit | form: form})
         |> put_flash(:error, gettext("Field grants must be a JSON object."))}
    end
  end

  def handle_event("delete_role", %{"id" => id}, socket) do
    %{actor: actor} = socket.assigns

    socket =
      with {:ok, role} <- Accounts.get_role(id, actor: actor),
           :ok <- Accounts.destroy_role(role, actor: actor) do
        socket |> load_data() |> put_flash(:info, gettext("Role deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that role."))
      end

    {:noreply, assign(socket, :role_edit, nil)}
  end

  # --- data ------------------------------------------------------------------

  defp load_data(socket) do
    %{actor: actor, current_org: org} = socket.assigns

    members =
      Accounts.list_memberships_for_org!(org.id,
        actor: actor,
        load: [:user, :custom_role],
        query: [sort: [inserted_at: :asc]]
      )

    roles =
      Accounts.list_roles_for_org!(org.id, actor: actor, query: [sort: [name: :asc]])

    socket |> assign(:members, members) |> assign(:roles, roles)
  end

  defp get_membership(socket, id) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  end

  defp find_user(email, actor) do
    case Accounts.get_user_by_email(String.trim(to_string(email)), actor: actor) do
      {:ok, %{} = user} -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  defp role_form(actor) do
    Role
    |> AshPhoenix.Form.for_create(:create, actor: actor, as: "role")
    |> to_form()
  end

  # Scope-axis inputs arrive as text: comma-separated type lists and a JSON
  # field-grants object. Convert before submit; bad JSON gets its own outcome
  # for a friendly flash (same convention as the automation config).
  defp submit_scoped(form, params) do
    case normalize_scopes(params) do
      {:ok, params} -> AshPhoenix.Form.submit(form, params: params)
      :error -> {:invalid_json, AshPhoenix.Form.validate(form, params)}
    end
  end

  defp normalize_scopes(params) do
    params =
      params
      |> split_list("editable_types")
      |> split_list("readable_types")
      |> Map.replace("role_id", presence(params["role_id"]))

    case params do
      %{"field_grants" => raw} when is_binary(raw) ->
        case decode_grants(raw) do
          {:ok, grants} -> {:ok, Map.put(params, "field_grants", grants)}
          :error -> :error
        end

      _ ->
        {:ok, params}
    end
  end

  defp split_list(%{} = params, key) do
    case params do
      %{^key => raw} when is_binary(raw) ->
        Map.put(
          params,
          key,
          raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        )

      _ ->
        params
    end
  end

  defp decode_grants(raw) do
    case String.trim(raw) do
      "" -> {:ok, %{}}
      trimmed -> decode_grants_json(trimmed)
    end
  end

  defp decode_grants_json(trimmed) do
    case Jason.decode(trimmed) do
      {:ok, %{} = grants} -> {:ok, grants}
      _ -> :error
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp tier_options, do: @tier_options

  defp custom_role_options(roles),
    do: [{gettext("No custom role"), ""}] ++ Enum.map(roles, &{&1.name, &1.id})

  defp types_value(form, field) do
    case form[field].value do
      list when is_list(list) -> Enum.join(list, ", ")
      raw when is_binary(raw) -> raw
      _ -> ""
    end
  end

  defp grants_value(form) do
    case form[:field_grants].value do
      map when is_map(map) and map_size(map) > 0 -> Jason.encode!(map, pretty: true)
      raw when is_binary(raw) -> raw
      _ -> ""
    end
  end

  defp scope_summary(membership) do
    [
      scope_part(gettext("edit"), membership.editable_types),
      scope_part(gettext("read"), membership.readable_types),
      grants_part(membership.field_grants)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp scope_part(_label, types) when types in [nil, []], do: nil
  defp scope_part(label, types), do: "#{label}: #{Enum.join(types, ", ")}"

  defp grants_part(grants) when is_map(grants) and map_size(grants) > 0,
    do: gettext("field grants: %{types}", types: grants |> Map.keys() |> Enum.join(", "))

  defp grants_part(_grants), do: nil

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:team}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Team")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Who can author what on this site: members, their capability tier, and granular scope — assigned directly or through a custom role."
            )}
          </p>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Members")} ({length(@members)})</h2>

          <form phx-submit="add_member" class="card card-pad space-y-4" id="add-member-form">
            <div class="grid gap-4 sm:grid-cols-3">
              <div>
                <label class="text-sm font-medium" for="member-email">{gettext("Email")}</label>
                <input
                  id="member-email"
                  name="member[email]"
                  type="email"
                  required
                  placeholder="colleague@example.com"
                  class="mt-1 w-full rounded border border-base-content/20 bg-base-100 p-2 text-sm"
                />
              </div>
              <div>
                <label class="text-sm font-medium" for="member-role">{gettext("Tier")}</label>
                <select
                  id="member-role"
                  name="member[role]"
                  class="mt-1 w-full rounded border border-base-content/20 bg-base-100 p-2 text-sm"
                >
                  <option :for={{label, value} <- tier_options()} value={value}>{label}</option>
                </select>
              </div>
              <div>
                <label class="text-sm font-medium" for="member-role-id">
                  {gettext("Custom role")}
                </label>
                <select
                  id="member-role-id"
                  name="member[role_id]"
                  class="mt-1 w-full rounded border border-base-content/20 bg-base-100 p-2 text-sm"
                >
                  <option :for={{label, value} <- custom_role_options(@roles)} value={value}>
                    {label}
                  </option>
                </select>
              </div>
            </div>
            <p class="text-xs text-base-content/60">
              {gettext("The account must already exist — invite people via sign-up or SSO first.")}
            </p>
            <.button type="submit" variant="primary">{gettext("Add member")}</.button>
          </form>

          <p :if={@members == []} class="text-sm text-base-content/60">
            {gettext("No members on this site yet.")}
          </p>

          <ul :if={@members != []} class="card divide-y divide-base-content/10 overflow-hidden">
            <li :for={membership <- @members} id={"member-#{membership.id}"} class="p-4">
              <div
                :if={@member_edit == nil || @member_edit.id != membership.id}
                class="flex items-start justify-between gap-4"
              >
                <div class="min-w-0 space-y-1">
                  <span class="font-medium">{membership.user.email}</span>
                  <p class="text-sm text-base-content/70">
                    <span class="badge badge-sm">{membership.role}</span>
                    <span :if={membership.custom_role} class="badge badge-sm badge-outline ml-1">
                      {membership.custom_role.name}
                    </span>
                  </p>
                  <p :if={scope_summary(membership) != ""} class="text-xs text-base-content/60">
                    {scope_summary(membership)}
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="edit_member"
                    phx-value-id={membership.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Edit")}
                  </button>
                  <button
                    type="button"
                    phx-click="remove_member"
                    phx-value-id={membership.id}
                    data-confirm={gettext("Remove this member from the site?")}
                    aria-label={gettext("Remove member")}
                    class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </div>

              <.form
                :if={@member_edit != nil && @member_edit.id == membership.id}
                for={@member_edit.form}
                id={"edit-member-#{membership.id}"}
                phx-submit="save_member"
                class="space-y-4"
              >
                <p class="text-sm font-medium">{membership.user.email}</p>
                <div class="grid gap-4 sm:grid-cols-2">
                  <.input
                    field={@member_edit.form[:role]}
                    type="select"
                    label={gettext("Tier")}
                    options={tier_options()}
                  />
                  <.input
                    field={@member_edit.form[:role_id]}
                    type="select"
                    label={gettext("Custom role")}
                    options={custom_role_options(@roles)}
                  />
                </div>
                <.scope_fields form={@member_edit.form} prefix="member" />
                <div class="flex gap-2">
                  <.button type="submit" variant="primary">{gettext("Save")}</.button>
                  <button type="button" phx-click="cancel_member_edit" class="btn btn-sm btn-default">
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            </li>
          </ul>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Custom roles")} ({length(@roles)})</h2>
          <p class="text-sm text-base-content/70">
            {gettext(
              "A custom role bundles granular scope — define \"Blog editor\" once, assign it to any member. A member's own scope overrides their role per axis."
            )}
          </p>

          <.form
            for={@role_form}
            id="new-role-form"
            phx-submit="create_role"
            class="card card-pad space-y-4"
          >
            <div class="grid gap-4 sm:grid-cols-2">
              <.input field={@role_form[:name]} label={gettext("Name")} placeholder="Blog editor" />
              <.input
                field={@role_form[:description]}
                label={gettext("Description")}
                placeholder={gettext("Optional")}
              />
            </div>
            <.scope_fields form={@role_form} prefix="role" />
            <.button type="submit" variant="primary">{gettext("Add role")}</.button>
          </.form>

          <p :if={@roles == []} class="text-sm text-base-content/60">
            {gettext("No custom roles yet — members use their tier and direct scope only.")}
          </p>

          <ul :if={@roles != []} class="card divide-y divide-base-content/10 overflow-hidden">
            <li :for={role <- @roles} id={"role-#{role.id}"} class="p-4">
              <div
                :if={@role_edit == nil || @role_edit.id != role.id}
                class="flex items-start justify-between gap-4"
              >
                <div class="min-w-0 space-y-1">
                  <span class="font-medium">{role.name}</span>
                  <p :if={role.description} class="text-sm text-base-content/70">
                    {role.description}
                  </p>
                  <p :if={scope_summary(role) != ""} class="text-xs text-base-content/60">
                    {scope_summary(role)}
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="edit_role"
                    phx-value-id={role.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Edit")}
                  </button>
                  <button
                    type="button"
                    phx-click="delete_role"
                    phx-value-id={role.id}
                    data-confirm={
                      gettext("Delete this role? Members keep their tier and direct scope.")
                    }
                    aria-label={gettext("Delete role")}
                    class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </div>

              <.form
                :if={@role_edit != nil && @role_edit.id == role.id}
                for={@role_edit.form}
                id={"edit-role-#{role.id}"}
                phx-submit="save_role"
                class="space-y-4"
              >
                <div class="grid gap-4 sm:grid-cols-2">
                  <.input field={@role_edit.form[:name]} label={gettext("Name")} />
                  <.input field={@role_edit.form[:description]} label={gettext("Description")} />
                </div>
                <.scope_fields form={@role_edit.form} prefix="role" />
                <div class="flex gap-2">
                  <.button type="submit" variant="primary">{gettext("Save")}</.button>
                  <button type="button" phx-click="cancel_role_edit" class="btn btn-sm btn-default">
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end

  attr :form, :any, required: true
  attr :prefix, :string, required: true

  defp scope_fields(assigns) do
    assigns =
      assigns
      |> assign(:editable_text, types_value(assigns.form, :editable_types))
      |> assign(:readable_text, types_value(assigns.form, :readable_types))
      |> assign(:grants_json, grants_value(assigns.form))

    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <div>
        <label class="text-sm font-medium" for={@form[:editable_types].id}>
          {gettext("Editable types")}
        </label>
        <input
          id={@form[:editable_types].id}
          name={"#{@prefix}[editable_types]"}
          type="text"
          value={@editable_text}
          placeholder={gettext("post, page — empty = all")}
          class="mt-1 w-full rounded border border-base-content/20 bg-base-100 p-2 text-sm"
        />
      </div>
      <div>
        <label class="text-sm font-medium" for={@form[:readable_types].id}>
          {gettext("Readable types (editorial)")}
        </label>
        <input
          id={@form[:readable_types].id}
          name={"#{@prefix}[readable_types]"}
          type="text"
          value={@readable_text}
          placeholder={gettext("post — empty = all")}
          class="mt-1 w-full rounded border border-base-content/20 bg-base-100 p-2 text-sm"
        />
      </div>
    </div>
    <div>
      <label class="text-sm font-medium" for={@form[:field_grants].id}>
        {gettext("Field grants (JSON)")}
      </label>
      <textarea
        id={@form[:field_grants].id}
        name={"#{@prefix}[field_grants]"}
        rows="3"
        class="mt-1 w-full rounded border border-base-content/20 bg-base-100 p-2 font-mono text-xs"
        placeholder={~s({"post": ["title", "blocks"]})}
      >{@grants_json}</textarea>
      <p class="mt-1 text-xs text-base-content/60">
        {gettext("Content type → attributes a member may change. Empty = no field restriction.")}
      </p>
    </div>
    """
  end
end
