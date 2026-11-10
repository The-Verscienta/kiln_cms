defmodule KilnCMSWeb.BotBudgetsLive do
  @moduledoc """
  This site's per-class delivery ceilings (#2243): how many public page
  requests a minute one address may make when its user agent says it is a
  search engine, an AI crawler, another bot or script, or says nothing at all,
  as a percentage of what a browser gets.

  Scoped to the request's org like `/editor/password-policy`. Writes are
  policy-gated to org admins by `KilnCMS.CMS.SiteBotBudgets`, this LiveView sits
  in the `:admin_routes` live session whose tier gate agrees, and every event
  re-checks the policy, because the socket outlives the mount-time check.

  The page shows, per class, the effective percentage, what it comes to in
  requests per address, where it comes from (this site, the server, or the
  default), and the server's value, which is the most a site may set
  (`KilnCMS.BotBudgets`). A blank field inherits the server's value. The
  search-engine hint says that a claim is checked against DNS
  (`KilnCMS.CrawlerVerification`, #2254), or that it is not when the operator
  turned verification off.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.BotBudgets
  alias KilnCMS.CMS
  alias KilnCMS.CrawlerVerification

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Bot budgets"))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", %{"bot_budgets" => params}, socket) when is_map(params) do
    if can_save?(socket) do
      # Re-read rather than trusting the struct assigned at mount: a second tab
      # may have saved or reset since.
      row = current_row(socket)

      case parse(params, row) do
        {:ok, attrs} -> save(socket, row, attrs, params)
        {:error, errors} -> {:noreply, assign(socket, :form, form(params, errors))}
      end
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket) do
    # Re-read rather than destroying the struct assigned at mount: a second tab
    # may already have dropped it.
    case current_row(socket) do
      nil ->
        {:noreply, load_settings(socket)}

      row ->
        if CMS.can_reset_site_bot_budgets?(socket.assigns.current_user, row,
             tenant: socket.assigns.current_org
           ) do
          reset(socket, row)
        else
          {:noreply, put_flash(socket, :error, forbidden_message())}
        end
    end
  end

  # An existing row is updated, so a column left as it was is not "changing"
  # and is not held to a server value lowered since it was saved.
  defp save(socket, row, attrs, params) do
    opts = [
      actor: socket.assigns.current_user,
      tenant: socket.assigns.current_org,
      context: socket.assigns.security_context
    ]

    result =
      if row,
        do: CMS.update_site_bot_budgets(row, attrs, opts),
        else: CMS.save_site_bot_budgets(attrs, opts)

    case result do
      {:ok, _row} ->
        {:noreply, socket |> put_flash(:info, gettext("Bot budgets saved.")) |> load_settings()}

      {:error, error} ->
        # Keep what the admin typed: the refusal names the value to fix.
        {:noreply,
         socket
         |> put_flash(:error, error_message(error))
         |> assign(:form, form(params, []))}
    end
  end

  defp reset(socket, row) do
    case CMS.reset_site_bot_budgets(row,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org,
           context: socket.assigns.security_context
         ) do
      {:error, error} ->
        {:noreply, socket |> put_flash(:error, error_message(error)) |> load_settings()}

      _destroyed ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Bot budgets reset to the server's values."))
         |> load_settings()}
    end
  end

  defp can_save?(socket) do
    CMS.can_save_site_bot_budgets?(socket.assigns.current_user, %{},
      tenant: socket.assigns.current_org
    )
  end

  # Form params (client-controlled) to the resource's attributes. Blank is
  # "inherit"; anything else must be a whole number in range and at most the
  # server's value, unless it is the value already stored (see `save/4`). The
  # resource refuses the same things; checking here as well gives each field its
  # own message, in the admin's language.
  defp parse(params, row) do
    {min, max} = BotBudgets.bounds()

    results =
      for {class, field} <- BotBudgets.fields() do
        raw = params |> Map.get(to_string(field)) |> text() |> String.trim()
        stored = row && Map.get(row, field)
        {field, parse_field(raw, BotBudgets.operator_percent(class), stored, min, max)}
      end

    case for({field, {:error, message}} <- results, do: {field, {message, []}}) do
      [] -> {:ok, Map.new(results, fn {field, {:ok, value}} -> {field, value} end)}
      errors -> {:error, errors}
    end
  end

  defp parse_field("", _ceiling, _stored, _min, _max), do: {:ok, nil}

  defp parse_field(raw, ceiling, stored, min, max) do
    case Integer.parse(raw) do
      {value, ""} when value >= min and value <= max ->
        if value <= ceiling or value == stored,
          do: {:ok, value},
          else:
            {:error,
             gettext("At most %{ceiling}%: this server's operator caps it there.",
               ceiling: ceiling
             )}

      _other ->
        {:error,
         gettext("Enter a whole number from %{min} to %{max}, or leave it blank.",
           min: min,
           max: max
         )}
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  defp load_settings(socket) do
    row = current_row(socket)

    socket
    |> assign(:row, row)
    |> assign(:effective, BotBudgets.effective(socket.assigns.current_org))
    |> assign(:delivery_limit, BotBudgets.delivery_limit())
    |> assign(:window_ms, delivery_window_ms())
    |> assign(:crawler_verification?, CrawlerVerification.enabled?())
    |> assign(:form, form(form_params(row), []))
  end

  defp form(params, errors), do: to_form(params, as: :bot_budgets, errors: errors)

  defp form_params(row) do
    Map.new(BotBudgets.fields(), fn {_class, field} ->
      value = row && Map.get(row, field)
      {to_string(field), if(value, do: to_string(value), else: "")}
    end)
  end

  defp current_row(socket) do
    case CMS.list_site_bot_budgets(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  defp delivery_window_ms do
    {_limit, scale} = Map.fetch!(KilnCMSWeb.RateLimit.limits(), :delivery)
    scale
  end

  defp forbidden_message,
    do: gettext("You don't have permission to change this site's bot budgets.")

  defp error_message(error) do
    ash_error_message(error,
      forbidden: forbidden_message(),
      fallback: gettext("The bot budgets could not be saved.")
    )
  end

  defp class_label(:search_engine), do: gettext("Search engines")
  defp class_label(:ai_crawler), do: gettext("AI crawlers")
  defp class_label(:declared_bot), do: gettext("Other bots and scripts")
  defp class_label(:empty), do: gettext("No user agent")

  defp class_hint(:search_engine),
    do:
      gettext(
        "Googlebot, Bingbot, DuckDuckBot, Baiduspider, YandexBot and Applebot, when the address checks out as theirs. A claim proven false counts as No user agent."
      )

  defp class_hint(:ai_crawler),
    do: gettext("GPTBot, ClaudeBot, CCBot, PerplexityBot, Bytespider, Amazonbot and similar.")

  defp class_hint(:declared_bot),
    do:
      gettext(
        "Clients that name themselves as tools or bots: curl, python-requests, headless browsers, link previews, SEO crawlers."
      )

  defp class_hint(:empty),
    do:
      gettext(
        "Requests that don't say what they are, and claimed search engines proven not to be them."
      )

  defp source_label(%{clamped?: true, site_percent: site}),
    do:
      gettext("This site asks for %{site}%, above what the server now allows.",
        site: site
      )

  defp source_label(%{source: :site}), do: gettext("Set for this site")
  defp source_label(%{source: :operator}), do: gettext("Server setting")
  defp source_label(%{source: :default}), do: gettext("Default")

  # "a minute" for the shipped window; the window in seconds for any other.
  defp per_window(count, 60_000),
    do: ngettext("%{count} request a minute", "%{count} requests a minute", count)

  defp per_window(count, window_ms),
    do:
      ngettext(
        "%{count} request every %{seconds} seconds",
        "%{count} requests every %{seconds} seconds",
        count,
        seconds: div(window_ms, 1000)
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:bot_budgets}
    >
      <.header>
        {gettext("Bot budgets")}
        <:subtitle>
          {gettext(
            "How many public page requests one address may make, by what its browser or tool says it is. Each is a share of what a browser gets."
          )}
        </:subtitle>
      </.header>

      <div class="mt-6 flex gap-3 rounded-lg border border-base-300 bg-base-200/50 p-4 text-sm">
        <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
        <p class="text-base-content/70">
          {gettext(
            "This keeps floods and runaway crawlers from costing you capacity. It is not access control: any client can claim to be a browser or Googlebot. To keep a crawler out, use Blocked addresses, or a robots.txt served in front of Kiln."
          )}
        </p>
      </div>

      <div
        :if={@effective.search_engine.percent < 100}
        id="bot-budgets-search-warning"
        role="status"
        class="mt-4 flex gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
        <p>
          {gettext(
            "Search engines will be refused sooner than browsers. That can slow how quickly new pages are indexed."
          )}
        </p>
      </div>

      <p id="bot-budgets-browser" class="mt-6 text-sm">
        <span class="font-medium">{gettext("Browsers")}</span>
        - {per_window(@delivery_limit, @window_ms)} {gettext(
          "per address. This is the delivery limit, set by the server."
        )}
      </p>

      <.form for={@form} id="bot-budgets-form" phx-submit="save" class="mt-6 max-w-2xl space-y-6">
        <div
          :for={{class, field} <- BotBudgets.fields()}
          id={"bot-budget-#{class}"}
          class="rounded-lg border border-base-300 p-4"
        >
          <.input
            field={@form[field]}
            type="number"
            min="1"
            max={max(@effective[class].operator_percent, @effective[class].site_percent || 0)}
            label={class_label(class) <> " (%)"}
            placeholder={to_string(@effective[class].operator_percent)}
          />
          <p class="-mt-1 text-xs text-base-content/70">{class_hint(class)}</p>
          <p
            :if={class == :search_engine and not @crawler_verification?}
            id="bot-budget-search_engine-unchecked"
            class="mt-1 text-xs text-base-content/70"
          >
            {gettext(
              "This server does not check search-engine claims, so any client naming one gets this budget."
            )}
          </p>
          <p id={"bot-budget-#{class}-effective"} class="mt-2 text-sm">
            <span class="font-medium">{@effective[class].percent}%</span>
            - {per_window(@effective[class].limit, @window_ms)} {gettext("per address")}
            <span class="text-base-content/70">({source_label(@effective[class])})</span>
          </p>
          <p id={"bot-budget-#{class}-ceiling"} class="mt-1 text-xs text-base-content/70">
            {gettext("The server allows at most %{percent}% here.",
              percent: @effective[class].operator_percent
            )}
          </p>
        </div>

        <p class="text-xs text-base-content/70">
          {gettext(
            "Leave a field blank to use the server's value. A site can lower a class below the server's value but not raise it above. Every class shares one count per address, so switching what a client claims never earns more."
          )}
        </p>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <button
            :if={@row}
            type="button"
            phx-click="reset"
            data-confirm={gettext("Go back to the server's values for this site?")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Use the server's values")}
          </button>
        </div>
      </.form>
    </Layouts.console>
    """
  end
end
