defmodule KilnCMSWeb.SocialLive do
  @moduledoc """
  Social accounts (`/editor/social`) — connect the Bluesky and Mastodon accounts
  an automation rule can announce to (#497), and read the announcement ledger.

  Admin-only, mirroring the `KilnCMS.Social.Account` policy: the credentials
  here are the site's public voice, and anyone holding one can post as the
  organisation.

  ## Two things this page is careful about

  **A stored credential is never rendered back.** The field is always blank on
  edit and blank means *unchanged* — so a save that only flips `enabled` cannot
  wipe a working token, and a screenshot of this page never leaks one.

  **"Test connection" exists because the alternative is finding out later.**
  A wrong app password otherwise surfaces as an announcement that silently did
  not happen, hours after publishing, in a ledger nobody has opened.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Social
  alias KilnCMS.Social.Account
  alias KilnCMS.Social.Announcer

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, socket.assigns.current_user)
       |> assign(:page_title, gettext("Social accounts"))
       |> assign(:edit, nil)
       |> assign(:form, create_form(socket.assigns.current_user, socket.assigns.current_org))
       |> load_accounts()
       |> load_posts()}
    else
      # Defense in depth: `:live_admin_required` already redirects before mount,
      # but the fallback stays consistent rather than silently bouncing.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("validate", %{"account" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("create", %{"account" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
         |> load_accounts()
         |> put_flash(:info, gettext("Account connected."))}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org)
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"account" => params}, socket) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, params)
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"account" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: params) do
      {:ok, _account} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_accounts() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
    end
  end

  # Ask the provider whether the stored credential still works, without posting.
  def handle_event("verify", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, account} <- Social.get_account(id, actor: actor, tenant: org),
           module when not is_nil(module) <- Announcer.provider_module(account.provider) do
        case module.verify(account) do
          :ok ->
            put_flash(socket, :info, gettext("Connection works."))

          {:error, reason} ->
            put_flash(socket, :error, gettext("Connection failed: %{reason}", reason: reason))
        end
      else
        _ -> put_flash(socket, :error, gettext("Couldn't test that account."))
      end

    {:noreply, socket}
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, account} <- Social.get_account(id, actor: actor, tenant: org),
           {:ok, _} <-
             Social.update_account(account, %{enabled: !account.enabled},
               actor: actor,
               tenant: org
             ) do
        load_accounts(socket)
      else
        _ -> put_flash(socket, :error, gettext("Couldn't update that account."))
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, account} <- Social.get_account(id, actor: actor, tenant: org),
           :ok <- Social.destroy_account(account, actor: actor, tenant: org) do
        socket |> load_accounts() |> put_flash(:info, gettext("Account removed."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't remove that account."))
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  # --- data ------------------------------------------------------------------

  defp load_accounts(socket) do
    assign(
      socket,
      :accounts,
      Social.list_accounts!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [sort: [inserted_at: :asc]]
      )
    )
  end

  defp load_posts(socket) do
    assign(
      socket,
      :posts,
      Social.recent_posts!(actor: socket.assigns.actor, tenant: socket.assigns.current_org)
    )
  end

  defp create_form(actor, org),
    do:
      Account
      |> AshPhoenix.Form.for_create(:create, actor: actor, tenant: org, as: "account")
      |> to_form()

  defp edit_form(id, actor, org) do
    Social.get_account!(id, actor: actor, tenant: org)
    |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "account")
    |> to_form()
  end

  defp provider_options,
    do: Enum.map(Account.providers(), &{provider_label(&1), &1})

  defp provider_label(:bluesky), do: "Bluesky"
  defp provider_label(:mastodon), do: "Mastodon"
  defp provider_label(other), do: to_string(other)

  defp state_tone(:posted), do: "success"
  defp state_tone(:failed), do: "error"
  defp state_tone(:unknown), do: "warning"
  defp state_tone(_), do: "neutral"

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:social}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Social accounts")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Announce published content on Bluesky or Mastodon. Add an account here, then add an Automation rule with the \"Social post\" reaction."
            )}
          </p>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Connect an account")}</h2>
          <.form
            for={@form}
            id="new-social-account-form"
            phx-change="validate"
            phx-submit="create"
            class="card card-pad space-y-4"
          >
            <.input
              field={@form[:provider]}
              type="select"
              label={gettext("Network")}
              options={provider_options()}
            />
            <.input
              field={@form[:handle]}
              label={gettext("Handle")}
              placeholder="example.bsky.social"
              hint={gettext("Bluesky: your full handle. Mastodon: for display only.")}
            />
            <.input
              field={@form[:instance_url]}
              label={gettext("Instance URL")}
              placeholder="https://mastodon.social"
              hint={gettext("Mastodon only. Must be https, and reachable from this server.")}
            />
            <.input
              field={@form[:credential]}
              type="password"
              label={gettext("App password or access token")}
              autocomplete="off"
              hint={
                gettext(
                  "Bluesky: an app password, never your account password. Mastodon: an access token with write:statuses."
                )
              }
            />
            <.button type="submit" variant="primary">{gettext("Connect")}</.button>
          </.form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">
            {gettext("Connected")} ({length(@accounts)})
          </h2>

          <p :if={@accounts == []} class="text-sm text-base-content/60">
            {gettext("No accounts connected yet.")}
          </p>

          <div :for={account <- @accounts} class="card card-pad space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <p class="font-medium">
                  {provider_label(account.provider)}
                  <span :if={account.handle} class="text-base-content/60">
                    — {account.handle}
                  </span>
                </p>
                <p class="text-xs text-base-content/60">
                  <span :if={account.last_posted_at}>
                    {gettext("Last posted %{when}",
                      when: Calendar.strftime(account.last_posted_at, "%Y-%m-%d %H:%M UTC")
                    )}
                  </span>
                  <span :if={is_nil(account.last_posted_at)}>
                    {gettext("Has not posted yet")}
                  </span>
                </p>
              </div>
              <div class="flex flex-wrap gap-2">
                <.badge variant={if account.enabled, do: "success", else: "neutral"}>
                  {if account.enabled, do: gettext("Enabled"), else: gettext("Disabled")}
                </.badge>
                <button phx-click="verify" phx-value-id={account.id} class="btn btn-sm btn-default">
                  {gettext("Test connection")}
                </button>
                <button
                  phx-click="toggle_enabled"
                  phx-value-id={account.id}
                  class="btn btn-sm btn-default"
                >
                  {if account.enabled, do: gettext("Disable"), else: gettext("Enable")}
                </button>
                <button phx-click="edit" phx-value-id={account.id} class="btn btn-sm btn-default">
                  {gettext("Edit")}
                </button>
                <button
                  phx-click="delete"
                  phx-value-id={account.id}
                  data-confirm={gettext("Remove this account?")}
                  class="btn btn-sm btn-error"
                >
                  {gettext("Remove")}
                </button>
              </div>
            </div>

            <.form
              :if={@edit && @edit.id == account.id}
              for={@edit.form}
              id={"edit-social-account-#{account.id}"}
              phx-change="validate_edit"
              phx-submit="save_edit"
              class="space-y-3 border-t border-base-300 pt-3"
            >
              <%!-- Explicit ids: the create form above renders the same fields, and
                    `.input` derives its id from the field name — so without these
                    both forms emit `account_handle` and every label points at
                    whichever input the browser saw first. --%>
              <.input
                field={@edit.form[:handle]}
                id={"edit-handle-#{account.id}"}
                label={gettext("Handle")}
              />
              <.input
                field={@edit.form[:instance_url]}
                id={"edit-instance-#{account.id}"}
                label={gettext("Instance URL")}
              />
              <.input
                field={@edit.form[:credential]}
                id={"edit-credential-#{account.id}"}
                type="password"
                value=""
                autocomplete="off"
                label={gettext("Replace app password or token")}
                hint={gettext("Leave blank to keep the current one.")}
              />
              <div class="flex gap-2">
                <.button type="submit" variant="primary">{gettext("Save")}</.button>
                <button type="button" phx-click="cancel_edit" class="btn btn-default">
                  {gettext("Cancel")}
                </button>
              </div>
            </.form>
          </div>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Recent announcements")}</h2>

          <p class="text-xs text-base-content/60">
            {gettext(
              "Kiln posts at most once per document per account per publish, and never retries an announcement whose outcome was unclear — a duplicate post cannot be taken back."
            )}
          </p>

          <p :if={@posts == []} class="text-sm text-base-content/60">
            {gettext("Nothing announced yet.")}
          </p>

          <ul :if={@posts != []} class="divide-y divide-base-300">
            <li :for={post <- @posts} class="flex flex-wrap items-center gap-3 py-2 text-sm">
              <.badge variant={state_tone(post.state)}>{post.state}</.badge>
              <span class="text-base-content/70">{provider_label(post.provider)}</span>
              <span class="grow truncate">{post.text}</span>
              <a
                :if={post.remote_url}
                href={post.remote_url}
                target="_blank"
                rel="noopener noreferrer"
                class="link"
              >
                {gettext("View")}
              </a>
              <span :if={post.error} class="text-xs text-base-content/60">{post.error}</span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
