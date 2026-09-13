defmodule KilnCMSWeb.AccountsLive do
  @moduledoc """
  Registered accounts (`/editor/accounts`) — the instance-wide account register,
  and the operator levers for one account. Platform-admin only.

  ## Why this is not `/editor/team`

  `KilnCMSWeb.TeamLive` answers a question about *one site*: who may author what
  here, and through which custom role. It lists `OrgMembership` rows, and it can
  only add people who already have an account — "invite people via sign-up or
  SSO first", as it says.

  This page answers the question that was missing: who has signed up at all.
  It lists `KilnCMS.Accounts.User`, spans every site, and carries the levers that
  belong to the account rather than to a site — the platform role, a time-boxed
  elevation, a password-reset link, signing every session out, and removing the
  account along with a decision about what it wrote. The two are deliberately
  separate surfaces because they are separate objects; the account detail links
  out to each site's team page for the per-site tiers.

  ## Every read here suppresses the temporary-role fold

  `KilnCMS.Accounts.RoleGrant.unfolded/0` on every read: this page both *shows*
  the standing role beside a live grant (impossible if the grant has replaced it)
  and *writes* the standing role, which Ash would silently drop as a no-op
  against a folded record. `KilnCMS.Accounts.Validations.UnfoldedRecord` refuses
  the write rather than letting that pass, so forgetting shows up as an error
  here instead of a wrong column in the database. The actor is still
  `current_user` from the session — folded, like every other page's — so nothing
  on this page authorizes against an unfolded role.
  """
  use KilnCMSWeb, :live_view

  require Ash.Expr

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountRemoval
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.RoleGrantForm

  # One page of the register. The read action carries no `pagination`, so paging
  # is `limit`/`offset` with one extra row fetched to know whether "Next" exists
  # — the same trick `KilnCMSWeb.TrashLive` uses, and cheaper than teaching the
  # authentication resource's primary read to count.
  @per_page 25

  @role_options [{"Viewer", :viewer}, {"Editor", :editor}, {"Admin", :admin}]

  @statuses ~w(all unconfirmed temporary erased)

  # The events that act on the account being viewed. On the register
  # (`live_action: :index`) there is no account, and a client can push any event
  # name — so these get one early no-op clause instead of dereferencing `nil`.
  @account_events ~w(save_access grant_role revoke_grant send_password_reset
                     sign_out_everywhere confirm_removal cancel_removal remove_account)

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:actor, socket.assigns.current_user)
       |> assign(:page_title, gettext("Accounts"))
       |> assign(:removing, nil)}
    else
      # Defense-in-depth: `:live_admin_required` already bounced non-admins
      # before mount; mirror its flash so the two paths read the same.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:account, nil)
    # Every parameter goes through `KilnCMSWeb.Params` (#751): `?page[]=1` decodes
    # to a LIST, which `Integer.parse/1` has no clause for, and `?q[a]=1` to a map.
    # A malformed parameter reads as absent — the same page the omitted one gives.
    |> assign(:search, Params.string(params, "q", ""))
    |> assign(:role_filter, role_filter(Params.string(params, "role")))
    |> assign(:status, status(Params.string(params, "status")))
    |> assign(:page, Params.integer(params, "page", 1, 1..100_000))
    |> load_accounts()
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case fetch_account(socket, id) do
      {:ok, user} ->
        socket
        |> assign(:page_title, to_string(user.email))
        |> assign(:account, user)
        |> assign(:removing, nil)
        |> load_detail(user)

      :error ->
        socket
        |> put_flash(:error, gettext("That account couldn't be found."))
        |> push_navigate(to: ~p"/editor/accounts")
    end
  end

  # --- the register ----------------------------------------------------------

  @impl true
  def handle_event(event, _params, %{assigns: %{account: nil}} = socket)
      when event in @account_events,
      do: {:noreply, socket}

  def handle_event("filter", %{"q" => q} = params, socket) when is_binary(q) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/editor/accounts?#{%{q: String.trim(q), role: params["role"] || "all", status: params["status"] || "all"}}"
     )}
  end

  # A pushed payload is client-chosen; the guarded heads above and below each get
  # somewhere to fall, so a mangled one is a no-op rather than a crash (#764).
  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("page", %{"to" => to}, socket) when is_binary(to) do
    %{search: q, role_filter: role, status: status} = socket.assigns

    {:noreply,
     push_patch(socket,
       to: ~p"/editor/accounts?#{%{q: q, role: to_string(role), status: status, page: to}}"
     )}
  end

  def handle_event("page", _params, socket), do: {:noreply, socket}

  # --- one account -----------------------------------------------------------

  # The standing platform role plus the consumer audiences — one submit, because
  # they are one action (`:manage_access`) and an admin editing access edits both.
  def handle_event("save_access", %{"access" => params}, socket) when is_map(params) do
    %{actor: actor, account: account} = socket.assigns

    attrs = %{
      role: params["role"],
      audiences: checked_audiences(params)
    }

    case Accounts.manage_user_access(account, attrs, actor: actor) do
      {:ok, _user} ->
        {:noreply, reload_account(socket, gettext("Access updated."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("save_access", _params, socket), do: {:noreply, socket}

  def handle_event(
        "grant_role",
        %{"grant" => %{"role" => role, "hours" => hours} = grant},
        socket
      )
      when is_binary(role) and is_binary(hours) do
    %{actor: actor, account: account} = socket.assigns

    case Accounts.grant_user_temporary_role(
           account,
           %{granted_role: role, granted_role_expires_at: RoleGrantForm.expiry(grant)},
           actor: actor
         ) do
      {:ok, user} ->
        {:noreply,
         reload_account(
           socket,
           gettext("%{role} until %{when}.",
             role: String.capitalize(to_string(user.granted_role)),
             when: format_datetime(user.granted_role_expires_at)
           )
         )}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("grant_role", _params, socket), do: {:noreply, socket}

  def handle_event("revoke_grant", _params, socket) do
    %{actor: actor, account: account} = socket.assigns

    case Accounts.grant_user_temporary_role(
           account,
           %{granted_role: nil, granted_role_expires_at: nil},
           actor: actor
         ) do
      {:ok, _user} ->
        {:noreply, reload_account(socket, gettext("Temporary role ended."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("send_password_reset", _params, socket) do
    %{actor: actor, account: account} = socket.assigns

    case Accounts.send_user_password_reset(account.id, actor: actor) do
      {:ok, :sent} ->
        {:noreply,
         put_flash(socket, :info, gettext("Sent a reset link to %{email}.", email: account.email))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  # Revoking the stored tokens ends every browser session on the account's next
  # request; the eviction drops the sockets that are connected right now. Both,
  # because either alone leaves the account signed in somewhere — see the
  # `:log_out_everywhere` code interface.
  def handle_event("sign_out_everywhere", _params, socket) do
    %{actor: actor, account: account} = socket.assigns

    case Accounts.log_out_user_everywhere(account, actor: actor) do
      :ok ->
        SessionEviction.evict(account.id, :signed_out_by_admin)
        {:noreply, reload_account(socket, gettext("Signed out of every session."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  # Deletion is two decisions, so it is two steps: this one opens the
  # confirmation with the authored-content counts on it, because "archive
  # everything they wrote" means something different when it is 4 pages than when
  # it is 400 posts.
  def handle_event("confirm_removal", _params, socket) do
    {:noreply, assign(socket, :removing, AccountRemoval.authored_counts(socket.assigns.account))}
  end

  def handle_event("cancel_removal", _params, socket),
    do: {:noreply, assign(socket, :removing, nil)}

  def handle_event("remove_account", %{"disposition" => disposition}, socket)
      when disposition in ~w(keep archive trash) do
    %{actor: actor, account: account} = socket.assigns

    case AccountRemoval.remove(account, String.to_existing_atom(disposition), actor: actor) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, removal_message(result))
         |> push_navigate(to: ~p"/editor/accounts")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:removing, nil)
         |> put_flash(:error, ash_error_message(error))}
    end
  end

  # A pushed payload is client-chosen; give the guard above somewhere to fall.
  def handle_event("remove_account", _params, socket), do: {:noreply, socket}

  # --- data ------------------------------------------------------------------

  defp load_accounts(socket) do
    %{actor: actor, page: page} = socket.assigns
    offset = (page - 1) * @per_page

    rows =
      Accounts.list_users!(
        RoleGrant.unfolded() ++
          [
            actor: actor,
            query: [
              filter: register_filter(socket.assigns),
              sort: [email: :asc],
              limit: @per_page + 1,
              offset: offset
            ]
          ]
      )

    socket
    |> assign(:accounts, Enum.take(rows, @per_page))
    |> assign(:more?, length(rows) > @per_page)
  end

  # Filters compose as one expression rather than a keyword list so the search
  # term can be an `or` across two columns.
  defp register_filter(assigns) do
    [
      search_filter(assigns.search),
      role_filter_expr(assigns.role_filter),
      status_filter(assigns.status)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(nil, fn clause, acc ->
      if acc, do: Ash.Expr.expr(^acc and ^clause), else: clause
    end)
  end

  defp search_filter(""), do: nil

  defp search_filter(term) do
    # `contains/2` is case-insensitive on a `ci_string` email; `name` is a plain
    # string, so it gets `ilike`. A nil name simply doesn't match.
    like = "%#{term}%"
    Ash.Expr.expr(contains(email, ^term) or ilike(name, ^like))
  end

  defp role_filter_expr(:all), do: nil
  # The STANDING role, not the effective one: this column is what an admin set,
  # and a "Role: editor" filter that hid someone because they are an admin until
  # Friday would hide them from the page that would end the grant.
  defp role_filter_expr(role), do: Ash.Expr.expr(role == ^role)

  defp status_filter("all"), do: nil
  defp status_filter("unconfirmed"), do: Ash.Expr.expr(is_nil(confirmed_at))
  defp status_filter("erased"), do: Ash.Expr.expr(not is_nil(anonymized_at))

  defp status_filter("temporary"),
    do: Ash.Expr.expr(not is_nil(granted_role) and granted_role_expires_at > now())

  defp fetch_account(socket, id) do
    case Accounts.get_user(id, RoleGrant.unfolded() ++ [actor: socket.assigns.actor]) do
      {:ok, %{} = user} -> {:ok, user}
      _ -> :error
    end
  rescue
    # A malformed id in the URL is a 404, not a crash.
    _ -> :error
  end

  defp load_detail(socket, user) do
    actor = socket.assigns.actor

    socket
    |> assign(:memberships, memberships(user, actor))
    |> assign(:passkey_count, length(Accounts.list_passkeys!(user.id, actor: actor)))
    |> assign(:api_key_count, length(Accounts.list_api_keys!(user.id, actor: actor)))
  end

  defp memberships(user, actor) do
    Accounts.list_memberships_for_user!(
      user.id,
      RoleGrant.unfolded() ++ [actor: actor, load: [:organization, :custom_role]]
    )
  end

  defp reload_account(socket, message) do
    case fetch_account(socket, socket.assigns.account.id) do
      {:ok, user} ->
        socket
        |> assign(:account, user)
        |> assign(:removing, nil)
        |> load_detail(user)
        |> put_flash(:info, message)

      :error ->
        socket |> put_flash(:info, message) |> push_navigate(to: ~p"/editor/accounts")
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp role_filter(nil), do: :all
  defp role_filter("all"), do: :all

  defp role_filter(role) when role in ~w(admin editor viewer),
    do: String.to_existing_atom(role)

  defp role_filter(_other), do: :all

  defp status(status) when status in @statuses, do: status
  defp status(_other), do: "all"

  # The audience checkboxes arrive as `%{"audience_member" => "true", ...}` —
  # only the checked ones are submitted, so the absent ones are the removals.
  defp checked_audiences(params) do
    for audience <- KilnCMS.CMS.Audiences.all(),
        params["audience_#{audience}"] == "true",
        do: audience
  end

  # A type the sweep could not read is named, never folded into a success count:
  # "N documents archived" beside a type that was skipped is the false report the
  # sweep used to give.
  defp removal_message(%{unreadable: [_ | _] = unreadable} = result) do
    removal_message(%{result | unreadable: []}) <>
      " " <>
      gettext("Some content could not be read and was not handled: %{types}.",
        types: Enum.join(unreadable, ", ")
      )
  end

  defp removal_message(%{disposition: :keep}),
    do: gettext("Account erased. Its content was left as it was.")

  defp removal_message(%{disposition: :archive, affected: affected, failed: 0}) do
    ngettext(
      "Account erased and %{count} document archived.",
      "Account erased and %{count} documents archived.",
      affected,
      count: affected
    )
  end

  defp removal_message(%{disposition: :trash, affected: affected, failed: 0}) do
    ngettext(
      "Account erased and %{count} document moved to trash.",
      "Account erased and %{count} documents moved to trash.",
      affected,
      count: affected
    )
  end

  defp removal_message(%{affected: affected, failed: failed}) do
    ngettext(
      "Account erased. %{count} document handled, %{failed} could not be — check the trash and the content list.",
      "Account erased. %{count} documents handled, %{failed} could not be — check the trash and the content list.",
      affected,
      count: affected,
      failed: failed
    )
  end

  defp role_options, do: @role_options

  # Only tiers ABOVE the standing one can be granted (`RoleGrant.elevation?/2`),
  # so offering the others would be offering a refusal.
  defp grantable_roles(user) do
    Enum.filter(@role_options, fn {_label, role} ->
      RoleGrant.elevation?(role, user.role)
    end)
  end

  # The lowest tier that is still an elevation, so the select opens on the
  # smallest grant rather than on whatever the browser picks for an unmatched
  # value.
  defp default_grant_role(user) do
    case grantable_roles(user) do
      [{_label, role} | _] -> to_string(role)
      [] -> ""
    end
  end

  defp live_grant?(user), do: RoleGrant.live?(user)

  defp format_datetime(at), do: RoleGrantForm.format(at)

  defp status_options do
    [
      {gettext("Any status"), "all"},
      {gettext("Unconfirmed"), "unconfirmed"},
      {gettext("Temporary role"), "temporary"},
      {gettext("Erased"), "erased"}
    ]
  end

  defp role_filter_options,
    do:
      [{gettext("Any role"), "all"}] ++
        Enum.map(@role_options, fn {l, r} -> {l, to_string(r)} end)

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:accounts}
    >
      <.register :if={@account == nil} {assigns} />
      <.detail :if={@account != nil} {assigns} />
    </Layouts.console>
    """
  end

  defp register(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
          &larr; {gettext("All content")}
        </.link>
        <h1 class="mt-1 text-2xl font-semibold">{gettext("Accounts")}</h1>
        <p class="text-sm text-base-content/70">
          {gettext(
            "Everyone registered on this instance. Roles here are the platform role; per-site tiers live on each site's team page."
          )}
        </p>
      </div>

      <form phx-change="filter" phx-submit="filter" id="account-filters" class="card card-pad">
        <div class="grid gap-4 sm:grid-cols-3">
          <.input
            name="q"
            value={@search}
            type="search"
            label={gettext("Search")}
            placeholder={gettext("Email or name")}
            phx-debounce="300"
          />
          <.input
            name="role"
            value={to_string(@role_filter)}
            type="select"
            label={gettext("Role")}
            options={role_filter_options()}
          />
          <.input
            name="status"
            value={@status}
            type="select"
            label={gettext("Status")}
            options={status_options()}
          />
        </div>
      </form>

      <p :if={@accounts == []} class="text-sm text-base-content/60">
        {gettext("No accounts match that.")}
      </p>

      <ul :if={@accounts != []} class="card divide-y divide-base-content/10 overflow-hidden">
        <li :for={user <- @accounts} id={"account-#{user.id}"} class="p-4">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0 space-y-1">
              <.link navigate={~p"/editor/accounts/#{user.id}"} class="font-medium hover:underline">
                {user.email}
              </.link>
              <p :if={user.name} class="text-sm text-base-content/70">{user.name}</p>
              <p class="flex flex-wrap items-center gap-1">
                <.badge>{user.role}</.badge>
                <.badge :if={live_grant?(user)} variant="warning">
                  {gettext("%{role} · %{remaining}",
                    role: user.granted_role,
                    remaining: time_left(user.granted_role_expires_at)
                  )}
                </.badge>
                <.badge :if={is_nil(user.confirmed_at)} variant="outline">
                  {gettext("unconfirmed")}
                </.badge>
                <.badge :if={user.anonymized_at} variant="error">{gettext("erased")}</.badge>
              </p>
            </div>
            <.link
              navigate={~p"/editor/accounts/#{user.id}"}
              class="btn btn-sm btn-default shrink-0"
            >
              {gettext("Manage")}
            </.link>
          </div>
        </li>
      </ul>

      <div :if={@page > 1 || @more?} class="flex items-center justify-between">
        <button
          type="button"
          phx-click="page"
          phx-value-to={@page - 1}
          disabled={@page == 1}
          class="btn btn-sm btn-default disabled:opacity-40"
        >
          {gettext("Previous")}
        </button>
        <span class="text-sm text-base-content/60">{gettext("Page %{page}", page: @page)}</span>
        <button
          type="button"
          phx-click="page"
          phx-value-to={@page + 1}
          disabled={not @more?}
          class="btn btn-sm btn-default disabled:opacity-40"
        >
          {gettext("Next")}
        </button>
      </div>
    </div>
    """
  end

  defp detail(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.link navigate={~p"/editor/accounts"} class="text-sm text-base-content/60 hover:underline">
          &larr; {gettext("All accounts")}
        </.link>
        <h1 class="mt-1 text-2xl font-semibold break-all">{@account.email}</h1>
        <p class="flex flex-wrap items-center gap-1">
          <.badge>{@account.role}</.badge>
          <.badge :if={live_grant?(@account)} variant="warning">
            {gettext("%{role} until %{when}",
              role: @account.granted_role,
              when: format_datetime(@account.granted_role_expires_at)
            )}
          </.badge>
          <.badge :if={is_nil(@account.confirmed_at)} variant="outline">
            {gettext("unconfirmed")}
          </.badge>
          <.badge :if={KilnCMS.Accounts.totp_enabled?(@account)} variant="success">
            {gettext("2FA on")}
          </.badge>
          <.badge :if={@account.anonymized_at} variant="error">{gettext("erased")}</.badge>
          <.badge :if={own_account?(assigns)} variant="primary">{gettext("this is you")}</.badge>
        </p>
        <p :if={own_account?(assigns)} class="mt-1 text-sm text-base-content/70">
          {gettext(
            "Changes here apply to the session you are reading this in: a demotion or a sign-out takes effect immediately."
          )}
        </p>
      </div>

      <section class="card card-pad space-y-2">
        <h2 class="text-lg font-medium">{gettext("Account")}</h2>
        <dl class="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
          <.fact label={gettext("Name")} value={@account.name || gettext("—")} />
          <.fact label={gettext("Confirmed")} value={confirmed_text(@account)} />
          <.fact label={gettext("Passkeys")} value={@passkey_count} />
          <.fact label={gettext("API keys")} value={@api_key_count} />
        </dl>
      </section>

      <.access_panel {assigns} />
      <.temporary_role_panel {assigns} />
      <.sites_panel {assigns} />
      <.danger_panel {assigns} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp fact(assigns) do
    ~H"""
    <div>
      <dt class="text-base-content/60">{@label}</dt>
      <dd>{@value}</dd>
    </div>
    """
  end

  defp access_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-4">
      <div>
        <h2 class="text-lg font-medium">{gettext("Platform access")}</h2>
        <p class="text-sm text-base-content/70">
          {gettext(
            "The standing role, which applies instance-wide, plus the consumer audiences this account can read. A per-site tier overrides the role on that site."
          )}
        </p>
      </div>

      <form phx-submit="save_access" id="access-form" class="space-y-4">
        <.input
          name="access[role]"
          value={to_string(@account.role)}
          type="select"
          label={gettext("Platform role")}
          options={role_options()}
        />
        <fieldset>
          <legend class="text-sm font-medium">{gettext("Audiences")}</legend>
          <div class="mt-2 flex flex-wrap gap-4">
            <label
              :for={audience <- KilnCMS.CMS.Audiences.all()}
              class="flex items-center gap-2 text-sm"
            >
              <input
                type="checkbox"
                name={"access[audience_#{audience}]"}
                value="true"
                checked={audience in @account.audiences}
                class="rounded border-base-content/30"
              />
              {audience}
            </label>
          </div>
        </fieldset>
        <.button type="submit" variant="primary">{gettext("Save access")}</.button>
      </form>
    </section>
    """
  end

  defp temporary_role_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-4" id="temporary-role">
      <div>
        <h2 class="text-lg font-medium">{gettext("Temporary role")}</h2>
        <p class="text-sm text-base-content/70">
          {gettext(
            "A higher role that expires on its own. The standing role above is untouched, so nothing has to run on time for the elevation to end."
          )}
        </p>
      </div>

      <div :if={live_grant?(@account)} class="space-y-3">
        <p class="text-sm">
          {gettext("%{role} until %{when} — %{remaining}.",
            role: @account.granted_role,
            when: format_datetime(@account.granted_role_expires_at),
            remaining: time_left(@account.granted_role_expires_at)
          )}
        </p>
        <button type="button" phx-click="revoke_grant" class="btn btn-sm btn-default">
          {gettext("End it now")}
        </button>
      </div>

      <p
        :if={not live_grant?(@account) and grantable_roles(@account) == []}
        class="text-sm text-base-content/60"
      >
        {gettext("This account already holds the highest role — there is nothing to grant above it.")}
      </p>

      <form
        :if={not live_grant?(@account) and grantable_roles(@account) != []}
        phx-submit="grant_role"
        id="grant-form"
        class="space-y-4"
      >
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            name="grant[role]"
            value={default_grant_role(@account)}
            type="select"
            label={gettext("Grant role")}
            options={grantable_roles(@account)}
          />
          <.input
            name="grant[hours]"
            value="24"
            type="select"
            label={gettext("For")}
            options={RoleGrantForm.durations()}
          />
        </div>
        <div>
          <.input
            name="grant[until]"
            value=""
            type="datetime-local"
            label={gettext("Or until (UTC)")}
          />
          <p class="mt-1 text-xs text-base-content/60">
            {gettext("Leave blank to use the duration above.")}
          </p>
        </div>
        <.button type="submit" variant="primary">{gettext("Grant")}</.button>
      </form>
    </section>
    """
  end

  defp sites_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-3">
      <div>
        <h2 class="text-lg font-medium">{gettext("Sites")} ({length(@memberships)})</h2>
        <p class="text-sm text-base-content/70">
          {gettext("Per-site tiers are edited on each site's own team page.")}
        </p>
      </div>

      <p :if={@memberships == []} class="text-sm text-base-content/60">
        {gettext("This account belongs to no site, so it authorizes from its platform role alone.")}
      </p>

      <ul :if={@memberships != []} class="divide-y divide-base-content/10">
        <li :for={membership <- @memberships} class="flex items-center justify-between gap-4 py-2">
          <div class="min-w-0">
            <span class="text-sm font-medium">{membership.organization.name}</span>
            <p class="flex flex-wrap items-center gap-1">
              <.badge>{membership.role}</.badge>
              <.badge :if={live_grant?(membership)} variant="warning">
                {gettext("%{role} · %{remaining}",
                  role: membership.granted_role,
                  remaining: time_left(membership.granted_role_expires_at)
                )}
              </.badge>
              <.badge :if={membership.custom_role} variant="outline">
                {membership.custom_role.name}
              </.badge>
            </p>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp danger_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-4 border-error/30">
      <h2 class="text-lg font-medium">{gettext("Credentials and removal")}</h2>

      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          phx-click="send_password_reset"
          disabled={not is_nil(@account.anonymized_at)}
          class="btn btn-sm btn-default disabled:opacity-40"
        >
          {gettext("Send password reset")}
        </button>
        <button
          type="button"
          phx-click="sign_out_everywhere"
          data-confirm={gettext("Sign this account out of every browser and session?")}
          class="btn btn-sm btn-default"
        >
          {gettext("Sign out everywhere")}
        </button>
        <button
          :if={is_nil(@account.anonymized_at)}
          type="button"
          phx-click="confirm_removal"
          class="btn btn-sm btn-danger"
        >
          {gettext("Delete account…")}
        </button>
      </div>

      <p :if={@account.anonymized_at} class="text-sm text-base-content/60">
        {gettext("This account was erased on %{when}. Nothing personal remains on it.",
          when: format_datetime(@account.anonymized_at)
        )}
      </p>

      <.removal_form :if={@removing} {assigns} />
    </section>
    """
  end

  defp removal_form(assigns) do
    ~H"""
    <div class="space-y-4 rounded-lg border border-error/40 p-4" id="removal-confirm">
      <div class="space-y-1">
        <p class="font-medium">{gettext("Delete %{email}?", email: @account.email)}</p>
        <p class="text-sm text-base-content/70">
          {gettext(
            "The account is erased: the email is replaced with a tombstone, the password destroyed, passkeys and sign-in links deleted, every session revoked. The row itself stays, because the audit trail and every byline reference it — nothing personal is left on it."
          )}
        </p>
      </div>

      <div :if={@removing.counts != []} class="text-sm">
        <p class="text-base-content/60">{gettext("This account authored:")}</p>
        <ul class="mt-1 list-inside list-disc">
          <li :for={{label, count} <- @removing.counts}>{label}: {count}</li>
        </ul>
      </div>
      <p :if={@removing.unreadable != []} class="text-sm text-warning-ink" role="alert">
        {gettext(
          "Some content could not be counted (%{types}), so the numbers above may be low.",
          types: Enum.join(@removing.unreadable, ", ")
        )}
      </p>
      <p
        :if={@removing.counts == [] and @removing.unreadable == []}
        class="text-sm text-base-content/60"
      >
        {gettext("This account has authored nothing.")}
      </p>

      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          phx-click="remove_account"
          phx-value-disposition="keep"
          data-confirm={gettext("Erase the account and leave its content where it is?")}
          class="btn btn-sm btn-danger"
        >
          {gettext("Delete, keep content")}
        </button>
        <button
          type="button"
          phx-click="remove_account"
          phx-value-disposition="archive"
          data-confirm={gettext("Erase the account and archive everything it wrote?")}
          class="btn btn-sm btn-danger"
        >
          {gettext("Delete, archive content")}
        </button>
        <button
          type="button"
          phx-click="remove_account"
          phx-value-disposition="trash"
          data-confirm={gettext("Erase the account and move everything it wrote to the trash?")}
          class="btn btn-sm btn-danger"
        >
          {gettext("Delete, trash content")}
        </button>
        <button type="button" phx-click="cancel_removal" class="btn btn-sm btn-ghost">
          {gettext("Cancel")}
        </button>
      </div>
      <p class="text-xs text-base-content/60">
        {gettext(
          "Archived content can be sent back to draft by an editor; trashed content can be restored from the trash. Neither is a permanent delete."
        )}
      </p>
    </div>
    """
  end

  # Editing your own account from this page is legitimate — an admin may hand over
  # or erase themselves — but it is also where the surprises live, so say so. The
  # last-admin guard (`KilnCMS.Accounts.Validations.NotLastAdmin`) is what stops
  # the one version of this that has no way back.
  defp own_account?(%{account: %{id: id}, current_user: %{id: id}}), do: true
  defp own_account?(_assigns), do: false

  defp confirmed_text(%{confirmed_at: nil}), do: gettext("No")
  defp confirmed_text(%{confirmed_at: at}), do: format_datetime(at)
end
