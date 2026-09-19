defmodule KilnCMSWeb.SiteMailLive do
  @moduledoc """
  A site's own outgoing mail (#1322): the SMTP relay and From address this
  site's mail goes out through, at `/editor/site-mail`.

  Before this, the relay was `SMTP_*` environment variables — one relay for the
  whole deployment, changed by the operator with a redeploy. Now a site admin
  can send their site's mail through their own provider, under their own domain,
  with no redeploy. The operator's relay stays underneath, for every site that
  has not set one and for account mail, which belongs to the deployment.

  Scoped to the request's org, like `/editor/code-injection`. Writes are
  policy-gated to org admins by `KilnCMS.CMS.SiteMailRelay`, and the
  `:admin_routes` live session gates on the same tier.

  ## What the page has to say

    * **Which relay is in use now.** "The deployment's relay" and "this site's
      relay" send differently, and the admin can't tell which from the form.
    * **Which mail this covers.** Account mail (sign-in links, password
      resets) is not the site's, and an admin who set a relay to fix those will
      otherwise think it is broken.
    * **When the stored password can't be read.** After a `SECRET_KEY_BASE`
      rotation the row still looks fine, but the site's mail is being held.
      This page is the one place that can say so.

  The password field is write-only. It is never filled in, so a blank field
  keeps the stored password (`Changes.StoreRelayPassword`).

  ## Sending a test

  "Send a test" delivers synchronously through what is *saved*, to the signed-in
  admin's own address. Only to that address: the button would otherwise be a way
  to send mail from this deployment to anyone. `Mail.deliver_now/2` takes no
  actor, so the handler re-asks the resource's update policy before sending
  instead of trusting the mount guard alone (#1166).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Mail
  alias KilnCMS.Mail.SiteRelay

  @fields ~w(host port security username from_email from_name)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Outgoing mail"))
     |> assign(:sending_test?, false)
     |> assign(:test_result, nil)
     |> load_relay()}
  end

  @impl true
  def handle_event("validate", %{"relay" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, to_form(params, as: :relay))}
  end

  def handle_event("save", %{"relay" => params}, socket) when is_map(params) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

    # An existing row is updated, never re-upserted: the upsert leaves the
    # password out of what it overwrites, so a blank-password save through it
    # would quietly drop a new one (see `SiteMailRelay`'s moduledoc).
    result =
      case socket.assigns.row do
        nil -> CMS.save_site_mail_relay(attrs(params), opts)
        row -> CMS.update_site_mail_relay(row, attrs(params), opts)
      end

    case result do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Outgoing mail saved."))
         |> assign(:test_result, nil)
         |> load_relay()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.delete(params, "password"), as: :relay))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    case socket.assigns.row do
      nil ->
        {:noreply, socket}

      row ->
        CMS.reset_site_mail_relay!(row,
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_org
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Removed. This site's mail uses the deployment's relay again.")
         )
         |> assign(:test_result, nil)
         |> load_relay()}
    end
  end

  def handle_event("send_test", _params, socket) do
    %{row: row, current_user: user, current_org: org} = socket.assigns

    cond do
      # Switched off, the "test" would go through the deployment's relay and
      # prove nothing about this one.
      socket.assigns.sending_test? or is_nil(row) or not row.enabled ->
        {:noreply, socket}

      # `Mail.deliver_now/2` checks nothing, so a forged event on a socket that
      # never passed the mount guard stops here (#1166).
      not CMS.can_update_site_mail_relay?(user, row, tenant: org) ->
        {:noreply, socket}

      true ->
        org_id = KilnCMS.Accounts.org_id(org)
        email = test_email(to_string(user.email))

        {:noreply,
         socket
         |> assign(:sending_test?, true)
         |> assign(:test_result, nil)
         |> start_async(:send_test, fn -> Mail.deliver_now(email, org_id: org_id) end)}
    end
  end

  @impl true
  def handle_async(:send_test, {:ok, {:ok, _receipt}}, socket) do
    {:noreply,
     socket
     |> assign(:sending_test?, false)
     |> assign(:test_result, {:ok, to_string(socket.assigns.current_user.email)})}
  end

  def handle_async(:send_test, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:sending_test?, false)
     |> assign(:test_result, {:error, describe_failure(reason)})}
  end

  def handle_async(:send_test, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:sending_test?, false)
     |> assign(:test_result, {:error, gettext("The test send stopped unexpectedly.")})}
  end

  defp test_email(to) do
    text = gettext("This is a test email from your site's outgoing mail settings.")

    # The From here is the deployment's; `SiteRelay` moves it onto the site's
    # own address when the site's relay is in use, exactly as for real mail.
    Swoosh.Email.new()
    |> Swoosh.Email.from(Application.fetch_env!(:kiln_cms, :email_from))
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.subject(gettext("Test email"))
    |> Swoosh.Email.html_body("<p>#{text}</p>")
    |> Swoosh.Email.text_body(text)
  end

  defp describe_failure({:site_relay, reason}), do: SiteRelay.describe_error(reason)
  defp describe_failure(reason), do: inspect(reason, limit: 20, printable_limit: 300)

  defp attrs(params) do
    params
    |> Map.take(@fields)
    |> Map.put("enabled", params["enabled"] in [true, "true", "on"])
    |> Map.put("password", params["password"])
  end

  defp load_relay(socket) do
    row = current_row(socket)

    params =
      if row do
        %{
          "enabled" => row.enabled,
          "host" => row.host,
          "port" => row.port,
          "security" => to_string(row.security),
          "username" => row.username,
          "from_email" => row.from_email,
          "from_name" => row.from_name
        }
      else
        %{"enabled" => true, "port" => 587, "security" => "starttls"}
      end

    socket
    |> assign(:row, row)
    |> assign(:password_stored?, row && not is_nil(row.password_encrypted))
    |> assign(:password_readable?, is_nil(row) or SiteRelay.password_readable?(row))
    |> assign(:form, to_form(params, as: :relay))
  end

  defp current_row(socket) do
    case CMS.list_site_mail_relay(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  defp operator_from do
    case Application.get_env(:kiln_cms, :email_from) do
      {_name, address} -> address
      _unset -> nil
    end
  end

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's outgoing mail."),
      fallback: gettext("Outgoing mail could not be saved.")
    )
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :operator_from, operator_from())

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      active={:site_mail}
    >
      <.header>
        {gettext("Outgoing mail")}
        <:subtitle>
          {gettext("The mail provider and From address this site's email is sent from.")}
        </:subtitle>
      </.header>

      <div id="site-mail-status" class="mt-6 card card-pad text-sm">
        <%= if @row && @row.enabled do %>
          <p class="font-medium">
            {gettext("This site's mail goes out through %{host}, from %{from}.",
              host: @row.host,
              from: @row.from_email
            )}
          </p>
        <% else %>
          <p class="font-medium">
            <%= if @operator_from do %>
              {gettext("This site's mail goes out through the deployment's relay, from %{from}.",
                from: @operator_from
              )}
            <% else %>
              {gettext("This site's mail goes out through the deployment's relay.")}
            <% end %>
          </p>
        <% end %>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "This covers newsletters, form notifications and autoresponders, workflow, task and comment notifications, and automation emails. Sign-in links, password resets and other account mail always use the deployment's relay, because accounts belong to the deployment, not to one site."
          )}
        </p>
      </div>

      <div
        :if={not @password_readable?}
        id="site-mail-password-unreadable"
        role="alert"
        class="mt-4 rounded-lg border border-error/40 bg-error/10 p-4 text-sm text-error-ink"
      >
        <p class="font-medium">{gettext("The saved password can't be read. Re-enter it.")}</p>
        <p class="mt-1">
          {gettext(
            "The deployment's secret key has changed since it was saved. Until you enter it again, this site's mail is held and retried, not sent."
          )}
        </p>
      </div>

      <.form
        for={@form}
        id="site-mail-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-8 space-y-6"
      >
        <.input
          field={@form[:enabled]}
          type="checkbox"
          label={gettext("Send this site's mail through this relay")}
          value={@form[:enabled].value}
        />

        <div class="grid gap-4 sm:grid-cols-3">
          <div class="sm:col-span-2">
            <.input
              field={@form[:host]}
              type="text"
              label={gettext("SMTP host")}
              placeholder="smtp.postmarkapp.com"
              autocomplete="off"
            />
          </div>
          <.input field={@form[:port]} type="number" label={gettext("Port")} min="1" max="65535" />
        </div>

        <.input
          field={@form[:security]}
          type="select"
          label={gettext("Encryption")}
          options={[
            {gettext("STARTTLS (usually port 587)"), "starttls"},
            {gettext("TLS (usually port 465)"), "tls"}
          ]}
          hint={gettext("Always encrypted, and the server's certificate is always checked.")}
        />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:username]}
            type="text"
            label={gettext("Username")}
            autocomplete="off"
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            value=""
            autocomplete="new-password"
            placeholder={if @password_stored?, do: gettext("Saved. Leave blank to keep it.")}
            hint={
              gettext("Stored encrypted and never shown again. Clearing the username removes it.")
            }
          />
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:from_email]}
            type="email"
            label={gettext("From address")}
            placeholder="news@example.com"
            hint={gettext("Must be an address your provider will send for.")}
          />
          <.input
            field={@form[:from_name]}
            type="text"
            label={gettext("From name")}
            hint={gettext("Leave blank to use the site's name.")}
          />
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <.button
            :if={@row && @row.enabled}
            type="button"
            variant="ghost"
            id="site-mail-send-test"
            phx-click="send_test"
            disabled={@sending_test?}
          >
            {if @sending_test?,
              do: gettext("Sending…"),
              else: gettext("Send a test to %{email}", email: to_string(@current_user.email))}
          </.button>
          <.button
            :if={@row}
            type="button"
            variant="ghost"
            phx-click="reset"
            data-confirm={
              gettext("Remove this site's relay? Its mail will use the deployment's relay again.")
            }
          >
            {gettext("Remove")}
          </.button>
        </div>
      </.form>

      <div :if={@test_result} id="site-mail-test-result" role="status" class="mt-4 text-sm">
        <%= case @test_result do %>
          <% {:ok, to} -> %>
            <p class="text-success-ink">
              {gettext("Sent to %{email}. Check that inbox.", email: to)}
            </p>
          <% {:error, message} -> %>
            <p class="text-error-ink">
              {gettext("The test didn't send: %{reason}", reason: message)}
            </p>
        <% end %>
      </div>
    </Layouts.console>
    """
  end
end
