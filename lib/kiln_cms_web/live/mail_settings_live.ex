defmodule KilnCMSWeb.MailSettingsLive do
  @moduledoc """
  Mail settings (`/editor/mail`, admin-only) — the operator console for
  direct email delivery (`docs/direct-email-delivery.md`): DKIM key
  management through the key providers (`KilnCMS.Keys`), the DNS records to
  publish with live verification, the outbound port-25 preflight, and test
  sends. Slow work (DNS lookups, SMTP dialogs) runs via `start_async` so the
  page stays responsive.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Keys
  alias KilnCMS.Mail
  alias KilnCMS.Mail.DnsCheck

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Mail"))
       |> assign(:mode, mailer_mode())
       |> assign(:from, Application.get_env(:kiln_cms, :email_from))
       |> assign(:helo_host, DnsCheck.helo_host())
       |> assign(:domain, Mail.sending_domain())
       |> assign(:verifying?, false)
       |> assign(:preflighting?, false)
       |> assign(:sending_test?, false)
       |> assign(:preflight, nil)
       |> assign(:test_result, nil)
       |> assign(:test_to, to_string(actor.email))
       |> load_settings(Mail.ensure_settings!())
       |> load_delivery_health()}
    else
      # Defense-in-depth: the `:live_admin_required` on_mount guard already
      # redirects non-admins before mount runs; mirror it for consistency.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- DKIM key management ----------------------------------------------------

  @impl true
  def handle_event("generate", _params, socket) do
    case Mail.generate_dkim(socket.assigns.settings, actor: socket.assigns.actor) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> load_settings(settings)
         |> put_flash(:info, gettext("DKIM key generated. Publish the DNS record below."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("rotate", _params, socket) do
    case Mail.rotate_dkim(socket.assigns.settings, actor: socket.assigns.actor) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> load_settings(settings)
         |> put_flash(
           :info,
           gettext(
             "Key rotated. Publish the new DNS record; the old one can stay up while signed mail is in transit."
           )
         )}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("select_provider", %{"provider" => provider}, socket)
      when provider in ~w(database env file) do
    {:noreply, assign(socket, :selected_provider, String.to_existing_atom(provider))}
  end

  def handle_event("save_key_source", %{"source" => %{"provider" => provider} = params}, socket)
      when provider in ~w(env file) do
    provider = String.to_existing_atom(provider)
    pointer = String.trim(params["pointer"] || "")

    config =
      case provider do
        :env -> %{"var" => pointer}
        :file -> %{"path" => pointer}
      end

    case Mail.configure_dkim_key_source(socket.assigns.settings, provider, config,
           actor: socket.assigns.actor
         ) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> load_settings(settings)
         |> put_flash(:info, gettext("Key source saved and checked."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # --- DNS records / verification ----------------------------------------------

  def handle_event("save_server_ip", %{"settings" => %{"server_ip" => ip}}, socket) do
    ip = if String.trim(ip) == "", do: nil, else: String.trim(ip)

    case Mail.set_mail_server_ip(socket.assigns.settings, %{server_ip: ip},
           actor: socket.assigns.actor
         ) do
      {:ok, settings} ->
        {:noreply, socket |> load_settings(settings) |> put_flash(:info, gettext("Saved."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("verify", _params, socket) do
    settings = socket.assigns.settings

    # Ignore a re-click while a run is already in flight: the disabled button
    # attribute is client-side only, so a fast double-click (or a replayed
    # event) would otherwise start a second concurrent run.
    if socket.assigns.verifying? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:verifying?, true)
       |> start_async(:verify, fn -> DnsCheck.run(settings) end)}
    end
  end

  def handle_event("preflight", _params, socket) do
    if socket.assigns.preflighting? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:preflighting?, true)
       |> start_async(:preflight, fn -> DnsCheck.check_port25() end)}
    end
  end

  def handle_event("send_test", %{"test" => %{"to" => to}}, socket) do
    recipient = String.trim(to)

    cond do
      socket.assigns.sending_test? ->
        {:noreply, socket}

      recipient == "" ->
        {:noreply,
         socket
         |> assign(:test_to, to)
         |> put_flash(:error, gettext("Enter an address to send the test to."))}

      true ->
        email =
          Swoosh.Email.new()
          |> Swoosh.Email.from(socket.assigns.from)
          |> Swoosh.Email.to(recipient)
          |> Swoosh.Email.subject(gettext("KilnCMS test email"))
          |> Swoosh.Email.html_body(
            "<p>#{gettext("This is a test email from your KilnCMS instance.")}</p>"
          )
          |> Swoosh.Email.text_body(gettext("This is a test email from your KilnCMS instance."))

        {:noreply,
         socket
         |> assign(:sending_test?, true)
         |> assign(:test_to, to)
         |> assign(:test_result, nil)
         |> start_async(:send_test, fn -> Mail.deliver_now(email) end)}
    end
  end

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard."))}
  end

  def handle_event("unsuppress", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      with {:ok, record} <- fetch_suppressed(id, actor),
           :ok <- Mail.unsuppress_recipient(record, actor: actor) do
        socket
        |> load_delivery_health()
        |> put_flash(:info, gettext("Address removed — it can receive mail again."))
      else
        _error -> put_flash(socket, :error, gettext("Couldn't remove that address."))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_async(:verify, {:ok, results}, socket) do
    results = stringify(results)

    case Mail.record_mail_verification(
           socket.assigns.settings,
           %{verification_results: results},
           actor: socket.assigns.actor
         ) do
      {:ok, settings} ->
        {:noreply, socket |> assign(:verifying?, false) |> load_settings(settings)}

      {:error, _error} ->
        {:noreply,
         socket
         |> assign(:verifying?, false)
         |> assign(:results, results)
         |> put_flash(:error, gettext("Checked, but couldn't save the results."))}
    end
  end

  def handle_async(:verify, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:verifying?, false)
     |> put_flash(:error, gettext("The DNS check failed unexpectedly."))}
  end

  def handle_async(:preflight, {:ok, result}, socket) do
    {:noreply, socket |> assign(:preflighting?, false) |> assign(:preflight, stringify(result))}
  end

  def handle_async(:preflight, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:preflighting?, false)
     |> put_flash(:error, gettext("The preflight check failed unexpectedly."))}
  end

  def handle_async(:send_test, {:ok, outcome}, socket) do
    result =
      case outcome do
        {:ok, receipt} -> %{"status" => "ok", "detail" => inspect(receipt)}
        {:error, reason} -> %{"status" => "fail", "detail" => inspect(reason)}
      end

    {:noreply, socket |> assign(:sending_test?, false) |> assign(:test_result, result)}
  end

  def handle_async(:send_test, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:sending_test?, false)
     |> assign(:test_result, %{"status" => "fail", "detail" => inspect(reason)})}
  end

  # --- data ---------------------------------------------------------------------

  defp load_settings(socket, settings) do
    socket
    |> assign(:settings, settings)
    |> assign(:selected_provider, settings.dkim_key_provider)
    |> assign(:records, DnsCheck.expected_records(settings))
    |> assign(:results, settings.verification_results || %{})
  end

  defp load_delivery_health(socket) do
    actor = socket.assigns.actor

    socket
    |> assign(:failures, Mail.recent_delivery_failures())
    |> assign(
      :suppressed,
      Mail.list_suppressed_recipients!(actor: actor, query: [sort: [last_failure_at: :desc]])
    )
  end

  defp fetch_suppressed(id, actor) do
    case Enum.find(Mail.list_suppressed_recipients!(actor: actor), &(&1.id == id)) do
      nil -> :error
      record -> {:ok, record}
    end
  end

  # Prefer the mode runtime.exs resolved; only fall back to inferring it from
  # the configured adapter (dev/test, where :mail_mode isn't set). A real
  # adapter we don't recognise is reported as :custom, not :local — otherwise
  # a downstream project's own Swoosh adapter reads as "no real delivery".
  defp mailer_mode do
    case Application.get_env(:kiln_cms, :mail_mode) do
      "direct" -> :direct
      "smtp" -> :smtp
      _unset -> infer_mailer_mode()
    end
  end

  defp infer_mailer_mode do
    case Application.get_env(:kiln_cms, KilnCMS.Mailer, [])[:adapter] do
      KilnCMS.Mailer.DirectMX -> :direct
      Swoosh.Adapters.SMTP -> :smtp
      adapter when adapter in [nil, Swoosh.Adapters.Local, Swoosh.Adapters.Test] -> :local
      _custom -> :custom
    end
  end

  # DnsCheck returns atom-keyed maps with atom status values (a clean Elixir
  # API); the stored verification_results and reloaded results are string-keyed
  # (JSONB). Convert freshly-computed results to that string shape so the
  # template reads one format regardless of source.
  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp stringify(other), do: other

  defp error_message(%{errors: [%{message: message} | _rest]}) when is_binary(message),
    do: message

  defp error_message(_error), do: gettext("Something went wrong.")

  defp result_for(results, check), do: results[to_string(check)]

  defp provider_label(:env), do: gettext("Environment variable")
  defp provider_label(:file), do: gettext("File")
  defp provider_label(:database), do: gettext("Database (encrypted)")

  defp provider_hint(:env),
    do: gettext("Recommended for production. Reads a PEM key from an environment variable.")

  defp provider_hint(:file),
    do:
      gettext(
        "Recommended for production. Reads a PEM file — the natural fit for Docker/Kubernetes mounted secrets."
      )

  defp provider_hint(:database),
    do:
      gettext(
        "Zero-ops default: generate a key right here. Encrypted with a key derived from SECRET_KEY_BASE — rotating that secret orphans the key."
      )

  defp pointer_value(%{dkim_key_provider: :env, dkim_key_provider_config: config}, :env),
    do: config["var"]

  defp pointer_value(%{dkim_key_provider: :file, dkim_key_provider_config: config}, :file),
    do: config["path"]

  defp pointer_value(_settings, :env), do: "DKIM_PRIVATE_KEY"
  defp pointer_value(_settings, _provider), do: nil

  # --- render ---------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:mail}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Mail")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Direct email delivery: sign with DKIM, publish the DNS records below, and this instance sends mail with no external provider."
            )}
          </p>
        </div>

        <section class="card card-pad">
          <h2 class="text-lg font-medium">{gettext("Status")}</h2>
          <dl class="mt-3 grid gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
            <div class="flex justify-between gap-4 sm:block">
              <dt class="text-base-content/60">{gettext("Delivery mode")}</dt>
              <dd class="font-medium">
                <%= case @mode do %>
                  <% :direct -> %>
                    {gettext("Direct (built-in MTA)")}
                  <% :smtp -> %>
                    {gettext("SMTP relay")}
                  <% :custom -> %>
                    {gettext("Custom adapter")}
                  <% :local -> %>
                    {gettext("Local mailbox (no real delivery)")}
                <% end %>
              </dd>
            </div>
            <div class="flex justify-between gap-4 sm:block">
              <dt class="text-base-content/60">{gettext("From address")}</dt>
              <dd class="font-medium">
                <%= if @from do %>
                  {elem(@from, 1)}
                <% else %>
                  {gettext("not configured")}
                <% end %>
              </dd>
            </div>
            <div class="flex justify-between gap-4 sm:block">
              <dt class="text-base-content/60">{gettext("HELO host")}</dt>
              <dd class="font-medium">{@helo_host || gettext("not configured")}</dd>
            </div>
            <div class="flex justify-between gap-4 sm:block">
              <dt class="text-base-content/60">{gettext("DKIM signing")}</dt>
              <dd class="font-medium">
                <%= if @settings.dkim_public_key do %>
                  {gettext("configured (selector %{selector})", selector: @settings.dkim_selector)}
                <% else %>
                  {gettext("no key — mail goes out unsigned")}
                <% end %>
              </dd>
            </div>
          </dl>
          <p :if={@mode == :local} class="mt-3 text-sm text-base-content/70">
            {gettext(
              "Direct delivery is off. Set MAIL_MODE=direct (with MAIL_FROM_EMAIL) to send straight to recipient mail servers; you can prepare the key and DNS records first."
            )}
          </p>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("DKIM key")}</h2>
          <div class="space-y-2">
            <label
              :for={provider <- Keys.provider_names()}
              class="flex cursor-pointer items-start gap-3 rounded border border-base-content/10 p-3 hover:bg-base-200/40"
            >
              <input
                type="radio"
                name="provider"
                value={provider}
                checked={@selected_provider == provider}
                phx-click="select_provider"
                phx-value-provider={provider}
                class="mt-1"
              />
              <span>
                <span class="flex items-center gap-2 font-medium">
                  {provider_label(provider)}
                  <span
                    :if={@settings.dkim_key_provider == provider and @settings.dkim_public_key}
                    class="rounded bg-success/20 px-1.5 py-0.5 text-xs text-success"
                  >
                    {gettext("active")}
                  </span>
                </span>
                <span class="block text-sm text-base-content/70">{provider_hint(provider)}</span>
              </span>
            </label>
          </div>

          <div :if={Keys.writable?(@selected_provider)} class="flex items-center gap-3">
            <%= if @settings.dkim_key_provider == @selected_provider and @settings.dkim_public_key do %>
              <.button
                type="button"
                phx-click="rotate"
                data-confirm={
                  gettext(
                    "Rotate the DKIM key? You must publish the new DNS record before signed mail verifies again."
                  )
                }
              >
                {gettext("Rotate key")}
              </.button>
              <span class="text-sm text-base-content/70">
                {gettext("Key present. The private key is never displayed.")}
              </span>
            <% else %>
              <.button type="button" phx-click="generate" variant="primary">
                {gettext("Generate key")}
              </.button>
            <% end %>
          </div>

          <form
            :if={not Keys.writable?(@selected_provider)}
            id="key-source-form"
            phx-submit="save_key_source"
            class="flex flex-wrap items-end gap-3"
          >
            <input type="hidden" name="source[provider]" value={@selected_provider} />
            <div class="min-w-64 flex-1">
              <.input
                type="text"
                id="key-source-pointer"
                name="source[pointer]"
                value={pointer_value(@settings, @selected_provider)}
                label={
                  if @selected_provider == :env,
                    do: gettext("Environment variable name"),
                    else: gettext("Absolute file path (e.g. /run/secrets/dkim.pem)")
                }
              />
            </div>
            <.button type="submit">{gettext("Save & check source")}</.button>
          </form>
        </section>

        <section class="space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-lg font-medium">{gettext("DNS records")}</h2>
            <div class="flex items-center gap-3">
              <span :if={@settings.last_verified_at} class="text-xs text-base-content/60">
                {gettext("last checked")} {Calendar.strftime(
                  @settings.last_verified_at,
                  "%Y-%m-%d %H:%M UTC"
                )}
              </span>
              <.button type="button" phx-click="verify" disabled={@verifying?}>
                <%= if @verifying? do %>
                  {gettext("Checking…")}
                <% else %>
                  {gettext("Verify now")}
                <% end %>
              </.button>
            </div>
          </div>

          <form id="server-ip-form" phx-submit="save_server_ip" class="flex flex-wrap items-end gap-3">
            <div>
              <.input
                type="text"
                id="server-ip-input"
                name="settings[server_ip]"
                value={@settings.server_ip}
                label={gettext("Server public IP (for the SPF and reverse-DNS checks)")}
                placeholder="203.0.113.9"
              />
            </div>
            <.button type="submit">{gettext("Save IP")}</.button>
          </form>

          <ul class="space-y-3">
            <li
              :for={record <- @records}
              class="rounded border border-base-content/10 p-3"
              data-check={record.check}
            >
              <div class="flex flex-wrap items-center gap-2">
                <.status_badge result={result_for(@results, record.check)} />
                <span class="font-mono text-xs text-base-content/60">{record.type}</span>
                <code class="break-all text-sm font-medium">{record.host}</code>
                <button
                  type="button"
                  id={"copy-#{record.check}"}
                  phx-hook="Clipboard"
                  data-clipboard-text={record.value}
                  class="btn btn-sm btn-default ml-auto shrink-0"
                >
                  {gettext("Copy value")}
                </button>
              </div>
              <code class="mt-2 block break-all rounded bg-base-200/60 p-2 text-xs">
                {record.value}
              </code>
              <p
                :if={result_for(@results, record.check)}
                class="mt-2 text-sm text-base-content/70"
              >
                {result_for(@results, record.check)["detail"]}
              </p>
              <p :if={record.check == :ptr} class="mt-1 text-xs text-base-content/50">
                {gettext("Reverse DNS is set in your hosting provider's panel, not in your DNS zone.")}
              </p>
            </li>
          </ul>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Delivery test")}</h2>

          <div class="flex flex-wrap items-center gap-3">
            <.button type="button" phx-click="preflight" disabled={@preflighting?}>
              <%= if @preflighting? do %>
                {gettext("Probing…")}
              <% else %>
                {gettext("Check outbound port 25")}
              <% end %>
            </.button>
            <div :if={@preflight} class="flex items-center gap-2 text-sm">
              <.status_badge result={@preflight} />
              <span class="text-base-content/70">{@preflight["detail"]}</span>
            </div>
          </div>

          <form id="send-test-form" phx-submit="send_test" class="flex flex-wrap items-end gap-3">
            <div class="min-w-64">
              <.input
                type="email"
                id="test-to-input"
                name="test[to]"
                value={@test_to}
                label={gettext("Send a test email to")}
                required
              />
            </div>
            <.button type="submit" disabled={@sending_test?}>
              <%= if @sending_test? do %>
                {gettext("Sending…")}
              <% else %>
                {gettext("Send test")}
              <% end %>
            </.button>
          </form>
          <div
            :if={@test_result}
            class="flex items-start gap-2 text-sm"
            data-test-result={@test_result["status"]}
          >
            <.status_badge result={@test_result} />
            <code class="break-all text-xs">{@test_result["detail"]}</code>
          </div>
          <p class="text-xs text-base-content/50">
            {gettext(
              "For an outside opinion on deliverability (SPF/DKIM/DMARC scoring), send a test to a service like mail-tester.com."
            )}
          </p>
        </section>

        <section class="space-y-6">
          <div>
            <h2 class="text-lg font-medium">{gettext("Delivery health")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Recent permanent failures and the addresses KilnCMS has stopped mailing as a result."
              )}
            </p>
          </div>

          <div class="space-y-2">
            <h3 class="text-sm font-medium text-base-content/80">
              {gettext("Recent failures")}
            </h3>
            <p :if={@failures == []} class="text-sm text-base-content/60">
              {gettext("No recent delivery failures.")}
            </p>
            <ul :if={@failures != []} class="space-y-2">
              <li
                :for={failure <- @failures}
                class="rounded border border-base-content/10 p-3 text-sm"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <span class={[
                    "rounded px-1.5 py-0.5 text-xs font-medium",
                    if(failure.state == "cancelled",
                      do: "bg-error/20 text-error",
                      else: "bg-warning/20 text-warning"
                    )
                  ]}>
                    {if failure.state == "cancelled",
                      do: gettext("hard bounce"),
                      else: gettext("gave up")}
                  </span>
                  <code class="font-medium">{failure.domain}</code>
                  <span :if={failure.at} class="ml-auto text-xs text-base-content/50">
                    {Calendar.strftime(failure.at, "%Y-%m-%d %H:%M UTC")}
                  </span>
                </div>
                <code :if={failure.reason} class="mt-1 block break-all text-xs text-base-content/60">
                  {failure.reason}
                </code>
              </li>
            </ul>
          </div>

          <div class="space-y-2">
            <h3 class="text-sm font-medium text-base-content/80">
              {gettext("Suppressed addresses")}
            </h3>
            <p class="text-xs text-base-content/50">
              {gettext(
                "These addresses hard-bounced and are skipped on future sends. Remove one to let it receive mail again."
              )}
            </p>
            <p :if={@suppressed == []} class="text-sm text-base-content/60">
              {gettext("No suppressed addresses.")}
            </p>
            <ul :if={@suppressed != []} class="space-y-2">
              <li
                :for={entry <- @suppressed}
                class="flex flex-wrap items-center gap-2 rounded border border-base-content/10 p-3 text-sm"
              >
                <code class="font-medium">{entry.email}</code>
                <span :if={entry.last_failure_at} class="text-xs text-base-content/50">
                  {gettext("since")} {Calendar.strftime(entry.last_failure_at, "%Y-%m-%d")}
                </span>
                <.button
                  type="button"
                  phx-click="unsuppress"
                  phx-value-id={entry.id}
                  class="ml-auto"
                >
                  {gettext("Remove")}
                </.button>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.console>
    """
  end

  attr :result, :map, default: nil

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "rounded px-1.5 py-0.5 text-xs font-medium",
      badge_class(@result && @result["status"])
    ]}>
      {badge_text(@result && @result["status"])}
    </span>
    """
  end

  defp badge_class("ok"), do: "bg-success/20 text-success"
  defp badge_class("warn"), do: "bg-warning/20 text-warning"
  defp badge_class("fail"), do: "bg-error/20 text-error"
  defp badge_class(_unchecked), do: "bg-base-content/10 text-base-content/60"

  defp badge_text("ok"), do: gettext("ok")
  defp badge_text("warn"), do: gettext("check")
  defp badge_text("fail"), do: gettext("fail")
  defp badge_text("skip"), do: gettext("skipped")
  defp badge_text(_unchecked), do: gettext("not checked")
end
