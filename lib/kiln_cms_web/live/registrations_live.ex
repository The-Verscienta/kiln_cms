defmodule KilnCMSWeb.RegistrationsLive do
  @moduledoc """
  The registration queue (`/editor/registrations`, #2251): who has signed up on
  this site and is waiting for an administrator, and the switch that makes them
  wait.

  With `KilnCMS.CMS.SiteRegistration` `approval_required` on, a self-registration
  on this site's host creates the account and a `:pending` membership here
  (`KilnCMS.Accounts.Changes.QueueRegistration`). The account can sign in but
  holds nothing until an admin approves it on this page; approving makes it a
  viewer here, rejecting keeps the account and marks the row rejected. A second
  switch, `approval_for_site_sso` (#2514), does the same for a new account this
  site's own single sign-on provisions; the two are independent.

  Applicants who have confirmed their address can be approved or rejected; the
  ones who have not can only be rejected, since anyone can register an address
  they do not own. The Rejected view lists those turned away.

  A third setting, `rejected_accounts` (#2514), erases an unconfirmed
  applicant's account when it is rejected, if nothing else hangs off it. The
  confirmation on such a row then says so, and only then does the click ask
  for the erasure (`erase: true`): an admin is never surprised by an erasure
  the dialog did not warn of. A standing admin only; a temporary one sees the
  ordinary confirmation, and the account is kept.

  Each list pages on its own (`Registrations.page/2`, "Load more"): confirmed
  applicants first and apart, so a wave of unconfirmed sign-ups cannot push the
  ones an admin can approve off the page. The headings count from bounded
  reads (`Registrations.pending_count/2`), not from the rows loaded. A decision
  takes its row out of the list in place rather than reloading from the first
  page.

  Scoped to the request's org, in the `:admin_routes` live session. Nothing here
  decides who may act: the queue read and both decisions are
  `OrgMembership` actions run as the signed-in user, whose policies admit an
  admin of the membership's own org, so every event is re-authorized by the
  action it runs.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.RegistrationRefused
  alias KilnCMS.Accounts.Registrations
  alias KilnCMS.Accounts.Registrations.Erasure
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMSWeb.PromotionWarning

  @impl true
  def mount(_params, _session, socket) do
    # Opening the queue reads its notice (#2251), and BEFORE the lists load
    # (`handle_params/3`), not after: an applicant who confirms in between
    # then leaves a fresh unread notice behind. Marked after, the notice for
    # someone this page never listed could be swept as read with them.
    # Connected only, so the static render does not mark it twice.
    if connected?(socket), do: mark_notice_read(socket)

    {:ok,
     socket
     |> assign(:page_title, gettext("Registrations"))
     |> assign(
       :registration_enabled?,
       Application.get_env(:kiln_cms, :registration_enabled, true)
     )
     |> assign(:status, :pending)
     |> assign(:lists, %{})
     |> assign(:counts, %{})
     |> load_settings()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] == "rejected", do: :rejected, else: :pending
    {:noreply, socket |> assign(:status, status) |> load_queue()}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) when is_binary(id),
    do: decide(socket, id, :approve)

  # `erase` is what the confirmation showed; the action still decides, from
  # the site's setting, the actor and the account, whether anything is erased.
  def handle_event("reject", %{"id" => id} = params, socket) when is_binary(id),
    do: decide(socket, id, {:reject, params["erase"] == "true"})

  # The next page of one list, after the last entry shown. The read is the
  # actor's own, so it is authorized again like the first.
  def handle_event("load_more", %{"list" => list}, socket) when is_binary(list) do
    case Enum.find(Map.keys(socket.assigns.lists), &(Atom.to_string(&1) == list)) do
      nil -> {:noreply, socket}
      key -> {:noreply, load_page(socket, key)}
    end
  end

  def handle_event("save_settings", %{"registration" => params}, socket) when is_map(params) do
    case CMS.save_site_registration(
           %{
             approval_required: params["approval_required"] == "true",
             approval_for_site_sso: params["approval_for_site_sso"] == "true",
             rejected_accounts: rejected_accounts(params["rejected_accounts"])
           },
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org,
           context: socket.assigns.security_context
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Registration settings saved."))
         |> load_settings()}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           ash_error_message(error,
             forbidden: gettext("You don't have permission to change this site's registration."),
             fallback: gettext("The registration settings could not be saved.")
           )
         )}
    end
  end

  # A pushed payload is client-chosen; give the guarded heads above somewhere
  # to fall (#764).
  def handle_event(event, _params, socket)
      when event in ~w(approve reject save_settings load_more),
      do: {:noreply, socket}

  # Anything but the one value that erases keeps.
  defp rejected_accounts("erase_unconfirmed"), do: :erase_unconfirmed
  defp rejected_accounts(_keep), do: :keep

  # As the signed-in user, on their own unread notice for this site only —
  # `Notifications.mark_read_about/4` reads and marks as them. A failure costs
  # an unread badge, so it is not the page's business.
  defp mark_notice_read(%{assigns: %{current_user: user, current_org: %{id: org_id}}}) do
    Notifications.mark_read_about(user, org_id, Notifications.Registrations.event(), org_id)
  end

  defp mark_notice_read(_socket), do: :ok

  # Re-authorized by the action itself: approving and rejecting are
  # `OrgMembership` actions whose policy admits only an admin of the row's org,
  # and the row is re-read and locked inside them, so a stale page cannot
  # decide a registration another admin has already decided.
  defp decide(socket, id, outcome) do
    case find_entry(socket, id) do
      nil ->
        {:noreply, socket}

      {key, %{membership: membership, email: email}} ->
        opts = [actor: socket.assigns.current_user, context: socket.assigns.security_context]

        result =
          case outcome do
            :approve -> Accounts.approve_registration(membership, %{}, opts)
            {:reject, erase?} -> Accounts.reject_registration(membership, %{erase: erase?}, opts)
          end

        {:noreply,
         socket
         |> settle(key, membership.id, outcome, email, result)
         |> approval_warning(outcome, result)}
    end
  end

  # Decided — by this admin, or (refused as no longer pending) by another — so
  # it leaves the list; every other loaded row stays put. Any other refusal
  # leaves it where it was.
  defp settle(socket, key, id, outcome, email, {:ok, membership}) do
    socket
    |> put_flash(:info, decided_message(outcome, email, membership))
    |> drop_entry(key, id)
    |> load_counts()
  end

  defp settle(socket, key, id, _outcome, _email, {:error, error}) do
    socket = put_flash(socket, :error, error_message(error))

    if RegistrationRefused.reason(error) == :not_pending,
      do: socket |> drop_entry(key, id) |> load_counts(),
      else: socket
  end

  # An approval makes the applicant a viewer, and a registration may have
  # waited longer than the grace period of a site that requires two-step
  # sign-in of everyone: they are then held at their first page (#2247). Said
  # with the confirmation, never in its way.
  defp approval_warning(socket, :approve, {:ok, membership}) do
    applicant = Registrations.approved_applicant(membership)

    case PromotionWarning.message(applicant, membership.organization_id, membership.role) do
      nil ->
        socket

      warning ->
        confirmation = Phoenix.Flash.get(socket.assigns.flash, :info)
        put_flash(socket, :info, PromotionWarning.with_confirmation(confirmation, warning))
    end
  end

  defp approval_warning(socket, _outcome, _result), do: socket

  defp find_entry(socket, id) do
    Enum.find_value(socket.assigns.lists, fn {key, %{entries: entries}} ->
      case Enum.find(entries, &(&1.membership.id == id)) do
        nil -> nil
        entry -> {key, entry}
      end
    end)
  end

  defp drop_entry(socket, key, id) do
    list = Map.fetch!(socket.assigns.lists, key)
    entries = Enum.reject(list.entries, &(&1.membership.id == id))

    socket =
      assign(socket, :lists, Map.put(socket.assigns.lists, key, %{list | entries: entries}))

    # Emptied a page that has more behind it: fetch the next, rather than
    # showing "nobody" over rows that are there.
    if entries == [] and list.more?, do: load_page(socket, key), else: socket
  end

  defp decided_message(:approve, email, _membership),
    do:
      gettext("Approved %{email}. They can now read this site as a viewer. We'll email them.",
        email: email
      )

  defp decided_message({:reject, erase?}, email, membership) do
    case {erase?, membership.__metadata__[:registration_outcome]} do
      {_asked, :erased} ->
        gettext("Rejected %{email} and erased the account.", email: email)

      {true, _kept} ->
        gettext(
          "Rejected %{email}. The account was kept, because it's more than this registration or it can't be erased right now.",
          email: email
        )

      {false, _kept} ->
        gettext("Rejected %{email}.", email: email)
    end
  end

  defp error_message(error) do
    case RegistrationRefused.reason(error) do
      :not_pending ->
        gettext("That registration has already been decided.")

      :unconfirmed ->
        gettext("That person hasn't confirmed their email address yet, so it can't be approved.")

      :erased ->
        gettext("That account was erased, so it can't be approved.")

      _other ->
        ash_error_message(error,
          forbidden: gettext("You don't have permission to decide registrations on this site."),
          fallback: gettext("The registration could not be updated.")
        )
    end
  end

  # The lists a tab shows, each with its own `Registrations.page/2` filter.
  defp list_keys(:pending), do: [:confirmed, :unconfirmed]
  defp list_keys(:rejected), do: [:rejected]

  defp list_filter(:confirmed), do: [status: :pending, confirmed: true]
  defp list_filter(:unconfirmed), do: [status: :pending, confirmed: false]
  defp list_filter(:rejected), do: [status: :rejected]

  # Every list of the tab from its first page — on mount and on a tab switch.
  defp load_queue(socket) do
    keys = list_keys(socket.assigns.status)
    socket = assign(socket, :lists, Map.new(keys, &{&1, %{entries: [], more?: false}}))

    keys
    |> Enum.reduce(socket, &load_page(&2, &1))
    |> load_counts()
  end

  # One more page of list `key`, appended (a keyset from its last entry).
  defp load_page(socket, key) do
    %{current_user: actor, current_org: org, lists: lists} = socket.assigns
    list = Map.get(lists, key, %{entries: [], more?: false})
    opts = [actor: actor, after: List.last(list.entries)] ++ list_filter(key)

    list =
      case Registrations.page(org, opts) do
        {:ok, %{entries: page, more?: more?}} -> %{entries: list.entries ++ page, more?: more?}
        {:error, _refused} -> %{list | more?: false}
      end

    assign(socket, :lists, Map.put(lists, key, list))
  end

  # The headings' numbers: bounded reads, so they say how many are waiting
  # rather than how many are loaded.
  defp load_counts(socket) do
    %{current_user: actor, current_org: org} = socket.assigns

    counts =
      Map.new([:confirmed, :unconfirmed], fn key ->
        {key, Registrations.pending_count(org, actor: actor, confirmed: key == :confirmed)}
      end)

    assign(socket, :counts, counts)
  end

  defp count_label(count) do
    if count >= Registrations.count_cap(),
      do: gettext("%{count}+", count: count),
      else: Integer.to_string(count)
  end

  defp entries(lists, key), do: lists |> Map.get(key, %{entries: []}) |> Map.fetch!(:entries)
  defp more?(lists, key), do: lists |> Map.get(key, %{more?: false}) |> Map.fetch!(:more?)

  defp load_settings(socket) do
    row = current_row(socket)
    required? = (row && row.approval_required) || false
    site_sso? = (row && row.approval_for_site_sso) || false
    rejected_accounts = (row && row.rejected_accounts) || :keep
    %{current_user: actor, current_org: org} = socket.assigns

    socket
    |> assign(:approval_required?, required?)
    # Whether a rejection here erases an unconfirmed account: the site's
    # setting, and a standing admin to do it (a temporary one only rejects).
    |> assign(
      :erase_unconfirmed?,
      rejected_accounts == :erase_unconfirmed and
        Erasure.standing_admin?(actor, org && org.id)
    )
    |> assign(
      :settings_form,
      to_form(
        %{
          "approval_required" => to_string(required?),
          "approval_for_site_sso" => to_string(site_sso?),
          "rejected_accounts" => to_string(rejected_accounts)
        },
        as: :registration
      )
    )
  end

  defp current_row(socket) do
    case CMS.list_site_registration(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  attr :list, :atom, required: true

  defp load_more(assigns) do
    ~H"""
    <div class="mt-4">
      <.button
        id={"registrations-load-more-#{@list}"}
        type="button"
        variant="ghost"
        size="sm"
        phx-click="load_more"
        phx-value-list={@list}
      >
        {gettext("Load more")}
      </.button>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :status, :atom, required: true
  attr :approvable?, :boolean, default: true
  attr :erase?, :boolean, default: false, doc: "whether the site erases unconfirmed rejections"

  defp applicant(assigns) do
    ~H"""
    <li
      id={"registration-#{@entry.membership.id}"}
      class="flex flex-wrap items-center justify-between gap-4 py-3"
    >
      <div class="min-w-0">
        <p class="truncate font-medium">{@entry.email}</p>
        <p :if={@entry.name} class="truncate text-sm text-base-content/70">{@entry.name}</p>
        <p :if={@entry.erased?} id={"registration-erased-#{@entry.membership.id}"} class="mt-1">
          <.badge variant="warning">{gettext("Account erased")}</.badge>
        </p>
        <p class="mt-0.5 text-xs text-base-content/70">
          {gettext("Registered %{at}", at: format_time(@entry.registered_at))}
          <span :if={@entry.membership.decided_at}>
            · {gettext("Rejected %{at}", at: format_time(@entry.membership.decided_at))}
          </span>
        </p>
      </div>
      <div class="flex items-center gap-2">
        <.button
          :if={@approvable? and not @entry.erased?}
          id={"approve-#{@entry.membership.id}"}
          type="button"
          size="sm"
          phx-click="approve"
          phx-value-id={@entry.membership.id}
          phx-disable-with={gettext("Approving…")}
        >
          <.icon name="hero-check" class="size-4" /> {gettext("Approve")}
        </.button>
        <.button
          :if={@status == :pending}
          id={"reject-#{@entry.membership.id}"}
          type="button"
          variant="ghost"
          size="sm"
          phx-click="reject"
          phx-value-id={@entry.membership.id}
          phx-value-erase={to_string(erases?(@entry, @erase?))}
          data-confirm={reject_confirm(@entry, erases?(@entry, @erase?))}
        >
          <.icon name="hero-x-mark" class="size-4" /> {gettext("Reject")}
        </.button>
      </div>
    </li>
    """
  end

  # Whether rejecting this entry asks for an erasure: the site erases
  # unconfirmed rejections, and this address was never confirmed (#2514).
  defp erases?(%{confirmed?: false, erased?: false}, true), do: true
  defp erases?(_entry, _erase?), do: false

  # A confirmed applicant is mailed the rejection (#2251); an unconfirmed one is
  # not, since the address was never proven theirs, and nor is an erased one.
  defp reject_confirm(%{email: email}, true),
    do:
      gettext(
        "Reject %{email} and erase the account? This address was never confirmed, so the account is erased, unless it's used for anything besides this registration. Erasing can't be undone, and the address can register again.",
        email: email
      )

  defp reject_confirm(entry, false), do: reject_confirm(entry)

  defp reject_confirm(%{confirmed?: true, erased?: false, email: email}),
    do:
      gettext(
        "Reject %{email}? The account is kept but gets no access to this site, and they can't register here again with this address. They'll be emailed that it wasn't approved.",
        email: email
      )

  defp reject_confirm(%{email: email}),
    do:
      gettext(
        "Reject %{email}? The account is kept but gets no access to this site, and they can't register here again with this address.",
        email: email
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:registrations}
    >
      <.header>
        {gettext("Registrations")}
        <:subtitle>
          {gettext(
            "People who signed up on this site and are waiting for an administrator. Until approved they can sign in, but can only read what's public."
          )}
        </:subtitle>
      </.header>

      <nav class="mt-6 flex gap-2" aria-label={gettext("Registrations")}>
        <.link
          patch={~p"/editor/registrations"}
          id="registrations-pending-tab"
          class={["btn btn-sm", if(@status == :pending, do: "btn-primary", else: "btn-ghost")]}
          aria-current={@status == :pending && "page"}
        >
          {gettext("Waiting")}
        </.link>
        <.link
          patch={~p"/editor/registrations?status=rejected"}
          id="registrations-rejected-tab"
          class={["btn btn-sm", if(@status == :rejected, do: "btn-primary", else: "btn-ghost")]}
          aria-current={@status == :rejected && "page"}
        >
          {gettext("Rejected")}
        </.link>
      </nav>

      <section :if={@status == :pending} class="mt-6 space-y-8">
        <div>
          <h2 class="text-sm font-semibold">
            {gettext("Waiting for approval")} ({count_label(@counts[:confirmed] || 0)})
          </h2>
          <p
            :if={entries(@lists, :confirmed) == []}
            id="registrations-empty"
            class="mt-2 text-sm text-base-content/70"
          >
            {gettext("Nobody is waiting.")}
          </p>
          <ul
            :if={entries(@lists, :confirmed) != []}
            id="registrations-confirmed"
            class="mt-3 divide-y divide-base-300"
          >
            <.applicant :for={entry <- entries(@lists, :confirmed)} entry={entry} status={@status} />
          </ul>
          <.load_more :if={more?(@lists, :confirmed)} list={:confirmed} />
        </div>

        <div :if={entries(@lists, :unconfirmed) != []}>
          <h2 class="text-sm font-semibold">
            {gettext("Email not confirmed yet")} ({count_label(@counts[:unconfirmed] || 0)})
          </h2>
          <p class="mt-1 text-sm text-base-content/70">
            {gettext(
              "These can't be approved until they confirm their address, since anyone can sign up with an address they don't own. You can reject them now."
            )}
          </p>
          <ul id="registrations-unconfirmed" class="mt-3 divide-y divide-base-300">
            <.applicant
              :for={entry <- entries(@lists, :unconfirmed)}
              entry={entry}
              status={@status}
              approvable?={false}
              erase?={@erase_unconfirmed?}
            />
          </ul>
          <.load_more :if={more?(@lists, :unconfirmed)} list={:unconfirmed} />
        </div>
      </section>

      <section :if={@status == :rejected} class="mt-6">
        <p
          :if={entries(@lists, :rejected) == []}
          id="registrations-empty"
          class="text-sm text-base-content/70"
        >
          {gettext("Nobody has been rejected.")}
        </p>
        <ul
          :if={entries(@lists, :rejected) != []}
          id="registrations-rejected"
          class="divide-y divide-base-300"
        >
          <%!-- A rejection can be reversed: approve, for a confirmed address. --%>
          <.applicant
            :for={entry <- entries(@lists, :rejected)}
            entry={entry}
            status={@status}
            approvable?={entry.confirmed?}
          />
        </ul>
        <.load_more :if={more?(@lists, :rejected)} list={:rejected} />
      </section>

      <section class="mt-12 border-t border-base-300 pt-8">
        <h2 class="text-lg font-medium">{gettext("Settings")}</h2>

        <div
          :if={!@registration_enabled?}
          id="registrations-disabled"
          role="status"
          class="mt-4 flex gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
          <p>
            {gettext(
              "Open registration is switched off for this deployment, so nobody can sign up and this setting has no effect. People join through invitations."
            )}
          </p>
        </div>

        <.form
          for={@settings_form}
          id="registration-settings-form"
          phx-submit="save_settings"
          class="mt-4 max-w-2xl space-y-4"
        >
          <.input
            field={@settings_form[:approval_required]}
            type="checkbox"
            label={gettext("New registrations wait for an administrator's approval")}
          />
          <p class="text-xs text-base-content/70">
            {gettext(
              "Applies to people who sign up with a password on this site. Invitations and existing accounts are not affected, and this site's single sign-on has its own switch below. Turning it off doesn't approve anyone already waiting."
            )}
          </p>
          <.input
            field={@settings_form[:approval_for_site_sso]}
            type="checkbox"
            label={gettext("New accounts from this site's single sign-on wait for approval too")}
          />
          <p class="text-xs text-base-content/70">
            {gettext(
              "Applies only if this site has its own single sign-on. Someone signing in that way for the first time gets an account that waits here; people who already have an account are not affected."
            )}
          </p>
          <.input
            field={@settings_form[:rejected_accounts]}
            type="select"
            label={gettext("When you reject someone")}
            options={[
              {gettext("Keep the account"), "keep"},
              {gettext("Erase the account if the email address was never confirmed"),
               "erase_unconfirmed"}
            ]}
          />
          <p id="registration-rejected-accounts-hint" class="text-xs text-base-content/70">
            {gettext(
              "Erasing can't be undone. Only accounts whose address was never confirmed and that are used for nothing besides this registration are erased; a rejected applicant who confirmed their address is always kept. An erased address can register again, while a kept one can't register here again."
            )}
          </p>
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
        </.form>
      </section>
    </Layouts.console>
    """
  end
end
