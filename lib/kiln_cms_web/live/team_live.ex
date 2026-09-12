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

  A member's tier can also be granted **temporarily** — "editor on this site until
  Friday" — which leaves the standing tier alone and expires on its own; see
  `KilnCMS.Accounts.RoleGrant`. That is why the membership list is read with
  `RoleGrant.unfolded/0`: this page shows the standing tier beside a live grant,
  and writes the standing tier, which Ash would silently drop against a folded
  record.

  The instance-wide account register — who has signed up at all, their platform
  role, password resets, account removal — is `KilnCMSWeb.AccountsLive`.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Role
  alias KilnCMS.Accounts.RoleGrant

  @tier_options [{"Viewer", :viewer}, {"Editor", :editor}, {"Admin", :admin}]

  # Offered lengths for a temporary tier, in hours — the same set
  # `KilnCMSWeb.AccountsLive` offers for the platform role.
  @grant_durations [
    {"6 hours", 6},
    {"24 hours", 24},
    {"3 days", 72},
    {"7 days", 168},
    {"30 days", 720}
  ]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Team"))
       |> assign(:member_edit, nil)
       |> assign(:role_edit, nil)
       |> assign(:role_form, role_form(actor))
       |> assign(
         :editors_can_publish,
         KilnCMS.CMS.EditorialSettings.editors_can_publish?(socket.assigns.current_org)
       )
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
  def handle_event("add_member", %{"member" => %{"email" => email} = params}, socket)
      when is_binary(email) do
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

  # Who can publish on this site (`SiteEditorialSettings.editors_can_publish`).
  # Here because it is a statement about what a tier may do, beside the tiers
  # themselves. The write is the settings resource's OrgAdmin policy; this page
  # only offers it.
  def handle_event("set_editors_can_publish", %{"enabled" => enabled}, socket)
      when enabled in ["true", "false"] do
    %{current_user: actor, current_org: org} = socket.assigns

    case KilnCMS.CMS.EditorialSettings.save(%{editors_can_publish: enabled == "true"},
           actor: actor,
           tenant: org
         ) do
      {:ok, settings} ->
        message =
          if settings.editors_can_publish,
            do: gettext("Editors can now publish their own work."),
            else: gettext("Editors now submit for review; an admin publishes.")

        {:noreply,
         socket
         |> assign(:editors_can_publish, settings.editors_can_publish)
         |> put_flash(:info, message)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  # A pushed payload is client-chosen; give the guard above somewhere to fall.
  def handle_event("set_editors_can_publish", _params, socket), do: {:noreply, socket}

  def handle_event("remove_member", %{"id" => id}, socket) when is_binary(id) do
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

  def handle_event("edit_member", %{"id" => id}, socket) when is_binary(id) do
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

  def handle_event("save_member", %{"member" => params}, socket) when is_map(params) do
    handle_submit(
      socket,
      socket.assigns.member_edit.form,
      params,
      &assign(&1, :member_edit, %{&1.assigns.member_edit | form: &2}),
      &(&1 |> assign(:member_edit, nil) |> load_data() |> put_flash(:info, gettext("Saved.")))
    )
  end

  # Time-boxed per-site tiers (`KilnCMS.Accounts.RoleGrant`). Its own event rather
  # than two more fields on the member form, because it writes a different action:
  # `:grant_temporary_role` leaves the standing tier — the thing the form edits —
  # alone, which is what lets the elevation expire without anything running.
  def handle_event(
        "grant_member_role",
        %{"membership_id" => id, "role" => role, "hours" => hours} = params,
        socket
      )
      when is_binary(id) and is_binary(role) and is_binary(hours) do
    %{actor: actor} = socket.assigns

    with {:ok, membership} <- get_membership(socket, id),
         expires_at = grant_expiry(params),
         {:ok, _} <-
           Accounts.grant_membership_temporary_role(
             membership,
             %{granted_role: role, granted_role_expires_at: expires_at},
             actor: actor
           ) do
      {:noreply,
       socket
       |> assign(:member_edit, nil)
       |> load_data()
       |> put_flash(
         :info,
         gettext("%{role} on this site until %{when}.",
           role: role,
           when: Calendar.strftime(expires_at, "%Y-%m-%d %H:%M UTC")
         )
       )}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, ash_error_message(error))}
      _ -> {:noreply, socket}
    end
  end

  # A pushed payload is client-chosen; give the guarded head above somewhere to
  # fall (#764).
  def handle_event("grant_member_role", _params, socket), do: {:noreply, socket}

  def handle_event("revoke_member_role", %{"id" => id}, socket) when is_binary(id) do
    %{actor: actor} = socket.assigns

    socket =
      with {:ok, membership} <- get_membership(socket, id),
           {:ok, _} <-
             Accounts.grant_membership_temporary_role(
               membership,
               %{granted_role: nil, granted_role_expires_at: nil},
               actor: actor
             ) do
        socket |> load_data() |> put_flash(:info, gettext("Temporary tier ended."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't end that temporary tier."))
      end

    {:noreply, assign(socket, :member_edit, nil)}
  end

  # --- roles -----------------------------------------------------------------

  def handle_event("create_role", %{"role" => params}, socket) when is_map(params) do
    params = Map.put(params, "org_id", socket.assigns.current_org.id)

    handle_submit(
      socket,
      socket.assigns.role_form,
      params,
      &assign(&1, :role_form, &2),
      &(&1
        |> assign(:role_form, role_form(&1.assigns.actor))
        |> load_data()
        |> put_flash(:info, gettext("Role added.")))
    )
  end

  def handle_event("edit_role", %{"id" => id}, socket) when is_binary(id) do
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

  def handle_event("save_role", %{"role" => params}, socket) when is_map(params) do
    handle_submit(
      socket,
      socket.assigns.role_edit.form,
      params,
      &assign(&1, :role_edit, %{&1.assigns.role_edit | form: &2}),
      &(&1 |> assign(:role_edit, nil) |> load_data() |> put_flash(:info, gettext("Saved.")))
    )
  end

  def handle_event("delete_role", %{"id" => id}, socket) when is_binary(id) do
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
      Accounts.list_memberships_for_org!(
        org.id,
        RoleGrant.unfolded() ++
          [
            actor: actor,
            load: [:user, :custom_role],
            query: [sort: [inserted_at: :asc]]
          ]
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

  # One outcome handler for every scoped submit (member edit, role create,
  # role edit): `set_form` re-assigns the failed form, `on_ok` applies the
  # success transition. Keeps the invalid-JSON flash from drifting per event.
  defp handle_submit(socket, form, params, set_form, on_ok) do
    case submit_scoped(form, params) do
      {:ok, _} ->
        {:noreply, on_ok.(socket)}

      {:error, form} ->
        {:noreply, set_form.(socket, form)}

      {:invalid_json, form} ->
        {:noreply,
         socket
         |> set_form.(form)
         |> put_flash(:error, gettext("Field grants must be a JSON object."))}
    end
  end

  # Per-org tiers are LIVE (#419): the membership tier governs this site.
  defp tier_hint do
    gettext(
      "The site tier governs this member's capability on THIS site (platform admins always retain access); custom roles and scopes refine it."
    )
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

  # Only tiers ABOVE the membership's standing one can be granted
  # (`RoleGrant.elevation?/2`), so offering the rest would offer a refusal.
  defp grantable_tiers(membership) do
    Enum.filter(@tier_options, fn {_label, tier} ->
      RoleGrant.elevation?(tier, membership.role)
    end)
  end

  defp grant_durations, do: @grant_durations

  # An explicit "until" wins over the preset, same as the account console's — see
  # `KilnCMSWeb.AccountsLive`. A blank or unparseable value falls back to the
  # preset; the action validates that whatever lands is in the future.
  # Minute-precision `datetime-local` values are not valid ISO 8601, and a browser
  # may or may not include seconds — try as given, then padded (same as
  # `KilnCMSWeb.AccountsLive`).
  defp grant_expiry(%{"until" => until}) when is_binary(until) and until != "" do
    case NaiveDateTime.from_iso8601(until) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> padded_expiry(until)
    end
  end

  defp grant_expiry(%{"hours" => hours}),
    do: DateTime.add(DateTime.utc_now(), grant_hours(hours), :hour)

  defp padded_expiry(until) do
    case NaiveDateTime.from_iso8601(until <> ":00") do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  defp grant_hours(raw) do
    case Integer.parse(to_string(raw)) do
      {hours, ""} when hours > 0 -> hours
      # The shortest offered grant, not the longest: a mangled value must not
      # hand out a month of admin.
      _ -> @grant_durations |> List.first() |> elem(1)
    end
  end

  defp grant_summary(%{granted_role: role, granted_role_expires_at: at} = membership) do
    if RoleGrant.live?(membership) do
      gettext("%{role} until %{when}",
        role: role,
        when: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
      )
    end
  end

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
      current_org={@current_org}
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

        <section id="team-publishing" class="card card-pad space-y-3">
          <h2 class="text-lg font-medium">{gettext("Publishing")}</h2>
          <p class="text-sm text-base-content/70">
            {if @editors_can_publish,
              do:
                gettext(
                  "Editors publish their own work. Submitting for review stays available, and admins can always publish."
                ),
              else: gettext("Editors submit their work for review, and an admin publishes it.")}
          </p>
          <button
            id="team-toggle-publishing"
            type="button"
            phx-click="set_editors_can_publish"
            phx-value-enabled={to_string(not @editors_can_publish)}
            class="btn btn-sm btn-default"
          >
            {if @editors_can_publish,
              do: gettext("Require admin approval"),
              else: gettext("Let editors publish")}
          </button>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Members")} ({length(@members)})</h2>

          <form phx-submit="add_member" class="card card-pad space-y-4" id="add-member-form">
            <div class="grid gap-4 sm:grid-cols-3">
              <.input
                name="member[email]"
                value=""
                type="email"
                required
                label={gettext("Email")}
                placeholder="colleague@example.com"
              />
              <.input
                name="member[role]"
                value="viewer"
                type="select"
                label={gettext("Site tier")}
                options={tier_options()}
              />
              <.input
                name="member[role_id]"
                value=""
                type="select"
                label={gettext("Custom role")}
                options={custom_role_options(@roles)}
              />
            </div>
            <p class="text-xs text-base-content/60">
              {gettext("The account must already exist — invite people via sign-up or SSO first.")}
              {tier_hint()}
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
                    <.badge>{membership.role}</.badge>
                    <.badge :if={grant_summary(membership)} variant="warning" class="ml-1">
                      {grant_summary(membership)}
                    </.badge>
                    <.badge :if={membership.custom_role} variant="outline" class="ml-1">
                      {membership.custom_role.name}
                    </.badge>
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
                    label={gettext("Site tier")}
                    options={tier_options()}
                  />
                  <.input
                    field={@member_edit.form[:role_id]}
                    type="select"
                    label={gettext("Custom role")}
                    options={custom_role_options(@roles)}
                  />
                </div>
                <p class="text-xs text-base-content/60">{tier_hint()}</p>
                <.scope_fields form={@member_edit.form} prefix="member" />
                <div class="flex gap-2">
                  <.button type="submit" variant="primary">{gettext("Save")}</.button>
                  <button type="button" phx-click="cancel_member_edit" class="btn btn-sm btn-default">
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>

              <.temporary_tier
                :if={@member_edit != nil && @member_edit.id == membership.id}
                membership={membership}
              />
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

  attr :membership, :map, required: true

  # A separate form beside the member form, not fields inside it: this submits a
  # different action (`:grant_temporary_role`, which leaves the standing tier
  # alone) and must not be saved by the same button that rewrites it.
  defp temporary_tier(assigns) do
    ~H"""
    <div class="mt-4 border-t border-base-content/10 pt-4">
      <p class="text-sm font-medium">{gettext("Temporary tier")}</p>
      <p class="text-xs text-base-content/60">
        {gettext(
          "A higher tier on this site that expires on its own. The site tier above is untouched, so the elevation ends whether or not anything runs on time."
        )}
      </p>

      <div :if={grant_summary(@membership)} class="mt-3 flex items-center gap-3">
        <span class="text-sm">{grant_summary(@membership)}</span>
        <button
          type="button"
          phx-click="revoke_member_role"
          phx-value-id={@membership.id}
          class="btn btn-sm btn-default"
        >
          {gettext("End it now")}
        </button>
      </div>

      <p
        :if={is_nil(grant_summary(@membership)) and grantable_tiers(@membership) == []}
        class="mt-3 text-sm text-base-content/60"
      >
        {gettext("This member already holds the highest tier on this site.")}
      </p>

      <form
        :if={is_nil(grant_summary(@membership)) and grantable_tiers(@membership) != []}
        phx-submit="grant_member_role"
        id={"grant-member-#{@membership.id}"}
        class="mt-3 space-y-4"
      >
        <input type="hidden" name="membership_id" value={@membership.id} />
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            name="role"
            value=""
            type="select"
            label={gettext("Grant tier")}
            options={grantable_tiers(@membership)}
          />
          <.input
            name="hours"
            value="24"
            type="select"
            label={gettext("For")}
            options={grant_durations()}
          />
        </div>
        <.input name="until" value="" type="datetime-local" label={gettext("Or until (UTC)")} />
        <.button type="submit">{gettext("Grant")}</.button>
      </form>
    </div>
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
      <.input
        name={"#{@prefix}[editable_types]"}
        value={@editable_text}
        type="text"
        label={gettext("Editable types")}
        placeholder={gettext("post, page — empty = all")}
      />
      <.input
        name={"#{@prefix}[readable_types]"}
        value={@readable_text}
        type="text"
        label={gettext("Readable types (editorial)")}
        placeholder={gettext("post — empty = all")}
      />
    </div>
    <div>
      <.input
        name={"#{@prefix}[field_grants]"}
        value={@grants_json}
        type="textarea"
        label={gettext("Field grants (JSON)")}
        placeholder={~s({"post": ["title", "blocks"]})}
      />
      <p class="mt-1 text-xs text-base-content/60">
        {gettext("Content type → attributes a member may change. Empty = no field restriction.")}
      </p>
    </div>
    """
  end
end
