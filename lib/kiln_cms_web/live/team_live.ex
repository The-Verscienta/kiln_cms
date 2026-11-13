defmodule KilnCMSWeb.TeamLive do
  @moduledoc """
  Team management (`/editor/team`) — granular RBAC without AshAdmin (#332,
  slice 4). Admin-only, mirroring the `OrgMembership`/`Role` policies.

  Two panels for the *current* org (multi-site admins switch org by host, like
  every other console page):

    * **Members** — the org's memberships: capability tier, assigned custom
      role, and per-member overrides of the scope axes. "Add or invite" adds
      an address with a confirmed account and emails an invitation to any
      other (#2135, `KilnCMS.Accounts.Invitations.AddOrInvite`); **Pending
      invitations** lists this org's invitations to resend or revoke.
    * **Roles** — the org's custom roles: named bundles of `editable_types` /
      `readable_types` / `field_grants` / `field_read_grants` (see docs/granular-rbac.md).

  The scope axes are picked, not typed (#2141): `KilnCMSWeb.ScopePickers`
  renders them for the role forms and the member form alike, and
  `KilnCMSWeb.ScopeParams` turns what they post into the stored attributes —
  merged onto the stored value, so a form saved untouched writes back exactly
  what it held, including names this site no longer has a type for.

  A member's tier can also be granted **temporarily** — "editor on this site until
  Friday" — which leaves the standing tier alone and expires on its own; see
  `KilnCMS.Accounts.RoleGrant`. A membership's `role` is always that standing
  tier; this page shows a live grant beside it and never writes one into it.

  Each row leads with the tier that applies on this site **now** — resolved by
  `KilnCMS.Accounts.Scoping.tier_source/2`, the same answer the policies get, so a
  platform admin reads as admin whatever their membership holds — and explains a
  live grant under it (`KilnCMSWeb.RoleDisplay`, #2142).

  The instance-wide account register — who has signed up at all, their platform
  role, password resets, account removal — is `KilnCMSWeb.AccountsLive`.
  """
  use KilnCMSWeb, :live_view

  require Ash.Expr

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.Registrations
  alias KilnCMS.Accounts.Role
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMSWeb.RoleDisplay
  alias KilnCMSWeb.RoleGrantForm
  alias KilnCMSWeb.ScopeParams
  alias KilnCMSWeb.ScopePickers

  import KilnCMSWeb.RoleDisplay, only: [role_label: 1, role_summary: 1]

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
       |> assign(:role_scope, blank_scope())
       |> assign(
         :editors_can_publish,
         KilnCMS.CMS.EditorialSettings.editors_can_publish?(socket.assigns.current_org)
       )
       |> load_data()}
    else
      # Not redundant: the `:live_admin_required` hook admits any ADMIN of this
      # site, and this page needs a PLATFORM admin (#419), so it refuses the rest
      # itself, to the same access-denied page (#2143).
      {:ok,
       socket
       |> push_navigate(to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  # --- members ---------------------------------------------------------------

  # "Add or invite" (#2135): an address with a confirmed account is added now;
  # any other is emailed an invitation. `Invitation.:add_or_invite` runs every
  # read and write as the actor, so the policies decide.
  @impl true
  def handle_event("add_member", %{"member" => %{"email" => email} = params}, socket)
      when is_binary(email) do
    %{actor: actor, current_org: org} = socket.assigns

    result =
      Accounts.add_or_invite_member(
        %{
          organization_id: org.id,
          email: String.trim(email),
          role: text(params["role"]) || "viewer",
          role_id: presence(text(params["role_id"]))
        },
        actor: actor,
        context: socket.assigns.security_context
      )

    case result do
      {:ok, %{outcome: :added}} ->
        {:noreply,
         socket |> load_data() |> put_flash(:info, gettext("Member added to this site."))}

      {:ok, %{outcome: :approved}} ->
        {:noreply,
         socket
         |> load_data()
         |> put_flash(
           :info,
           gettext("Their registration on this site is approved, and they are now a member.")
         )}

      {:ok, %{outcome: :approved_over_rejection}} ->
        {:noreply,
         socket
         |> load_data()
         |> put_flash(
           :info,
           gettext(
             "Their registration on this site had been rejected; it's now approved, and they are a member."
           )
         )}

      {:ok, %{outcome: outcome}} when outcome in [:invited, :reinvited] ->
        {:noreply,
         socket
         |> load_data()
         |> put_flash(:info, gettext("Invitation sent to %{email}.", email: String.trim(email)))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, add_error_message(error))}
    end
  end

  # A pushed payload is client-chosen; give the guarded head above somewhere to
  # fall (#764).
  def handle_event("add_member", _params, socket), do: {:noreply, socket}

  # Pending invitations (#2135). Looked up in the loaded `@invitations` — this
  # org's rows only — so a crafted id from another site matches nothing.
  def handle_event("resend_invitation", %{"id" => id}, socket) when is_binary(id) do
    %{actor: actor} = socket.assigns

    socket =
      with {:ok, invitation} <- get_invitation(socket, id),
           {:ok, _resent} <-
             Accounts.resend_invitation(invitation, %{},
               actor: actor,
               context: socket.assigns.security_context
             ) do
        socket
        |> load_data()
        |> put_flash(
          :info,
          gettext("Invitation sent again to %{email}.", email: invitation.email)
        )
      else
        {:error, :not_found} -> socket
        {:error, error} -> put_flash(socket, :error, add_error_message(error))
      end

    {:noreply, socket}
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) when is_binary(id) do
    %{actor: actor} = socket.assigns

    socket =
      with {:ok, invitation} <- get_invitation(socket, id),
           :ok <-
             Accounts.revoke_invitation(invitation,
               actor: actor,
               context: socket.assigns.security_context
             ) do
        socket |> load_data() |> put_flash(:info, gettext("Invitation revoked."))
      else
        {:error, :not_found} -> socket
        _error -> put_flash(socket, :error, gettext("Couldn't revoke that invitation."))
      end

    {:noreply, socket}
  end

  def handle_event(event, _params, socket)
      when event in ["resend_invitation", "revoke_invitation"],
      do: {:noreply, socket}

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
           :ok <-
             Accounts.remove_org_membership(membership,
               actor: actor,
               context: socket.assigns.security_context
             ) do
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
          |> AshPhoenix.Form.for_update(:update,
            actor: socket.assigns.actor,
            context: socket.assigns.security_context,
            as: "member"
          )
          |> to_form()

        {:noreply,
         assign(socket, :member_edit, %{
           id: id,
           form: form,
           stored: ScopeParams.stored(membership),
           scope: blank_scope(),
           inherited: %{role: membership.custom_role, user: membership.user}
         })}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_member_edit", _params, socket),
    do: {:noreply, assign(socket, :member_edit, nil)}

  def handle_event("validate_member", %{"member" => params}, socket)
      when is_map(params) and is_map(socket.assigns.member_edit) do
    if admin?(socket) do
      edit = socket.assigns.member_edit
      {form, scope} = validate_scoped(edit, member_params(params))

      # "Currently inherited" follows the custom role picked in this form, not
      # the one stored: switching the role changes what the axes fall back to.
      inherited =
        if Map.has_key?(params, "role_id"),
          do: %{edit.inherited | role: picked_role(socket, params["role_id"])},
          else: edit.inherited

      {:noreply,
       assign(socket, :member_edit, %{edit | form: form, scope: scope, inherited: inherited})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_member", %{"member" => params}, socket)
      when is_map(params) and is_map(socket.assigns.member_edit) do
    edit = socket.assigns.member_edit

    case submit_scoped(edit, member_params(params)) do
      {:ok, _membership} ->
        {:noreply,
         socket |> assign(:member_edit, nil) |> load_data() |> put_flash(:info, gettext("Saved."))}

      {:error, form, scope} ->
        {:noreply, assign(socket, :member_edit, %{edit | form: form, scope: scope})}
    end
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
         expires_at = RoleGrantForm.expiry(params),
         {:ok, _} <-
           Accounts.grant_membership_temporary_role(
             membership,
             %{granted_role: role, granted_role_expires_at: expires_at},
             actor: actor,
             context: socket.assigns.security_context
           ) do
      {:noreply,
       socket
       |> assign(:member_edit, nil)
       |> load_data()
       |> put_flash(
         :info,
         gettext("%{role} on this site until %{when}.",
           role: role_label(role),
           when: RoleGrantForm.format(expires_at)
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
               actor: actor,
               context: socket.assigns.security_context
             ) do
        socket |> load_data() |> put_flash(:info, gettext("Temporary tier ended."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't end that temporary tier."))
      end

    {:noreply, assign(socket, :member_edit, nil)}
  end

  # --- roles -----------------------------------------------------------------

  def handle_event("validate_role", %{"role" => params}, socket) when is_map(params) do
    if admin?(socket) do
      new = new_role(socket)

      {form, scope} =
        validate_scoped(new, Map.put(params, "org_id", socket.assigns.current_org.id))

      {:noreply, socket |> assign(:role_form, form) |> assign(:role_scope, scope)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_role", %{"role" => params}, socket) when is_map(params) do
    params = Map.put(params, "org_id", socket.assigns.current_org.id)

    case submit_scoped(new_role(socket), params) do
      {:ok, _role} ->
        {:noreply,
         socket
         |> assign(:role_form, role_form(socket.assigns.actor))
         |> assign(:role_scope, blank_scope())
         |> load_data()
         |> put_flash(:info, gettext("Role added."))}

      {:error, form, scope} ->
        {:noreply, socket |> assign(:role_form, form) |> assign(:role_scope, scope)}
    end
  end

  def handle_event("edit_role", %{"id" => id}, socket) when is_binary(id) do
    case Accounts.get_role(id, actor: socket.assigns.actor) do
      {:ok, role} ->
        form =
          role
          # Its own html id: the create form beside it is also `as: "role"`,
          # and two `role_name` inputs on one page break DOM patching.
          |> AshPhoenix.Form.for_update(:update,
            actor: socket.assigns.actor,
            as: "role",
            id: "edit-role-#{id}"
          )
          |> to_form()

        {:noreply,
         assign(socket, :role_edit, %{
           id: id,
           form: form,
           role: role,
           stored: ScopeParams.stored(role),
           scope: blank_scope()
         })}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_role_edit", _params, socket),
    do: {:noreply, assign(socket, :role_edit, nil)}

  def handle_event("validate_role_edit", %{"role" => params}, socket)
      when is_map(params) and is_map(socket.assigns.role_edit) do
    if admin?(socket) do
      edit = socket.assigns.role_edit
      {form, scope} = validate_scoped(edit, params)
      {:noreply, assign(socket, :role_edit, %{edit | form: form, scope: scope})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_role", %{"role" => params}, socket)
      when is_map(params) and is_map(socket.assigns.role_edit) do
    edit = socket.assigns.role_edit

    # Every role update evicts the live sessions of everyone holding the role
    # (`EvictRoleMembers`), so a save that changes nothing is not sent at all.
    case submit_scoped(edit, params, &unchanged_role?(edit.role, &1)) do
      :unchanged ->
        {:noreply, socket |> assign(:role_edit, nil) |> put_flash(:info, gettext("No changes."))}

      {:ok, _role} ->
        {:noreply,
         socket |> assign(:role_edit, nil) |> load_data() |> put_flash(:info, gettext("Saved."))}

      {:error, form, scope} ->
        {:noreply, assign(socket, :role_edit, %{edit | form: form, scope: scope})}
    end
  end

  # A change or save for an edit form that has since closed (or a payload in
  # another shape) has nothing to apply to.
  def handle_event(event, _params, socket)
      when event in ~w(validate_member save_member create_role validate_role validate_role_edit save_role),
      do: {:noreply, socket}

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
        actor: actor,
        load: [:user, :custom_role],
        query: [sort: [inserted_at: :asc]]
      )

    roles =
      Accounts.list_roles_for_org!(org.id, actor: actor, query: [sort: [name: :asc]])

    invitations =
      Accounts.list_invitations_for_org!(org.id, actor: actor, load: [:custom_role, :invited_by])

    site_admins = site_admins_without_membership(actor, org.id)

    socket
    |> assign(:catalog, ScopePickers.catalog(org, actor))
    |> assign(:members, members)
    |> assign(:site_admins, site_admins)
    # Each person's tier on this site through the decision the policies make,
    # keyed by user — fed the rows just read rather than the policy checks'
    # memo, so the row shows what a save or a revoke left.
    |> assign(:access, access(members, site_admins, org))
    |> assign(:roles, roles)
    |> assign(:invitations, invitations)
    |> assign(:pending_registrations, Registrations.pending_count(org, actor: actor))
  end

  # Platform admins — `User.role == :admin`, or a live admin grant — reach every
  # site with no OrgMembership row at all: the account `/setup` creates is one.
  # Listing memberships alone left them off this page, so a fresh install showed
  # "Members (0)" to the admin looking at it. They are the same people
  # `Scoping.users_with_tier/2` counts as admins, through the same expression;
  # an admin who also holds a membership here is already on the list and is
  # left out of this one. Read as the actor, like the membership list.
  defp site_admins_without_membership(actor, org_id) do
    admin = RoleGrant.expression([:admin])

    Accounts.list_users!(
      actor: actor,
      query: [
        filter: Ash.Expr.expr(^admin and not exists(org_memberships, organization_id == ^org_id)),
        sort: [email: :asc]
      ]
    )
  end

  defp access(members, site_admins, org) do
    Map.new(
      Enum.map(members, &{&1.user.id, RoleDisplay.site_access_for_membership(&1.user, org, &1)}) ++
        Enum.map(site_admins, &{&1.id, RoleDisplay.site_access_for_membership(&1, org, nil)})
    )
  end

  defp site_admin?(user), do: RoleGrant.effective_role(user) == :admin

  defp get_membership(socket, id) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  end

  defp get_invitation(socket, id) do
    case Enum.find(socket.assigns.invitations, &(&1.id == id)) do
      nil -> {:error, :not_found}
      invitation -> {:ok, invitation}
    end
  end

  # What the admin is told when an address could not be added or invited.
  defp add_error_message(error) do
    case InvitationRefused.reason(error) do
      :already_member ->
        gettext("That person is already on this site.")

      :already_invited ->
        gettext("That address is already invited — resend it from Pending invitations.")

      :suppressed ->
        gettext(
          "That address is on the mail suppression list, so the invitation would not arrive. Clear it under Mail first."
        )

      :mail_budget ->
        gettext(
          "That address has been sent too many invitations in the last hour. Try again later."
        )

      _other ->
        ash_error_message(error,
          fallback: gettext("Couldn't add or invite that address.")
        )
    end
  end

  defp invitation_status(invitation) do
    if Invitations.live?(invitation),
      do: gettext("Expires %{when}", when: RoleGrantForm.format(invitation.expires_at)),
      else: gettext("Expired")
  end

  defp inviter(%{invited_by: %{} = user}), do: user.name || to_string(user.email)
  defp inviter(_invitation), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp role_form(actor) do
    Role
    |> AshPhoenix.Form.for_create(:create, actor: actor, as: "role")
    |> to_form()
  end

  defp blank_scope, do: %{picks: nil, errors: %{}}

  defp admin?(socket), do: KilnCMSWeb.LiveUserAuth.platform_admin?(socket)

  # The create form, in the shape `validate_scoped/2`/`submit_scoped/3` take
  # from an edit: its stored scope is the attribute defaults.
  defp new_role(socket),
    do: %{
      form: socket.assigns.role_form,
      stored: ScopeParams.blank(),
      scope: socket.assigns.role_scope
    }

  defp picked_role(socket, role_id) when is_binary(role_id) and role_id != "",
    do: Enum.find(socket.assigns.roles, &(&1.id == role_id))

  defp picked_role(_socket, _blank), do: nil

  defp member_params(params), do: Map.replace(params, "role_id", presence(params["role_id"]))

  # Per-org tiers are LIVE (#419): the membership tier governs this site.
  defp tier_hint do
    gettext(
      "The site tier governs this member's capability on THIS site (platform admins always retain access); custom roles and scopes refine it."
    )
  end

  # The scope pickers post modes; `ScopeParams` merges them onto the stored
  # value. A picker refusal ("Only these…" with nothing ticked) is shown once a
  # submit has hit it, and then follows the admin's edits until it is fixed.
  defp validate_scoped(%{form: form, stored: stored, scope: scope}, params) do
    {form_params, errors} =
      case ScopeParams.normalize(params, stored) do
        {:ok, normalized} -> {normalized, %{}}
        {:error, errors} -> {ScopeParams.strip(params), errors}
      end

    errors = if scope.errors == %{}, do: %{}, else: errors

    {AshPhoenix.Form.validate(form, form_params),
     %{picks: ScopeParams.picks(params), errors: errors}}
  end

  # A refused picker never reaches the action: the form keeps the stored scope
  # and the picks as posted. `unchanged?` sees the normalized params and can
  # stop a submit that would write nothing.
  defp submit_scoped(
         %{form: form, stored: stored},
         params,
         unchanged? \\ fn _normalized -> false end
       ) do
    picks = ScopeParams.picks(params)

    case ScopeParams.normalize(params, stored) do
      {:ok, normalized} ->
        if unchanged?.(normalized),
          do: :unchanged,
          else: submit_normalized(form, normalized, picks)

      {:error, errors} ->
        {:error, AshPhoenix.Form.validate(form, ScopeParams.strip(params)),
         %{picks: picks, errors: errors}}
    end
  end

  defp submit_normalized(form, normalized, picks) do
    case AshPhoenix.Form.submit(form, params: normalized) do
      {:ok, result} -> {:ok, result}
      {:error, form} -> {:error, form, %{picks: picks, errors: %{}}}
    end
  end

  defp unchanged_role?(role, params) do
    same_text?(Map.get(params, "name", role.name), role.name) and
      same_text?(Map.get(params, "description", role.description || ""), role.description) and
      params["editable_types"] == role.editable_types and
      params["readable_types"] == role.readable_types and
      params["field_grants"] == role.field_grants and
      params["field_read_grants"] == (role.field_read_grants || %{})
  end

  # As the `:string` attribute casts it: trimmed, and blank is nil.
  defp same_text?(param, stored) when is_binary(param), do: presence(String.trim(param)) == stored
  defp same_text?(_param, _stored), do: false

  defp presence(""), do: nil
  defp presence(value), do: value

  defp tier_options, do: RoleDisplay.role_options()

  # Only tiers ABOVE the membership's standing one can be granted
  # (`RoleGrant.elevation?/2`), so offering the rest would offer a refusal.
  defp grantable_tiers(membership) do
    Enum.filter(tier_options(), fn {_label, tier} ->
      RoleGrant.elevation?(tier, membership.role)
    end)
  end

  defp grant_summary(%{granted_role: role, granted_role_expires_at: at} = membership) do
    if RoleGrant.live?(membership) do
      gettext("%{role} until %{when}",
        role: role_label(role),
        when: RoleGrantForm.format(at)
      )
    end
  end

  defp custom_role_options(roles),
    do: [{gettext("No custom role"), ""}] ++ Enum.map(roles, &{&1.name, &1.id})

  defp scope_summary(record, catalog) do
    [
      scope_part(gettext("edit"), record.editable_types),
      scope_part(gettext("read"), record.readable_types),
      ScopePickers.grants_summary(record.field_grants, catalog),
      ScopePickers.read_grants_summary(record.field_read_grants, catalog)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp scope_part(_label, types) when types in [nil, []], do: nil
  defp scope_part(label, types), do: "#{label}: #{Enum.join(types, ", ")}"

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
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:team}
          />
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
          <h2 class="text-lg font-medium">
            {gettext("Members")} ({length(@members) + length(@site_admins)})
          </h2>

          <%!-- Registrations awaiting approval (#2251) are not members, so the
                list below leaves them out; this says where they are. --%>
          <p :if={@pending_registrations > 0} id="team-pending-registrations" class="text-sm">
            <.link navigate={~p"/editor/registrations"} class="link">
              <%!-- A bounded count (`Registrations.count_cap/0`): at the cap
                    it says "or more" rather than a number it did not read. --%>
              {if @pending_registrations >= Registrations.count_cap(),
                do:
                  gettext("%{count} or more registrations are waiting for approval",
                    count: @pending_registrations
                  ),
                else:
                  ngettext(
                    "1 registration is waiting for approval",
                    "%{count} registrations are waiting for approval",
                    @pending_registrations
                  )}
            </.link>
          </p>

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
            <p class="text-xs text-base-content/70">
              {gettext(
                "No account yet, or not confirmed? They'll get an email invitation. A confirmed account is added straight away."
              )}
              {tier_hint()}
              <a
                id="add-member-docs"
                href={docs_url("account-administration.md#invite-someone-to-a-site")}
                target="_blank"
                rel="noopener"
                class="link inline-flex items-center gap-1 font-medium text-primary-ink"
              >
                {gettext("Learn more")}
                <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
                <span class="sr-only">{gettext("(opens in a new tab)")}</span>
              </a>
            </p>
            <.button type="submit" variant="primary">{gettext("Add or invite")}</.button>
          </form>

          <section
            :if={@invitations != []}
            id="team-invitations"
            class="space-y-2"
            aria-labelledby="team-invitations-heading"
          >
            <h3 id="team-invitations-heading" class="text-sm font-medium">
              {gettext("Pending invitations")} ({length(@invitations)})
            </h3>
            <%!-- The numbers are `Invitations.ttl_days/0` and
                  `prune_after_days/0`. Inviting an address whose invitation
                  expired resends it (`AddOrInvite`, `:reinvited`). --%>
            <p id="team-invitations-help" class="text-xs text-base-content/70">
              {gettext(
                "Links work for %{days} days. Resending mails a new link and restarts the clock; the old link stops working. Expired invitations stay listed for %{keep} days, and inviting the address again resends it.",
                days: Invitations.ttl_days(),
                keep: Invitations.prune_after_days()
              )}
            </p>
            <ul class="card divide-y divide-base-content/10 overflow-hidden">
              <li
                :for={invitation <- @invitations}
                id={"invitation-#{invitation.id}"}
                class="flex items-start justify-between gap-4 p-4"
              >
                <div class="min-w-0 space-y-1">
                  <span class="font-medium">{invitation.email}</span>
                  <p class="flex flex-wrap items-center gap-1 text-xs text-base-content/70">
                    <.badge variant="outline">{role_label(invitation.role)}</.badge>
                    <span :if={invitation.custom_role}>{gettext("Custom role:")}</span>
                    <.badge :if={invitation.custom_role} variant="outline">
                      {invitation.custom_role.name}
                    </.badge>
                  </p>
                  <p class="text-xs text-base-content/70">
                    <span :if={inviter(invitation)}>
                      {gettext("Invited by %{name}.", name: inviter(invitation))}
                    </span>
                    <span class={!Invitations.live?(invitation) && "text-warning"}>
                      {invitation_status(invitation)}
                    </span>
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="resend_invitation"
                    phx-value-id={invitation.id}
                    aria-label={gettext("Resend the invitation to %{email}", email: invitation.email)}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Resend")}
                  </button>
                  <button
                    type="button"
                    phx-click="revoke_invitation"
                    phx-value-id={invitation.id}
                    data-confirm={gettext("Revoke this invitation? Its link will stop working.")}
                    aria-label={gettext("Revoke the invitation to %{email}", email: invitation.email)}
                    class="btn btn-sm btn-ghost text-base-content/70 hover:text-error"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              </li>
            </ul>
          </section>

          <.empty_state
            :if={@members == [] and @site_admins == []}
            id="team-members-empty"
            icon="hero-user-group"
            title={gettext("No members on this site yet.")}
            compact
          >
            {gettext("Add someone with the form above to give them a role here.")}
          </.empty_state>

          <ul
            :if={@members != [] or @site_admins != []}
            class="card divide-y divide-base-content/10 overflow-hidden"
          >
            <%!-- Admin through their account role, not a membership: there is
                  no site tier, custom role or scope to edit and nothing to
                  remove here, so the row offers none — the role is changed
                  where it is held, on the account. --%>
            <li :for={user <- @site_admins} id={"site-admin-#{user.id}"} class="p-4">
              <div class="min-w-0 space-y-1">
                <span class="font-medium">{user.email}</span>
                <.role_summary
                  id={"site-admin-#{user.id}-role"}
                  label={gettext("On this site:")}
                  access={@access[user.id]}
                />
                <p class="text-sm text-base-content/70">
                  <.badge variant="info">{gettext("Site admin")}</.badge>
                </p>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "Admin on every site through their account role, so there is no site tier to set here."
                  )}
                  <.link
                    navigate={~p"/editor/accounts/#{user.id}"}
                    aria-label={gettext("Manage account %{email}", email: user.email)}
                    class="link"
                  >
                    {gettext("Manage account")}
                  </.link>
                </p>
              </div>
            </li>
            <li :for={membership <- @members} id={"member-#{membership.id}"} class="p-4">
              <div
                :if={@member_edit == nil || @member_edit.id != membership.id}
                class="flex items-start justify-between gap-4"
              >
                <div class="min-w-0 space-y-1">
                  <span class="font-medium">{membership.user.email}</span>
                  <%!-- A membership never demotes a platform admin
                        (`Scoping.effective_tier/2`), so the row leads with
                        the tier that applies and names the one it overrides. --%>
                  <.role_summary
                    id={"member-#{membership.id}-role"}
                    label={gettext("On this site:")}
                    access={@access[membership.user.id]}
                  >
                    <:note :if={@access[membership.user.id].source == :platform}>
                      {gettext("Site tier %{tier}, overridden by the platform admin role.",
                        tier: role_label(RoleGrant.effective_role(membership))
                      )}
                    </:note>
                  </.role_summary>
                  <p
                    :if={site_admin?(membership.user) or membership.custom_role}
                    class="flex flex-wrap items-center gap-1 text-xs text-base-content/60"
                  >
                    <.badge :if={site_admin?(membership.user)} variant="info">
                      {gettext("Site admin")}
                    </.badge>
                    <span :if={membership.custom_role}>{gettext("Custom role:")}</span>
                    <.badge :if={membership.custom_role} variant="outline">
                      {membership.custom_role.name}
                    </.badge>
                  </p>
                  <p
                    :if={scope_summary(membership, @catalog) != ""}
                    class="text-xs text-base-content/60"
                  >
                    {scope_summary(membership, @catalog)}
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="edit_member"
                    phx-value-id={membership.id}
                    aria-label={gettext("Edit %{email}", email: membership.user.email)}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Edit")}
                  </button>
                  <button
                    type="button"
                    phx-click="remove_member"
                    phx-value-id={membership.id}
                    data-confirm={gettext("Remove this member from the site?")}
                    aria-label={gettext("Remove %{email}", email: membership.user.email)}
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
                phx-change="validate_member"
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
                <ScopePickers.scope_pickers
                  id={"edit-member-#{membership.id}"}
                  form={@member_edit.form}
                  level={:member}
                  stored={@member_edit.stored}
                  picks={@member_edit.scope.picks}
                  errors={@member_edit.scope.errors}
                  catalog={@catalog}
                  inherited={@member_edit.inherited}
                />
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
            phx-change="validate_role"
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
            <ScopePickers.scope_pickers
              id="new-role"
              form={@role_form}
              level={:role}
              stored={ScopeParams.blank()}
              picks={@role_scope.picks}
              errors={@role_scope.errors}
              catalog={@catalog}
            />
            <.button type="submit" variant="primary">{gettext("Add role")}</.button>
          </.form>

          <.empty_state
            :if={@roles == []}
            id="team-roles-empty"
            icon="hero-identification"
            title={gettext("No custom roles yet")}
            compact
          >
            {gettext("Members use their tier and direct scope only.")}
          </.empty_state>

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
                  <p :if={scope_summary(role, @catalog) != ""} class="text-xs text-base-content/60">
                    {scope_summary(role, @catalog)}
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="edit_role"
                    phx-value-id={role.id}
                    aria-label={gettext("Edit role %{name}", name: role.name)}
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
                    aria-label={gettext("Delete role %{name}", name: role.name)}
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
                phx-change="validate_role_edit"
                phx-submit="save_role"
                class="space-y-4"
              >
                <div class="grid gap-4 sm:grid-cols-2">
                  <.input field={@role_edit.form[:name]} label={gettext("Name")} />
                  <.input field={@role_edit.form[:description]} label={gettext("Description")} />
                </div>
                <ScopePickers.scope_pickers
                  id={"edit-role-#{role.id}"}
                  form={@role_edit.form}
                  level={:role}
                  stored={@role_edit.stored}
                  picks={@role_edit.scope.picks}
                  errors={@role_edit.scope.errors}
                  catalog={@catalog}
                />
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
          data-confirm={gettext("End this temporary tier now?")}
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
            options={RoleGrantForm.durations()}
          />
        </div>
        <.input name="until" value="" type="datetime-local" label={gettext("Or until (UTC)")} />
        <.button type="submit">{gettext("Grant")}</.button>
      </form>
    </div>
    """
  end
end
